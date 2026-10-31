"""Check time alignment, disagreement reporting, provenance, and read-only inputs."""
import csv
import hashlib
import json
import shutil
import unittest

import comparison
import core
from test_automation import Fixture


class ComparisonTests(Fixture):
    def setUp(self):
        super().setUp()
        self.left = self.make_run()
        self.right = self.root / 'independent_review'
        shutil.copytree(self.left, self.right)
        self.set_rows(self.left)
        self.set_rows(self.right)

    def set_rows(self, run, spans=None):
        spans = spans or [(0, 1, '', '', ''), (1, 3, 'FAN-CDS', '+1', '+1'), (3, 6, '', '', '')]
        rows = [dict(start=a, end=b, speaker_speech=s, valence=v, arousal=r) for a, b, s, v, r in spans]
        core.write_grid(run / 'annotations.TextGrid', 6, rows)
        core.save_json(run / 'reviews.json', {})

    def approve(self, run, reviewer):
        _, rows, _ = core.load_run(run)
        for index, row in enumerate(rows):
            if core.valid(row):
                core.approve(run, index, reviewer)

    def fingerprints(self):
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for folder in (self.left, self.right) for path in folder.rglob('*') if path.is_file()}

    def test_deliberate_valence_disagreement_links_to_audio_and_preserves_files(self):
        self.set_rows(self.right, [(0, 1, '', '', ''), (1, 3, 'FAN-CDS', '-1', '+1'), (3, 6, '', '', '')])
        self.approve(self.left, 'rater_a'); self.approve(self.right, 'rater_b')
        before = self.fingerprints()
        report = comparison.compare_runs(self.left, self.right)
        self.assertEqual(before, self.fingerprints())
        items = [item for item in report['entries'] if item['kind'] == 'label_disagreement']
        self.assertEqual(len(items), 1)
        item = items[0]
        self.assertEqual(item['different_tiers'], ['valence'])
        self.assertEqual((item['start'], item['end'], item['source_start']), (1., 3., 1.))
        self.assertEqual((item['left_index'], item['right_index']), (1, 1))
        self.assertTrue(item['left']['approved']); self.assertTrue(item['right']['approved'])
        self.assertEqual(item['left']['reviewer'], 'rater_a')
        metric = report['metrics']['tiers']
        self.assertEqual(metric['valence']['agreement'], 0.)
        self.assertEqual(metric['valence']['compared_seconds'], 2.)
        self.assertEqual(metric['speaker_speech']['agreement'], 1.)
        self.assertEqual(report['warnings'], [])

    def test_equal_approved_reviews_have_no_differences(self):
        self.approve(self.left, 'a'); self.approve(self.right, 'b')
        report = comparison.compare_runs(self.left, self.right)
        self.assertEqual(report['entries'], [])
        self.assertEqual(report['metrics']['both_approved_seconds'], 2.)
        self.assertEqual(report['reviewers'], {'left': ['a'], 'right': ['b']})

    def test_boundary_shift_does_not_cascade_into_label_mismatches(self):
        self.set_rows(self.right, [(0, 1.02, '', '', ''), (1.02, 3.02, 'FAN-CDS', '+1', '+1'), (3.02, 6, '', '', '')])
        self.approve(self.left, 'a'); self.approve(self.right, 'b')
        report = comparison.compare_runs(self.left, self.right)
        kinds = [item['kind'] for item in report['entries']]
        self.assertEqual(kinds.count('boundary_shift'), 2)
        self.assertNotIn('label_disagreement', kinds)
        self.assertEqual(report['metrics']['boundaries']['matched_count'], 2)
        self.assertAlmostEqual(report['metrics']['tiers']['valence']['compared_seconds'], 1.98)
        self.assertAlmostEqual(report['metrics']['tiers']['valence']['missing_seconds'], .04)

    def test_split_and_merge_report_boundary_without_false_label_difference(self):
        self.set_rows(self.right, [(0, 1, '', '', ''), (1, 2, 'FAN-CDS', '+1', '+1'),
                                   (2, 3, 'FAN-CDS', '+1', '+1'), (3, 6, '', '', '')])
        self.approve(self.left, 'a'); self.approve(self.right, 'b')
        report = comparison.compare_runs(self.left, self.right)
        self.assertEqual([item['kind'] for item in report['entries']], ['boundary_unmatched'])
        boundary = report['entries'][0]
        self.assertEqual(boundary['boundary_side'], 'right')
        self.assertEqual(boundary['boundary_time'], 2.)
        self.assertLess(boundary['start'], boundary['end'])
        self.assertEqual(report['metrics']['tiers']['valence']['compared_seconds'], 2.)
        self.assertEqual(report['metrics']['tiers']['valence']['agreement'], 1.)
        reverse = comparison.compare_runs(self.right, self.left)
        self.assertEqual(reverse['entries'][0]['boundary_side'], 'left')

    def test_missing_annotation_has_no_agreement_denominator(self):
        self.set_rows(self.right, [(0, 6, '', '', '')])
        report = comparison.compare_runs(self.left, self.right)
        self.assertTrue(any(item['kind'] == 'missing_annotation' for item in report['entries']))
        for item in report['metrics']['tiers'].values():
            self.assertIsNone(item['agreement'])
            self.assertEqual(item['compared_seconds'], 0.)
            self.assertEqual(item['missing_seconds'], 2.)

    def test_unknown_values_are_excluded_separately_for_each_tier(self):
        self.set_rows(self.right, [(0, 1, '', '', ''), (1, 3, 'FAN-CDS', '+1', '?'), (3, 6, '', '', '')])
        report = comparison.compare_runs(self.left, self.right)
        tiers = report['metrics']['tiers']
        self.assertEqual(tiers['speaker_speech']['agreement'], 1.)
        self.assertEqual(tiers['valence']['agreement'], 1.)
        self.assertIsNone(tiers['arousal']['agreement'])
        self.assertEqual(tiers['arousal']['unknown_seconds'], 2.)
        item = report['entries'][0]
        self.assertEqual(item['unknown_tiers'], ['arousal'])
        self.assertEqual(item['kind'], 'needs_review')

    def test_all_unknown_has_zero_denominator_and_no_nan(self):
        self.set_rows(self.right, [(0, 1, '', '', ''), (1, 3, 'FAN-?', '?', '?'), (3, 6, '', '', '')])
        report = comparison.compare_runs(self.left, self.right)
        self.assertTrue(all(item['agreement'] is None for item in report['metrics']['tiers'].values()))
        json.dumps(report, allow_nan=False)

    def test_known_draft_agreement_is_explicit_and_requires_review(self):
        self.approve(self.left, 'a')
        report = comparison.compare_runs(self.left, self.right)
        self.assertEqual(report['metrics']['tiers']['valence']['agreement'], 1.)
        self.assertEqual(report['metrics']['both_approved_seconds'], 0.)
        self.assertIn('draft', report['metrics']['agreement_scope'])
        self.assertEqual(report['entries'][0]['kind'], 'needs_review')
        self.assertTrue(report['entries'][0]['left']['approved'])
        self.assertFalse(report['entries'][0]['right']['approved'])
        self.assertTrue(report['warnings'])

    def test_shared_reviewer_ids_warn_about_independence(self):
        self.approve(self.left, 'same_rater'); self.approve(self.right, 'same_rater')
        report = comparison.compare_runs(self.left, self.right)
        self.assertTrue(any('same reviewer' in warning.lower() for warning in report['warnings']))

    def test_stale_and_malformed_approvals_do_not_count(self):
        _, rows, _ = core.load_run(self.left)
        signature = core.signature(rows[1])
        stale = dict(rows[1], valence='-1')
        core.save_json(self.left / 'reviews.json', {core.signature(stale): {'reviewer': 'old', 'approved_utc': core.now()},
            signature: {'reviewer': 'name', 'approved_utc': 'not a timestamp'}})
        core.save_json(self.right / 'reviews.json', {signature: {'reviewer': '', 'approved_utc': core.now()}})
        report = comparison.compare_runs(self.left, self.right)
        self.assertEqual(report['reviewers'], {'left': [], 'right': []})
        self.assertEqual(report['metrics']['both_approved_seconds'], 0.)

    def test_modified_excerpt_is_rejected_even_if_metadata_is_rebound(self):
        sound = self.right / 'excerpt.wav'
        data = bytearray(sound.read_bytes()); data[-1] ^= 1; sound.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'audio changed'):
            comparison.compare_runs(self.left, self.right)
        meta = json.loads((self.right / 'run.json').read_text())
        meta['excerpt_sha256'] = core.digest(sound)
        core.save_json(self.right / 'run.json', meta)
        with self.assertRaisesRegex(ValueError, 'same audio excerpt'):
            comparison.compare_runs(self.left, self.right)

    def test_source_offset_group_and_invalid_timing_rejected(self):
        path = self.right / 'run.json'
        original = json.loads(path.read_text())
        for field, value in [('source_offset', 2.), ('group', 'HA'), ('duration', 5.), ('source_offset', -1.)]:
            with self.subTest(field=field, value=value):
                core.save_json(path, dict(original, **{field: value}))
                with self.assertRaises(ValueError):
                    comparison.compare_runs(self.left, self.right)
        core.save_json(path, original)

    def test_same_folder_and_invalid_tolerance_rejected(self):
        with self.assertRaisesRegex(ValueError, 'two different'):
            comparison.compare_runs(self.left, self.left)
        for value in (-1, float('nan'), float('inf'), True, 'bad'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                comparison.compare_runs(self.left, self.right, value)

    def test_dense_boundaries_are_matched_once_without_losing_possible_pairs(self):
        self.set_rows(self.left, [(0, .1, 'FAN-CDS', '+1', '+1'), (.1, .2, 'FAN-CDS', '+1', '+1'), (.2, 6, 'FAN-CDS', '+1', '+1')])
        self.set_rows(self.right, [(0, .16, 'FAN-CDS', '+1', '+1'), (.16, .26, 'FAN-CDS', '+1', '+1'), (.26, 6, 'FAN-CDS', '+1', '+1')])
        report = comparison.compare_runs(self.left, self.right, .1)
        boundaries = report['metrics']['boundaries']
        self.assertEqual(boundaries['matched_count'], 2)
        self.assertEqual(boundaries['left_unmatched'], [])
        self.assertEqual(boundaries['right_unmatched'], [])

    def test_report_exports_to_fresh_folders_without_touching_reviews(self):
        before = self.fingerprints()
        report = comparison.compare_runs(self.left, self.right)
        first = comparison.save_report(report, self.root / 'comparisons')
        second = comparison.save_report(report, self.root / 'comparisons')
        self.assertNotEqual(first, second)
        self.assertEqual(json.loads((first / 'comparison.json').read_text())['identity'], report['identity'])
        with (first / 'differences.csv').open(encoding='utf-8-sig', newline='') as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(rows[0]['kind'], 'needs_review')
        self.assertEqual(rows[0]['left_interval'], '2')
        self.assertEqual(before, self.fingerprints())
        for target in (self.left, self.left / 'nested', self.right):
            with self.assertRaisesRegex(ValueError, 'outside'):
                comparison.save_report(report, target)


if __name__ == '__main__':
    unittest.main()

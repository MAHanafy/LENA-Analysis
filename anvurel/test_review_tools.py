"""Check form recovery, approval rollback, and review audio without real recordings."""
import json
from pathlib import Path
from unittest.mock import patch

import numpy as np
import parselmouth

import core
import review_tools
from test_automation import Fixture


class ReviewToolsTests(Fixture):
    def setUp(self):
        super().setUp()
        self.run = self.make_run()
        self.meta, self.rows, _ = core.load_run(self.run)
        self.index = next(i for i, row in enumerate(self.rows) if row['speaker_speech'])
        row = self.rows[self.index]
        self.values = dict(speaker='FAN-CDS', valence='?', arousal='+1',
                           start=str(row['start']), end=str(row['end']))

    def test_draft_round_trip_never_edits_annotations_or_reviews(self):
        before = {name: (self.run / name).read_bytes() for name in ('annotations.TextGrid', 'reviews.json')}
        review_tools.save_draft(self.run, self.index, self.values, 'rater_one', core.digest(self.run / 'annotations.TextGrid'))
        recovered = review_tools.load_draft(self.run)
        self.assertEqual(recovered['values'], self.values)
        self.assertEqual(recovered['reviewer'], 'rater_one')
        self.assertEqual(recovered['index'], self.index)
        self.assertEqual(before, {name: (self.run / name).read_bytes() for name in before})
        review_tools.clear_draft(self.run)
        self.assertIsNone(review_tools.load_draft(self.run))

    def test_invalid_new_draft_preserves_previous_recoverable_draft(self):
        digest = core.digest(self.run / 'annotations.TextGrid')
        review_tools.save_draft(self.run, self.index, self.values, '', digest)
        before = (self.run / review_tools.DRAFT_NAME).read_bytes()
        for values in (dict(self.values, start=''), dict(self.values, end='nan'), dict(self.values, valence='happy')):
            with self.assertRaises(ValueError):
                review_tools.save_draft(self.run, self.index, values, '', digest)
            self.assertEqual((self.run / review_tools.DRAFT_NAME).read_bytes(), before)

    def test_external_annotation_change_rejects_load_and_save(self):
        digest = core.digest(self.run / 'annotations.TextGrid')
        review_tools.save_draft(self.run, self.index, self.values, '', digest)
        self.rows[self.index]['valence'] = '-1'
        core.save_annotations(self.run, self.rows, digest)
        with self.assertRaisesRegex(ValueError, 'older annotations'):
            review_tools.load_draft(self.run)
        with self.assertRaisesRegex(ValueError, 'changed externally'):
            review_tools.save_draft(self.run, self.index, self.values, '', digest)

    def test_draft_identity_and_malformed_json_are_not_recovered(self):
        digest = core.digest(self.run / 'annotations.TextGrid')
        review_tools.save_draft(self.run, self.index, self.values, '', digest)
        path = self.run / review_tools.DRAFT_NAME
        draft = json.loads(path.read_text())
        draft['audio_sha256'] = 'wrong'
        path.write_text(json.dumps(draft))
        with self.assertRaisesRegex(ValueError, 'different run or audio'):
            review_tools.load_draft(self.run)
        path.write_text('{invalid')
        with self.assertRaisesRegex(ValueError, 'unreadable'):
            review_tools.load_draft(self.run)
        self.assertTrue(path.exists())

    def complete(self):
        self.rows[self.index].update(speaker_speech='FAN-CDS', valence='+1', arousal='-1')
        core.save_annotations(self.run, self.rows, core.digest(self.run / 'annotations.TextGrid'))

    def test_undo_restores_annotations_and_removes_new_approval(self):
        before = {name: (self.run / name).read_bytes() for name in ('annotations.TextGrid', 'reviews.json')}
        token = review_tools.checkpoint(self.run)
        self.complete()
        core.approve(self.run, self.index, 'rater_one')
        review_tools.seal_checkpoint(self.run, token)
        self.assertTrue(token['changed'])
        review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))
        self.assertEqual(before, {name: (self.run / name).read_bytes() for name in before})
        self.assertTrue(list((self.run / 'history').glob('before_undo_*.reviews.json')))
        with self.assertRaisesRegex(ValueError, 'already been undone'):
            review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))

    def test_undo_can_restore_exact_earlier_approval(self):
        self.complete()
        core.approve(self.run, self.index, 'rater_one')
        token = review_tools.checkpoint(self.run)
        _, rows, _ = core.load_run(self.run)
        rows[self.index]['valence'] = '-1'
        core.save_annotations(self.run, rows, core.digest(self.run / 'annotations.TextGrid'))
        review_tools.seal_checkpoint(self.run, token)
        review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))
        _, restored, approvals = core.load_run(self.run)
        self.assertIn(core.signature(restored[self.index]), approvals)

    def test_undo_rejects_unsealed_and_external_review_changes(self):
        token = review_tools.checkpoint(self.run)
        with self.assertRaisesRegex(ValueError, 'not completed'):
            review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))
        self.complete()
        review_tools.seal_checkpoint(self.run, token)
        core.approve(self.run, self.index, 'external_rater')
        before = (self.run / 'annotations.TextGrid').read_bytes()
        with self.assertRaisesRegex(ValueError, 'changed after this action'):
            review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), before)

    def test_undo_rejects_annotation_change_even_with_current_ui_hash(self):
        token = review_tools.checkpoint(self.run)
        self.complete()
        review_tools.seal_checkpoint(self.run, token)
        _, rows, _ = core.load_run(self.run)
        rows[self.index]['arousal'] = '+1'
        core.save_annotations(self.run, rows, core.digest(self.run / 'annotations.TextGrid'))
        with self.assertRaisesRegex(ValueError, 'changed after this action'):
            review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))

    def test_undo_rejects_another_run_and_changed_preparation_metadata(self):
        token = review_tools.checkpoint(self.run)
        self.complete()
        review_tools.seal_checkpoint(self.run, token)
        another = self.make_run()
        with self.assertRaisesRegex(ValueError, 'different run or preparation'):
            review_tools.undo(another, token, core.digest(another / 'annotations.TextGrid'))
        path = self.run / 'run.json'
        metadata = json.loads(path.read_text())
        metadata['source_offset'] = 2
        path.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, 'different run or preparation'):
            review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))

    def test_undo_rejects_corrupted_snapshot_bytes(self):
        token = review_tools.checkpoint(self.run)
        self.complete()
        review_tools.seal_checkpoint(self.run, token)
        token['before_reviews'] = b'{"unexpected":true}'
        with self.assertRaisesRegex(ValueError, 'snapshot has changed'):
            review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))

    def test_failed_second_undo_write_rolls_back_grid(self):
        token = review_tools.checkpoint(self.run)
        self.complete()
        review_tools.seal_checkpoint(self.run, token)
        before = (self.run / 'annotations.TextGrid').read_bytes()
        real_write = review_tools._atomic_bytes
        def fail_review(path, data):
            if Path(path) == self.run / 'reviews.json':
                raise OSError('Simulated full disk')
            return real_write(path, data)
        with patch.object(review_tools, '_atomic_bytes', side_effect=fail_review):
            with self.assertRaisesRegex(OSError, 'full disk'):
                review_tools.undo(self.run, token, core.digest(self.run / 'annotations.TextGrid'))
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), before)
        self.assertFalse(token['used'])

    def test_context_audio_is_clipped_and_original_bytes_are_preserved(self):
        original = (self.run / 'excerpt.wav').read_bytes()
        path = review_tools.make_playback(self.run, .1, 1.5, context=1)
        self.assertAlmostEqual(core.audio_info(path)['duration'], 2.5)
        self.assertEqual((self.run / 'excerpt.wav').read_bytes(), original)
        with self.assertRaises(ValueError):
            review_tools.make_playback(self.run, 2, 1)
        with self.assertRaises(ValueError):
            review_tools.make_playback(self.run, 1, 2, speed=float('nan'))

    def test_slow_playback_lengthens_audio_and_preserves_tone_pitch(self):
        path = review_tools.make_playback(self.run, 1.05, 1.75, speed=.75)
        self.assertAlmostEqual(core.audio_info(path)['duration'], .7 / .75, places=3)
        pitch = parselmouth.Sound(str(path)).to_pitch_ac(pitch_floor=60, pitch_ceiling=600)
        values = pitch.selected_array['frequency']
        voiced = values[values > 0]
        self.assertTrue(len(voiced))
        self.assertLess(abs(float(np.median(voiced)) - 200), 3)

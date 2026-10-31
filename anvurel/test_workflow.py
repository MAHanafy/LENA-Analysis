"""Exercise the complete desktop workflow with generated audio and metadata."""
import csv
import json
from pathlib import Path
import shutil
import time
import tkinter as tk
import unittest
from unittest.mock import patch
import wave

import app
import core
import transcripts
from test_automation import Fixture


class WorkflowTests(Fixture):
    def setUp(self):
        super().setUp()
        body = (self.adult('FAN', .8, 2.) + self.child(2.05, 2.15)
                + self.adult('MAN', 2.2, 3.4) + self.child(3.6, 4.))
        self.its(body)
        self.errors = []
        self.callback_errors = []
        self.sound = patch('winsound.PlaySound').start()
        self.error_dialog = patch('app.messagebox.showerror', side_effect=lambda title, text: self.errors.append(text)).start()
        self.info_dialog = patch('app.messagebox.showinfo').start()
        self.addCleanup(patch.stopall)
        self.tk = tk.Tk(); self.tk.withdraw()
        self.tk.report_callback_exception = lambda kind, error, traceback: self.callback_errors.append(str(error))
        self.application = app.Application(self.tk)
        with patch('app.filedialog.askopenfilename', return_value=str(self.source)):
            self.application.browse('source', 'file')
        self.assertEqual(Path(self.application.vars['its'].get()), self.source.with_suffix('.its'))
        for key, value in {'output': str(self.root / 'prepared'), 'offset': '.5',
                           'length': '4', 'reviewer': 'rater_a'}.items():
            self.application.vars[key].set(value)
        self.application.refine.set(False)
        self.application.prepare()
        self.wait_for_work()
        self.assertEqual(self.errors, [])
        self.assertEqual(self.callback_errors, [])
        self.assertIsNotNone(self.application.run)
        self.run = self.application.run

    def tearDown(self):
        a = self.application
        if a.busy:
            a.cancel.set()
            self.wait_for_work()
        a.close()
        super().tearDown()

    def wait_for_work(self, timeout=12.):
        deadline = time.monotonic() + timeout
        while self.application.busy or not self.application.events.empty():
            self.tk.update()
            if time.monotonic() >= deadline:
                self.fail('The preparation or transcript operation did not finish in time.')
            time.sleep(.01)
        self.tk.update()

    def approve_first_and_save_second_draft(self):
        a = self.application
        self.tk.update()
        first = a.selected_index()
        a.vars['speaker'].set('FAN-CDS')
        a.vars['valence'].set('+1')
        a.vars['arousal'].set('+1')
        a.autosave_form()
        self.assertTrue(a.dirty)
        a.approve_next(); self.tk.update()
        self.assertEqual(self.errors, [])
        second = a.selected_index()
        self.assertNotEqual(first, second)
        a.vars['speaker'].set('MAN-CDS')
        a.vars['valence'].set('0')
        a.vars['arousal'].set('-1')
        a.save_labels(); self.tk.update()
        _, rows, reviews = core.load_run(self.run)
        self.assertTrue(core.valid(rows[second]))
        self.assertNotIn(core.signature(rows[second]), reviews)
        self.assertIn(core.signature(rows[first]), reviews)
        self.assertFalse(a.dirty)
        return first, second

    def import_original_transcript(self):
        source = self.root / 'original_timeline.json'
        source.write_text(json.dumps({'segments': [
            {'start': .6, 'end': 1.1, 'text': 'First phrase'},
            {'start': 1.2, 'end': 1.7, 'text': 'Middle phrase'},
            {'start': 1.8, 'end': 2.3, 'text': 'Last phrase'}]}), encoding='utf-8')
        self.application.transcript_vars['timeline'].set('Original recording')
        self.application.import_transcript_file(source)
        self.wait_for_work()
        self.assertEqual(self.errors, [])
        self.assertEqual(self.callback_errors, [])
        return transcripts.load(self.run)

    def audio_bytes(self, path, start=0., end=None):
        with wave.open(str(path), 'rb') as handle:
            rate = handle.getframerate()
            first = round(start * rate)
            last = handle.getnframes() if end is None else round(end * rate)
            handle.setpos(first)
            return handle.readframes(last - first), rate, last - first

    def input_hashes(self):
        paths = [self.source, self.source.with_suffix('.its')]
        paths += [path for path in self.run.rglob('*') if path.is_file()]
        return {str(path): core.digest(path) for path in paths}

    def assert_no_export_directories(self):
        self.assertEqual([path for path in self.run.iterdir()
                          if path.name.startswith(('export_', '.export_'))], [])

    def test_preparation_guided_review_transcript_comparison_and_export(self):
        a = self.application
        meta, _, _ = core.load_run(self.run)
        self.assertEqual((meta['source_offset'], meta['duration']), (.5, 4.))
        first, second = self.approve_first_and_save_second_draft()
        transcript = self.import_original_transcript()
        self.assertAlmostEqual(transcript['segments'][1]['start'], .7)
        self.assertAlmostEqual(transcript['segments'][1]['end'], 1.2)
        self.assertEqual(len(a.transcript_tree.get_children()), 3)
        a.transcript_tree.selection_set('1'); self.tk.update()
        a.play_transcript_segment()
        playback = Path(next(call.args[0] for call in reversed(self.sound.call_args_list) if call.args[0] is not None))
        actual, rate, frames = self.audio_bytes(playback)
        expected, _, _ = self.audio_bytes(self.source, 1.2, 1.7)
        self.assertEqual(actual, expected)
        self.assertEqual(frames, round(.5 * rate))
        a.show_transcript_annotation(); self.tk.update()
        self.assertEqual(a.selected_index(), first)
        self.assertIn('Middle phrase', a.transcript_preview.get())

        independent = self.root / 'independent_review'
        shutil.copytree(self.run, independent)
        core.save_json(independent / 'reviews.json', {})
        _, rows, _ = core.load_run(independent)
        original_end = rows[first]['end']
        labels = {tier: rows[first][tier] for tier in core.TIERS}
        labels['valence'] = '-1'
        core.set_boundaries(independent, first, rows[first]['start'], original_end + .04,
                            core.digest(independent / 'annotations.TextGrid'), labels=labels)
        core.approve(independent, first, 'rater_b')
        a.compare_vars['left'].set(str(self.run))
        a.compare_vars['right'].set(str(independent))
        a.compare_reviews(); self.tk.update()
        self.assertEqual(self.errors, [])
        report = a.comparison_report
        label_item = next(item for item in report['entries'] if item['kind'] == 'label_disagreement')
        self.assertEqual(label_item['different_tiers'], ['valence'])
        self.assertTrue(any(item['kind'] == 'boundary_shift' for item in report['entries']))
        self.assertEqual(report['reviewers'], {'left': ['rater_a'], 'right': ['rater_b']})
        self.assertAlmostEqual(report['metrics']['tiers']['speaker_speech']['agreement'], 1.)
        self.assertLess(report['metrics']['tiers']['valence']['agreement'], 1.)
        self.assertIn('known draft labels', a.comparison_notes.get())
        a.comparison_tree.selection_set(label_item['id'])
        a.open_comparison_interval(); self.tk.update()
        self.assertEqual(a.selected_index(), first)

        before = set(self.run.glob('export_*'))
        a.export()
        exports = set(self.run.glob('export_*')) - before
        self.assertEqual(len(exports), 1)
        destination = exports.pop()
        with (destination / 'manifest.csv').open(encoding='utf-8-sig', newline='') as handle:
            manifest = list(csv.DictReader(handle))
        self.assertEqual(len(manifest), 1)
        sample = manifest[0]
        self.assertEqual(sample['sample_id'], f'interval_{first+1:05}')
        self.assertNotEqual(sample['sample_id'], f'interval_{second+1:05}')
        self.assertEqual(sample['reviewer'], 'rater_a')
        self.assertAlmostEqual(float(sample['source_start']), .8)
        self.assertAlmostEqual(float(sample['source_end']), 2.)
        clip = destination / sample['clip_path']
        clip_data, rate, clip_frames = self.audio_bytes(clip)
        source_data, _, _ = self.audio_bytes(self.source, .8, 2.)
        self.assertEqual(clip_data, source_data)
        self.assertEqual(clip_frames, round(1.2 * rate))
        self.assertEqual(json.loads((destination / 'transcript.json').read_text(encoding='utf-8')), transcripts.load(self.run))
        with (destination / 'transcript_segments.csv').open(encoding='utf-8-sig', newline='') as handle:
            links = list(csv.DictReader(handle))
        self.assertEqual(len(links), 3)
        self.assertEqual([link['partial_cue'] for link in links], ['True', 'False', 'True'])
        self.assertEqual([link['segment'] for link in links], ['1', '2', '3'])
        self.assertTrue(all(link['sample_id'] == sample['sample_id'] for link in links))
        for link in links:
            self.assertEqual(link['draft'], 'True')
            self.assertAlmostEqual(float(link['source_start']), .5 + float(link['excerpt_start']))
            self.assertAlmostEqual(float(link['source_end']), .5 + float(link['excerpt_end']))
            self.assertAlmostEqual(float(link['clip_start']), float(link['excerpt_start']) - .3)
            self.assertAlmostEqual(float(link['clip_end']), float(link['excerpt_end']) - .3)
        self.assertEqual(self.errors, [])
        self.assertEqual(self.callback_errors, [])

    def test_stale_transcript_source_offset_rejects_export_without_partial_output(self):
        self.approve_first_and_save_second_draft()
        self.import_original_transcript()
        metadata = json.loads((self.run / 'run.json').read_text(encoding='utf-8'))
        metadata['source_offset'] += 1
        metadata['source_end'] += 1
        core.save_json(self.run / 'run.json', metadata)
        before = set(self.run.iterdir())
        with self.assertRaises(ValueError):
            core.export(self.run)
        self.assertEqual(set(self.run.iterdir()), before)
        self.assertEqual(list(self.run.glob('export_*')), [])

    def test_changed_audio_blocks_transcript_comparison_and_export(self):
        self.approve_first_and_save_second_draft()
        self.import_original_transcript()
        independent = self.root / 'independent_review'
        shutil.copytree(self.run, independent)
        a = self.application
        a.compare_vars['left'].set(str(self.run)); a.compare_vars['right'].set(str(independent))
        a.compare_reviews()
        self.assertIsNotNone(a.comparison_report)
        source = self.run / 'excerpt.wav'
        data = bytearray(source.read_bytes()); data[-1] ^= 1; source.write_bytes(data)
        with self.assertRaises(ValueError):
            transcripts.load(self.run)
        a.open_comparison_interval()
        self.assertIn('changed after this comparison', self.errors[-1])
        before = set(self.run.iterdir())
        with self.assertRaises(ValueError):
            core.export(self.run)
        self.assertEqual(set(self.run.iterdir()), before)
        self.assertEqual(list(self.run.glob('export_*')), [])

    def test_approval_change_during_export_cancels_output_and_preserves_external_change(self):
        self.approve_first_and_save_second_draft()
        self.import_original_transcript()
        before = self.input_hashes()
        original_features = core.features
        def remove_approval_during_measurement(*args, **kwargs):
            result = original_features(*args, **kwargs)
            core.save_json(self.run / 'reviews.json', {})
            return result
        with patch('core.features', side_effect=remove_approval_during_measurement):
            with self.assertRaisesRegex(ValueError, 'inputs changed during processing'):
                core.export(self.run)
        after = self.input_hashes()
        reviews = str(self.run / 'reviews.json')
        self.assertEqual({name: value for name, value in before.items() if name != reviews},
                         {name: value for name, value in after.items() if name != reviews})
        self.assertEqual(json.loads((self.run / 'reviews.json').read_text(encoding='utf-8')), {})
        self.assert_no_export_directories()

    def test_failed_export_write_removes_partial_files_and_preserves_inputs(self):
        self.approve_first_and_save_second_draft()
        self.import_original_transcript()
        before = self.input_hashes()
        original_write_csv = core.write_csv
        def fail_after_clips_are_written(path, *args, **kwargs):
            if Path(path).name == 'acoustics.csv':
                raise OSError('Simulated output write failure')
            return original_write_csv(path, *args, **kwargs)
        with patch('core.write_csv', side_effect=fail_after_clips_are_written):
            with self.assertRaisesRegex(OSError, 'Simulated output write failure'):
                core.export(self.run)
        self.assert_no_export_directories()
        self.assertEqual(self.input_hashes(), before)


if __name__ == '__main__':
    unittest.main()

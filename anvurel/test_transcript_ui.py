"""Native transcript controls preserve timing and route work through the UI queue."""
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import ttk
from unittest.mock import Mock, patch

import core
import transcripts
from transcript_ui import TranscriptUIMixin
from test_automation import Fixture


class TranscriptHarness(TranscriptUIMixin):
    def __init__(self, root, run, models):
        self.root, self.run = root, Path(run)
        self.meta, self.rows, self.reviews = core.load_run(run)
        self.events, self.cancel = queue.Queue(), threading.Event()
        self.busy, self.dirty, self.active_praat = False, False, False
        self.errors, self.worker_errors, self.threads = [], [], []
        self.status = tk.StringVar(master=root)
        self.vars = {'filter': tk.StringVar(master=root, value='Needs review')}
        self.tabs = ttk.Notebook(root)
        self.tabs.pack(fill='both', expand=True)
        self.review_tab, self.guided_tab, self.transcript_tab = [ttk.Frame(self.tabs) for _ in range(3)]
        for title, page in [('Review', self.review_tab), ('Guided', self.guided_tab), ('Transcript', self.transcript_tab)]:
            self.tabs.add(page, text=title)
        self.tree = ttk.Treeview(self.review_tab)
        self.tree.pack()
        self.play_range = Mock()
        self.init_transcripts(models)
        self.make_transcripts()
        self.render()

    def table(self, page, columns, titles, widths):
        tree = ttk.Treeview(page, columns=columns, show='headings')
        for column, title, width in zip(columns, titles, widths):
            tree.heading(column, text=title)
            tree.column(column, width=width)
        tree.pack(fill='both', expand=True)
        return tree

    def button_bar(self, page, buttons):
        bar = ttk.Frame(page)
        bar.pack(fill='x')
        for title, action in buttons:
            ttk.Button(bar, text=title, command=action).pack(side='left')

    def require_run(self):
        if self.run is None:
            raise ValueError('Choose a run first.')

    def praat_active(self):
        return self.active_praat

    def guard(self, action):
        try:
            return action()
        except Exception as error:
            self.errors.append(str(error))

    def render(self):
        self.tree.delete(*self.tree.get_children())
        for index, row in enumerate(self.rows):
            if any(row[tier] for tier in core.TIERS):
                self.tree.insert('', 'end', iid=str(index))
        if self.tree.get_children():
            self.tree.selection_set(self.tree.get_children()[0])

    def selected_index(self):
        selection = self.tree.selection()
        if not selection:
            raise ValueError('Select a candidate.')
        return int(selection[0])

    def select(self):
        self.update_transcript_selection(self.rows[self.selected_index()])

    def work(self, task):
        if self.busy:
            raise ValueError('Busy')
        self.busy = True
        self.cancel.clear()
        def worker():
            try:
                task()
            except Exception as error:
                self.worker_errors.append(error)
            finally:
                self.events.put(('idle',))
        thread = threading.Thread(target=worker)
        self.threads.append(thread)
        thread.start()

    def finish_work(self):
        for thread in self.threads:
            thread.join(5)
            if thread.is_alive():
                raise AssertionError('Transcript worker did not finish')
        while not self.events.empty():
            event = self.events.get_nowait()
            if event[0] == 'idle':
                self.busy = False
            else:
                self.handle_transcript_event(event)
        self.root.update()


class TranscriptUITests(Fixture):
    def setUp(self):
        super().setUp()
        self.run = core.prepare(self.source, self.root / 'runs', offset=.5, length=4)
        self.window = tk.Tk()
        self.window.withdraw()
        self.a = TranscriptHarness(self.window, self.run, self.root / 'models')
        self.callback_errors = []
        self.window.report_callback_exception = lambda *error: self.callback_errors.append(error)
        self.window.update()

    def tearDown(self):
        self.a.cancel.set()
        for thread in self.a.threads:
            thread.join(5)
        self.window.destroy()
        super().tearDown()

    def import_source(self, start=.8, end=1.1, text='Check the words'):
        path = self.root / 'words.json'
        import json
        path.write_text(json.dumps({'segments': [{'start': start, 'end': end, 'text': text}]}), encoding='utf-8')
        return path

    def attached(self, start=.8, end=1.1):
        transcripts.import_transcript(self.run, self.import_source(start, end))
        self.a.load_transcript_for_run()
        self.window.update()

    def test_import_original_times_maps_text_and_playback_once(self):
        path = self.root / 'words.srt'
        path.write_text('1\n00:00:01,300 --> 00:00:01,500\nCheck these words\n', encoding='utf-8')
        self.a.transcript_vars['timeline'].set('Original recording')
        self.a.import_transcript_file(path)
        self.a.finish_work()
        self.assertEqual(self.a.errors, [])
        self.assertEqual(self.a.worker_errors, [])
        segment = self.a.transcript_document['segments'][0]
        self.assertAlmostEqual(segment['start'], .8)
        self.assertAlmostEqual(segment['end'], 1.)
        self.assertIn('Original 1.300 to 1.500', self.a.transcript_segment_detail.get())
        self.a.play_transcript_segment()
        self.a.play_range.assert_called_once_with(.8, 1., context=0., loop=False)
        self.a.show_transcript_annotation()
        selected = self.a.rows[self.a.selected_index()]
        self.assertLessEqual(selected['start'], .8)
        self.assertGreaterEqual(selected['end'], 1.)
        self.assertEqual(self.a.vars['filter'].get(), 'All')
        self.assertEqual(self.a.tabs.select(), str(self.a.guided_tab))
        self.assertIn('Check these words', self.a.transcript_preview.get())
        self.assertEqual(self.callback_errors, [])

    def test_preview_only_includes_overlapping_text(self):
        self.attached()
        self.a.update_transcript_selection({'start': 2., 'end': 3.})
        self.assertNotIn('Check the words', self.a.transcript_preview.get())
        self.assertIn('no text overlaps', self.a.transcript_preview.get())
        self.a.update_transcript_selection({'start': .7, 'end': .9})
        self.assertIn('Check the words', self.a.transcript_preview.get())

    def test_annotation_jump_uses_largest_overlap_when_text_spans_candidates(self):
        self.attached(start=1., end=2.6)
        self.a.show_transcript_annotation()
        selected = self.a.rows[self.a.selected_index()]
        self.assertGreater(selected['start'], 1.5)
        self.assertGreaterEqual(selected['end'], 2.6)

    def test_unsaved_form_and_active_praat_block_annotation_jump(self):
        self.attached()
        before = self.a.tree.selection()
        self.a.dirty = True
        self.a.show_transcript_annotation()
        self.assertIn('Save or reset', self.a.errors[-1])
        self.assertEqual(self.a.tree.selection(), before)
        self.a.dirty = False
        self.a.active_praat = True
        self.a.show_transcript_annotation()
        self.assertIn('Finish and save Praat', self.a.errors[-1])
        self.assertEqual(self.a.tree.selection(), before)
        self.a.play_transcript_segment()
        self.a.play_range.assert_not_called()

    def test_text_without_an_overlapping_candidate_does_not_change_selection(self):
        self.attached(start=3.8, end=3.9)
        before = self.a.tree.selection()
        self.a.show_transcript_annotation()
        self.assertIn('No annotation overlaps', self.a.errors[-1])
        self.assertEqual(self.a.tree.selection(), before)

    def test_stale_transcript_warns_without_blocking_annotation_table(self):
        self.attached()
        path = self.run / 'transcript.json'
        import json
        document = json.loads(path.read_text(encoding='utf-8'))
        document['audio_sha256'] = '0' * 64
        path.write_text(json.dumps(document), encoding='utf-8')
        before = self.a.tree.get_children()
        self.a.load_transcript_for_run()
        self.assertIsNone(self.a.transcript_document)
        self.assertIn('needs attention', self.a.transcript_status.get())
        self.assertEqual(self.a.tree.get_children(), before)
        self.assertEqual(self.a.transcript_tree.get_children(), ())

    def test_saved_transcript_changes_require_refresh_before_play(self):
        self.attached()
        transcripts.import_transcript(self.run, self.import_source(2., 2.5, 'Replacement'))
        self.a.play_transcript_segment()
        self.assertIn('Transcript changed', self.a.errors[-1])
        self.a.play_range.assert_not_called()

    def test_generation_captures_inputs_on_ui_thread_and_reports_through_queue(self):
        caller_thread = threading.get_ident()
        getter_threads = []
        contexts = []
        for variable in self.a.transcript_vars.values():
            original = variable.get
            context = patch.object(variable, 'get', side_effect=lambda original=original: (
                getter_threads.append(threading.get_ident()), original())[1])
            contexts.append(context)
            context.start()
        path = self.import_source()
        captured = {}
        def generated(run, **kwargs):
            captured.update(run=Path(run), thread=threading.get_ident(), **kwargs)
            kwargs['progress'](.5, 'Half complete')
            return transcripts.import_transcript(run, path)
        try:
            with patch.object(transcripts, 'generate', side_effect=generated):
                self.a.generate_transcript()
                self.a.finish_work()
        finally:
            for context in contexts:
                context.stop()
        self.assertNotEqual(captured['thread'], caller_thread)
        self.assertTrue(all(thread == caller_thread for thread in getter_threads))
        self.assertEqual(captured['run'], self.run.resolve())
        self.assertEqual(captured['model'], 'tiny')
        self.assertIsNone(captured['language'])
        self.assertFalse(captured['allow_download'])
        self.assertEqual(captured['model_directory'], self.root / 'models')
        self.assertIn('draft saved', self.a.status.get())
        self.assertIsNotNone(self.a.transcript_document)
        self.assertEqual(self.a.worker_errors, [])
        self.assertEqual(self.callback_errors, [])

    def test_stale_worker_result_cannot_replace_current_run_display(self):
        started, release = threading.Event(), threading.Event()
        path = self.import_source()
        captured = []
        def generated(run, **kwargs):
            captured.append(Path(run))
            started.set()
            if not release.wait(5):
                raise RuntimeError('Test worker was not released')
            return transcripts.import_transcript(run, path)
        other = core.prepare(self.source, self.root / 'other_runs', length=4)
        with patch.object(transcripts, 'generate', side_effect=generated):
            self.a.generate_transcript()
            self.assertTrue(started.wait(5))
            self.a.run = other
            self.a.meta, self.a.rows, self.a.reviews = core.load_run(other)
            self.a.load_transcript_for_run()
            release.set()
            self.a.finish_work()
        self.assertEqual(captured, [self.run.resolve()])
        self.assertIsNone(self.a.transcript_document)
        self.assertFalse((other / 'transcript.json').exists())
        self.assertTrue((self.run / 'transcript.json').exists())
        self.assertIsNone(self.a._transcript_operation)

    def test_invalid_import_is_reported_and_previous_draft_retained(self):
        self.attached()
        previous = (self.run / 'transcript.json').read_bytes()
        self.a.import_transcript_file(self.import_source(0., 100.))
        self.a.finish_work()
        self.assertIn('beyond the excerpt', self.a.transcript_status.get())
        self.assertEqual((self.run / 'transcript.json').read_bytes(), previous)
        self.assertIsNotNone(self.a.transcript_document)

    def test_cancel_stops_only_a_transcript_job(self):
        self.a.busy = True
        self.a.stop_transcription()
        self.assertFalse(self.a.cancel.is_set())
        self.a._transcript_operation = ('token', self.run.resolve())
        self.a.stop_transcription()
        self.assertTrue(self.a.cancel.is_set())
        self.assertIn('current model or decoding step', self.a.transcript_status.get())

"""Check minimum window actions and deferred form recovery events in native Tk."""
import json
import tkinter as tk
from unittest.mock import patch

import app
import core
import transcripts
from test_automation import Fixture


class GuidedLayoutTests(Fixture):
    def setUp(self):
        super().setUp()
        self.run = self.make_run()
        self.sound_patch = patch('winsound.PlaySound')
        self.sound_patch.start()
        self.messages = []
        self.error_patch = patch.object(app.messagebox, 'showerror', side_effect=lambda title, message:self.messages.append(str(message)))
        self.error_patch.start()
        self.root_window = tk.Tk()
        self.root_window.withdraw()
        self.callbacks = []
        self.root_window.report_callback_exception = lambda typ, error, trace:self.callbacks.append(str(error))
        self.application = app.Application(self.root_window)
        self.application.load_run(self.run)
        self.root_window.update()

    def tearDown(self):
        try:
            self.application.dirty = False
            self.application.close()
        finally:
            try:
                self.root_window.destroy()
            except tk.TclError:
                pass
            self.error_patch.stop()
            self.sound_patch.stop()
            super().tearDown()

    def descendants(self, widget):
        for child in widget.winfo_children():
            yield child
            yield from self.descendants(child)

    def assert_fully_visible(self, widget):
        self.assertTrue(widget.winfo_ismapped(), f'{widget.cget("text")} is hidden')
        self.assertGreaterEqual(widget.winfo_height(), widget.winfo_reqheight(), f'{widget.cget("text")} is vertically clipped')
        self.assertGreaterEqual(widget.winfo_width(), widget.winfo_reqwidth(), f'{widget.cget("text")} is horizontally clipped')
        left, top = widget.winfo_rootx(), widget.winfo_rooty()
        right, bottom = left + widget.winfo_width(), top + widget.winfo_height()
        parent = widget.master
        while parent is not None:
            self.assertGreaterEqual(left, parent.winfo_rootx())
            self.assertGreaterEqual(top, parent.winfo_rooty())
            self.assertLessEqual(right, parent.winfo_rootx() + parent.winfo_width())
            self.assertLessEqual(bottom, parent.winfo_rooty() + parent.winfo_height())
            parent = parent.master

    def test_essential_actions_remain_visible_with_long_transcript_at_supported_sizes(self):
        source = self.root / 'long_text.json'
        source.write_text(json.dumps({'segments':[{'start':0., 'end':6.,
            'text':'Synthetic words for checking a long transcript preview. ' * 12}]}), encoding='utf-8')
        transcripts.import_transcript(self.run, source)
        a = self.application
        a.load_transcript_for_run()
        expected = {'Save labels', 'Approve and next', 'Next', 'Exclude interval', 'Undo last change',
                    'Export approved', 'Restore saved form', 'Reset form'}
        for width, height in ((1000,700), (1280,800)):
            with self.subTest(size=(width,height)):
                self.root_window.geometry(f'{width}x{height}+20+20')
                a.tabs.select(a.guided_tab)
                self.root_window.deiconify()
                self.root_window.update()
                found = {}
                footer = getattr(a, 'guided_footer', a.guided_tab)
                for child in self.descendants(footer):
                    try:
                        caption = str(child.cget('text'))
                    except tk.TclError:
                        continue
                    if caption in expected:
                        found[caption] = child
                self.assertEqual(set(found), expected)
                for widget in found.values():
                    self.assert_fully_visible(widget)
                scroll = getattr(a, 'guided_scroll', None)
                if scroll is not None:
                    scroll.yview_moveto(1.)
                    self.root_window.update()
                    for widget in found.values():
                        self.assert_fully_visible(widget)
        self.assertEqual(self.callbacks, [])

    def test_invalid_run_selection_retains_old_run_and_unsaved_form(self):
        a = self.application
        a.vars['valence'].set('+1')
        original_run = a.run
        original_rows = list(a.rows)
        invalid = self.root / 'not_a_run'
        invalid.mkdir()
        with self.assertRaises((OSError, ValueError)):
            a.load_run(invalid)
        self.root_window.update()
        self.assertEqual(a.run, original_run)
        self.assertEqual(a.rows, original_rows)
        self.assertTrue(a.dirty)
        self.assertEqual(a.vars['valence'].get(), '+1')
        self.assertEqual(self.callbacks, [])

    def test_valid_run_switch_is_blocked_when_current_draft_cannot_be_saved(self):
        a = self.application
        original_run = a.run
        a.vars['valence'].set('+1')
        a.vars['start'].set('')
        another = self.make_run()
        with self.assertRaises(ValueError):
            a.load_run(another)
        self.root_window.update()
        self.assertEqual(a.run, original_run)
        self.assertTrue(a.dirty)
        self.assertEqual(a.vars['valence'].get(), '+1')
        self.assertEqual(a.vars['start'].get(), '')
        self.assertEqual(core.load_run(original_run)[2], {})
        self.assertEqual(self.callbacks, [])

    def test_close_keeps_invalid_unsaved_form_and_window_open(self):
        a = self.application
        a.vars['valence'].set('+1')
        a.vars['start'].set('invalid')
        before = (self.run / 'annotations.TextGrid').read_bytes()
        with patch.object(app.messagebox, 'showinfo') as notice:
            a.close()
        self.assertEqual(notice.call_count, 1)
        self.assertEqual(notice.call_args.args[0], 'Unsaved form')
        self.assertTrue(self.root_window.winfo_exists())
        self.assertTrue(a.dirty)
        self.assertEqual(a.vars['valence'].get(), '+1')
        self.assertEqual(a.vars['start'].get(), 'invalid')
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), before)
        self.assertEqual(core.load_run(self.run)[2], {})
        self.assertEqual(self.callbacks, [])

    def test_restore_after_rapid_run_switch_keeps_values_when_queued_events_arrive(self):
        a = self.application
        index = a.selected_index()
        a.vars['speaker'].set('FAN-CDS')
        a.vars['valence'].set('+1')
        a.vars['reviewer'].set('rater_one')
        a.autosave_form()
        another = self.make_run()
        # Deliberately do not flush Tk events between the two run selections
        # and restoration. Queued Treeview events must use the current run.
        a.load_run(another)
        a.load_run(self.run)
        a.restore_form()
        self.root_window.update()
        self.assertEqual(a.run, self.run.resolve())
        self.assertEqual(a.selected_index(), index)
        self.assertEqual(a.vars['speaker'].get(), 'FAN-CDS')
        self.assertEqual(a.vars['valence'].get(), '+1')
        self.assertEqual(a.vars['reviewer'].get(), 'rater_one')
        self.assertTrue(a.dirty)
        self.assertEqual(core.load_run(self.run)[2], {})
        self.assertEqual(self.callbacks, [])
        self.assertEqual(self.messages, [])

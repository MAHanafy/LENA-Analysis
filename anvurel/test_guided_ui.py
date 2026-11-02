"""Exercise guided controls and form recovery using native Tk and generated audio."""
import tkinter as tk
from unittest.mock import patch
import winsound

import numpy as np
import parselmouth

import app
import core
import review_tools
from test_automation import Fixture


class GuidedDesktopTests(Fixture):
    def setUp(self):
        super().setUp()
        self.run = self.make_run()
        self.messages = []
        self.callbacks = []
        self.sound_patch = patch('winsound.PlaySound')
        self.sound = self.sound_patch.start()
        self.error_patch = patch.object(app.messagebox, 'showerror', side_effect=lambda title, message, **kwargs: self.messages.append(str(message)))
        self.error_patch.start()
        self.open_application()

    def open_application(self):
        self.tk = tk.Tk()
        self.tk.withdraw()
        self.tk.report_callback_exception = lambda typ, value, trace: self.callbacks.append(value)
        self.application = app.Application(self.tk)
        self.application.load_run(self.run)
        self.tk.update()

    def tearDown(self):
        try:
            self.application.dirty = False
            self.application.close()
        finally:
            try:
                self.tk.destroy()
            except tk.TclError:
                pass
            self.error_patch.stop()
            self.sound_patch.stop()
            super().tearDown()

    def complete_form(self):
        a = self.application
        a.vars['speaker'].set('FAN-CDS')
        a.vars['valence'].set('+1')
        a.vars['arousal'].set('-1')
        a.vars['reviewer'].set('rater_one')

    def assert_clean_callbacks(self):
        self.assertEqual(self.callbacks, [])
        self.assertEqual(self.messages, [])

    def test_restart_keeps_form_separate_until_explicit_restore(self):
        a = self.application
        index = a.selected_index()
        original_grid = (self.run / 'annotations.TextGrid').read_bytes()
        a.vars['speaker'].set('FAN-CDS')
        a.vars['valence'].set('+1')
        a.vars['reviewer'].set('rater_one')
        a.autosave_form()
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), original_grid)
        self.assertEqual(core.load_run(self.run)[2], {})
        a.close()
        self.open_application()
        a = self.application
        self.assertIn('Saved form available', a.draft_status.get())
        self.assertNotEqual(a.vars['valence'].get(), '+1')
        self.assertFalse(a.dirty)
        a.restore_form()
        self.tk.update()
        self.assertEqual(a.selected_index(), index)
        self.assertEqual(a.vars['valence'].get(), '+1')
        self.assertEqual(a.vars['reviewer'].get(), 'rater_one')
        self.assertTrue(a.dirty)
        self.assertEqual(core.load_run(self.run)[2], {})
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), original_grid)
        self.assert_clean_callbacks()

    def test_guided_next_saves_partial_labels_without_approval(self):
        a = self.application
        original_index = a.selected_index()
        a.vars['speaker'].set('FAN-CDS')
        a.vars['valence'].set('+1')
        a.guided_next()
        self.tk.update()
        _, rows, approvals = core.load_run(self.run)
        self.assertEqual(rows[original_index]['speaker_speech'], 'FAN-CDS')
        self.assertEqual(rows[original_index]['valence'], '+1')
        self.assertEqual(rows[original_index]['arousal'], '?')
        self.assertEqual(approvals, {})
        self.assertNotEqual(a.selected_index(), original_index)
        self.assertFalse(a.dirty)
        self.assertIsNone(review_tools.load_draft(self.run))
        self.assert_clean_callbacks()

    def test_approve_and_undo_restore_annotation_and_approval_together(self):
        a = self.application
        before = {name: (self.run / name).read_bytes() for name in ('annotations.TextGrid', 'reviews.json')}
        self.complete_form()
        a.approve_next()
        self.tk.update()
        self.assertEqual(len(core.load_run(self.run)[2]), 1)
        self.assertEqual(len(a.undo_tokens), 1)
        a.undo_change()
        self.tk.update()
        self.assertEqual(before, {name: (self.run / name).read_bytes() for name in before})
        self.assertEqual(a.undo_tokens, [])
        self.assert_clean_callbacks()

    def test_multiple_saved_changes_can_be_undone_in_order(self):
        a = self.application
        index = a.selected_index()
        original = (self.run / 'annotations.TextGrid').read_bytes()
        a.vars['valence'].set('+1')
        a.save_labels()
        self.tk.update()
        first = (self.run / 'annotations.TextGrid').read_bytes()
        a.vars['arousal'].set('-1')
        a.save_labels()
        self.tk.update()
        self.assertEqual(len(a.undo_tokens), 2)
        a.undo_change()
        self.tk.update()
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), first)
        self.assertEqual(core.load_run(self.run)[1][index]['arousal'], '?')
        a.undo_change()
        self.tk.update()
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), original)
        self.assertEqual(core.load_run(self.run)[2], {})
        self.assert_clean_callbacks()

    def test_save_without_change_does_not_add_an_undo_action(self):
        a = self.application
        a.save_labels()
        self.tk.update()
        self.assertEqual(a.undo_tokens, [])
        self.assert_clean_callbacks()

    def test_play_interval_uses_exact_bounds_and_pitch_preserving_slow_audio(self):
        a = self.application
        row = a.rows[a.selected_index()]
        original = (self.run / 'excerpt.wav').read_bytes()
        a.loop_audio.set(True)
        a.playback_speed.set('0.75')
        a.play_interval()
        path, flags = self.sound.call_args.args
        self.assertTrue(flags & winsound.SND_LOOP)
        self.assertTrue(flags & winsound.SND_ASYNC)
        self.assertAlmostEqual(core.audio_info(path)['duration'], (row['end'] - row['start']) / .75, places=3)
        pitch = parselmouth.Sound(path).to_pitch_ac(pitch_floor=60, pitch_ceiling=600).selected_array['frequency']
        self.assertLess(abs(float(np.median(pitch[pitch > 0])) - 200), 3)
        self.assertEqual((self.run / 'excerpt.wav').read_bytes(), original)
        a.play()
        path, flags = self.sound.call_args.args
        self.assertFalse(flags & winsound.SND_LOOP)
        context_duration = min(a.meta['duration'], row['end'] + 1) - max(0, row['start'] - 1)
        self.assertAlmostEqual(core.audio_info(path)['duration'], context_duration / .75, places=3)
        self.assert_clean_callbacks()

    def test_external_grid_change_preserves_form_and_rejects_save(self):
        a = self.application
        index = a.selected_index()
        a.vars['valence'].set('+1')
        _, rows, _ = core.load_run(self.run)
        rows[index]['arousal'] = '-1'
        core.save_annotations(self.run, rows, core.digest(self.run / 'annotations.TextGrid'))
        changed = (self.run / 'annotations.TextGrid').read_bytes()
        a.autosave_form()
        self.assertIn('Recovery form not saved', a.draft_status.get())
        a.save_labels()
        self.assertEqual(len(self.messages), 1)
        self.assertIn('changed externally', self.messages[0])
        self.assertEqual(a.vars['valence'].get(), '+1')
        self.assertTrue(a.dirty)
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), changed)
        self.assertEqual(core.load_run(self.run)[2], {})
        self.assertEqual(self.callbacks, [])

    def test_external_approval_change_rejects_new_annotation_write(self):
        a = self.application
        index = a.selected_index()
        self.complete_form()
        a.save_labels()
        self.tk.update()
        core.approve(self.run, index, 'other_rater')
        before = (self.run / 'annotations.TextGrid').read_bytes()
        a.vars['valence'].set('-1')
        a.save_labels()
        self.assertEqual(len(self.messages), 1)
        self.assertIn('Approvals changed externally', self.messages[0])
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), before)
        self.assertEqual(next(iter(core.load_run(self.run)[2].values()))['reviewer'], 'other_rater')

    def test_malformed_boundary_preserves_previous_draft_and_stops_next(self):
        a = self.application
        index = a.selected_index()
        a.vars['valence'].set('+1')
        a.autosave_form()
        original = (self.run / review_tools.DRAFT_NAME).read_bytes()
        a.vars['start'].set('')
        a.autosave_form()
        self.assertIn('Recovery form not saved', a.draft_status.get())
        self.assertEqual((self.run / review_tools.DRAFT_NAME).read_bytes(), original)
        a.guided_next()
        self.tk.update()
        self.assertEqual(a.selected_index(), index)
        self.assertEqual(len(self.messages), 1)
        self.assertTrue(a.dirty)
        self.assertEqual(core.load_run(self.run)[2], {})

    def test_nan_boundary_cannot_approve_an_interval(self):
        a = self.application
        before = (self.run / 'annotations.TextGrid').read_bytes()
        self.complete_form()
        a.vars['start'].set('nan')
        a.approve_next()
        self.tk.update()
        self.assertEqual(len(self.messages), 1)
        self.assertEqual((self.run / 'annotations.TextGrid').read_bytes(), before)
        self.assertEqual(core.load_run(self.run)[2], {})

    def test_stale_recovery_form_is_not_applied_after_external_change(self):
        a = self.application
        index = a.selected_index()
        a.vars['valence'].set('+1')
        a.autosave_form()
        _, rows, _ = core.load_run(self.run)
        rows[index]['arousal'] = '-1'
        core.save_annotations(self.run, rows, core.digest(self.run / 'annotations.TextGrid'))
        a.reload()
        self.tk.update()
        a.restore_form()
        self.assertEqual(len(self.messages), 1)
        self.assertIn('older annotations', self.messages[0])
        self.assertNotEqual(a.vars['valence'].get(), '+1')
        self.assertFalse(a.dirty)
        self.assertEqual(core.load_run(self.run)[2], {})

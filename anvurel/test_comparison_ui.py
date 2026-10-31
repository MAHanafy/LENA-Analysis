"""Exercise comparison widgets and audio navigation without changing real reviews."""
import hashlib
import shutil
import tkinter as tk
from tkinter import ttk
import unittest
from unittest.mock import patch

import core
from comparison_ui import ComparisonUIMixin
from test_automation import Fixture


class Harness(ComparisonUIMixin):
    def __init__(self, root):
        self.root = root
        self.dirty = False
        self.active_praat = False
        self.run = None
        self.rows = []
        self.errors = []
        self.loads = []
        self.played = []
        self.focused_index = None
        self.vars = {'filter': tk.StringVar(value='Needs review')}
        self.status = tk.StringVar()
        self.tree = ttk.Treeview(root)
        self.init_comparison()
        self.compare_tab = ttk.Frame(root)
        self.compare_tab.pack(fill='both', expand=True)
        self.make_comparison()

    def guard(self, action):
        try:
            return action()
        except Exception as error:
            self.errors.append(str(error))

    def praat_active(self):
        return self.active_praat

    def load_run(self, path):
        self.loads.append(str(path))
        self.run = path
        _, self.rows, _ = core.load_run(path)
        self.tree.delete(*self.tree.get_children())
        for index, row in enumerate(self.rows):
            if any(row[tier] for tier in core.TIERS):
                self.tree.insert('', 'end', iid=str(index))
        if self.tree.get_children():
            self.tree.selection_set(self.tree.get_children()[0])

    def play_range(self, start, end):
        self.played.append((start, end))


class ComparisonUITests(Fixture):
    def setUp(self):
        super().setUp()
        self.left = self.make_run()
        self.set_rows(self.left, '+1')
        self.right = self.root / 'second_review'
        shutil.copytree(self.left, self.right)
        self.set_rows(self.right, '-1')
        core.approve(self.left, 1, 'rater_a')
        core.approve(self.right, 1, 'rater_b')
        self.tk = tk.Tk(); self.tk.withdraw()
        self.application = Harness(self.tk)
        self.application.compare_vars['left'].set(str(self.left))
        self.application.compare_vars['right'].set(str(self.right))

    def tearDown(self):
        self.tk.destroy()
        super().tearDown()

    def set_rows(self, run, valence):
        rows = [dict(start=0, end=1, speaker_speech='', valence='', arousal=''),
                dict(start=1, end=3, speaker_speech='FAN-CDS', valence=valence, arousal='+1'),
                dict(start=3, end=6, speaker_speech='', valence='', arousal='')]
        core.write_grid(run / 'annotations.TextGrid', 6, rows)
        core.save_json(run / 'reviews.json', {})

    def fingerprints(self):
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for run in (self.left, self.right) for path in run.rglob('*') if path.is_file()}

    def test_compare_from_empty_application_and_open_correct_interval(self):
        a = self.application
        before = self.fingerprints()
        a.compare_reviews(); self.tk.update()
        self.assertEqual(a.errors, [])
        self.assertIsNone(a.run)
        self.assertEqual(len(a.comparison_tree.get_children()), 1)
        self.assertEqual(a.comparison_metrics.item('valence', 'values')[1], '0.0%')
        self.assertIn('known draft labels', a.comparison_notes.get())
        item = a.open_comparison_interval(); self.tk.update()
        self.assertEqual(a.errors, [])
        self.assertEqual(item['kind'], 'label_disagreement')
        self.assertEqual(a.loads, [str(self.left)])
        self.assertEqual(a.tree.selection(), ('1',))
        self.assertEqual(a.vars['filter'].get(), 'All')
        self.assertEqual(self.fingerprints(), before)

    def test_play_difference_uses_exact_span_not_full_row_or_context(self):
        a = self.application
        self.set_rows(self.right, '-1')
        _, rows, _ = core.load_run(self.right)
        rows = [rows[0], dict(rows[1], end=2), dict(rows[1], start=2, valence='+1'), rows[2]]
        core.write_grid(self.right / 'annotations.TextGrid', 6, rows)
        a.compare_reviews()
        label = next(item for item in a.comparison_entries.values() if item['kind'] == 'label_disagreement')
        a.comparison_tree.selection_set(label['id'])
        before = self.fingerprints()
        a.play_comparison_difference()
        self.assertEqual(a.errors, [])
        self.assertEqual(a.played, [(1., 2.)])
        self.assertEqual(before, self.fingerprints())

    def test_dirty_forms_and_active_praat_block_navigation(self):
        a = self.application
        a.compare_reviews()
        for flag in ('dirty', 'active_praat'):
            with self.subTest(flag=flag):
                setattr(a, flag, True)
                a.open_comparison_interval()
                a.play_comparison_difference()
                self.assertEqual(a.loads, [])
                self.assertEqual(a.played, [])
                self.assertEqual(len(a.errors), 2)
                a.errors.clear()
                setattr(a, flag, False)

    def test_changed_review_rejects_stale_navigation_and_export(self):
        a = self.application
        a.compare_reviews()
        self.set_rows(self.right, '+1')
        a.open_comparison_interval()
        self.assertEqual(a.loads, [])
        self.assertIn('Compare the reviews again', a.errors[-1])
        with patch('comparison_ui.filedialog.askdirectory') as chooser:
            a.save_comparison()
        chooser.assert_not_called()
        self.assertIn('Compare the reviews again', a.errors[-1])

    def test_invalid_pair_is_reported_without_discarding_existing_view(self):
        a = self.application
        a.compare_reviews()
        original = a.comparison_report
        a.compare_vars['right'].set(str(self.left))
        a.compare_reviews()
        self.assertIn('two different', a.errors[-1])
        self.assertIs(a.comparison_report, original)
        self.assertIn('previous results remain', a.comparison_status.get())

    def test_missing_left_candidate_can_still_play_exact_difference(self):
        a = self.application
        core.write_grid(self.left / 'annotations.TextGrid', 6,
                        [dict(start=0, end=6, speaker_speech='', valence='', arousal='')])
        core.save_json(self.left / 'reviews.json', {})
        a.compare_reviews()
        item = next(item for item in a.comparison_entries.values() if item['kind'] == 'missing_annotation')
        a.comparison_tree.selection_set(item['id'])
        a.play_comparison_difference()
        self.assertEqual(a.errors, [])
        self.assertEqual(a.played, [(1., 3.)])
        self.assertEqual(a.tree.get_children(), ())
        self.assertIn('no labeled candidate', a.status.get())

    def test_gap_index_uses_best_overlapping_candidate(self):
        a = self.application
        a.compare_reviews()
        item = next(iter(a.comparison_entries.values()))
        item['left_index'] = 0
        a.open_comparison_interval()
        self.assertEqual(a.tree.selection(), ('1',))
        self.assertEqual(a.errors, [])

    def test_save_report_uses_new_folder_and_preserves_reviews(self):
        a = self.application
        a.compare_reviews()
        before = self.fingerprints()
        with patch('comparison_ui.filedialog.askdirectory', return_value=str(self.root / 'comparison_output')):
            destination = a.save_comparison()
        self.assertTrue((destination / 'comparison.json').exists())
        self.assertEqual(before, self.fingerprints())
        self.assertEqual(a.errors, [])


if __name__ == '__main__':
    unittest.main()

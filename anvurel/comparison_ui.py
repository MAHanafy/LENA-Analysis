"""Controls for reading, inspecting, and exporting differences between two reviews."""
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, ttk

import comparison
import core


class ComparisonUIMixin:
    def init_comparison(self):
        self.comparison_report = None
        self.comparison_entries = {}
        self.compare_vars = {name: tk.StringVar(value=value) for name, value in
                             (('left', ''), ('right', ''), ('tolerance', '0.05'))}
        self.comparison_status = tk.StringVar(value='Choose two separately reviewed copies of the same excerpt.')
        self.comparison_notes = tk.StringVar(value='Agreement describes the saved labels. It does not measure their accuracy.')

    def make_comparison(self):
        page = self.compare_tab
        fields = ttk.Frame(page); fields.pack(fill='x')
        for row, (key, label) in enumerate((('left', 'First review folder'), ('right', 'Second review folder'))):
            ttk.Label(fields, text=label).grid(row=row, column=0, sticky='w', padx=(0, 8), pady=4)
            ttk.Entry(fields, textvariable=self.compare_vars[key]).grid(row=row, column=1, sticky='ew', pady=4)
            ttk.Button(fields, text='Browse', command=lambda key=key: self.browse_comparison(key)).grid(row=row, column=2, padx=(8, 0))
        fields.columnconfigure(1, weight=1)
        tools = ttk.Frame(page); tools.pack(fill='x', pady=6)
        ttk.Label(tools, text='Boundary tolerance in seconds').pack(side='left')
        ttk.Entry(tools, textvariable=self.compare_vars['tolerance'], width=9).pack(side='left', padx=(6, 14))
        for label, command in (('Compare reviews', self.compare_reviews), ('Save report', self.save_comparison),
                               ('Open first review', self.open_comparison_interval), ('Play difference', self.play_comparison_difference)):
            ttk.Button(tools, text=label, command=command).pack(side='left', padx=(0, 6))
        ttk.Label(page, textvariable=self.comparison_status, wraplength=1130).pack(anchor='w', pady=4)
        self.comparison_metrics = self._comparison_table(page,
            ('tier', 'agreement', 'known', 'unknown', 'missing'),
            ('Tier', 'Agreement', 'Known pairs s', 'Unknown s', 'Missing s'),
            (180, 180, 150, 150, 150), height=3, expand=False)
        ttk.Label(page, textvariable=self.comparison_notes, wraplength=1130).pack(anchor='w', pady=5)
        self.comparison_tree = self._comparison_table(page,
            ('span', 'issue', 'left', 'right', 'approval', 'summary'),
            ('Excerpt seconds', 'Difference', 'First labels', 'Second labels', 'Approvals', 'Details'),
            (135, 155, 170, 170, 140, 330), height=8, expand=True)
        self.comparison_tree.bind('<Double-1>', lambda event: self.open_comparison_interval())
        ttk.Label(page, text='Select a difference to open its first review or hear the exact span. Reports leave both reviews unchanged.',
                  wraplength=1130).pack(anchor='w', pady=(6, 0))

    def _comparison_table(self, page, columns, headings, widths, height, expand):
        frame = ttk.Frame(page); frame.pack(fill='both' if expand else 'x', expand=expand)
        tree = ttk.Treeview(frame, columns=columns, show='headings', height=height, selectmode='browse')
        for column, heading, width in zip(columns, headings, widths):
            tree.heading(column, text=heading); tree.column(column, width=width, anchor='w')
        vertical = ttk.Scrollbar(frame, orient='vertical', command=tree.yview)
        horizontal = ttk.Scrollbar(frame, orient='horizontal', command=tree.xview)
        tree.configure(yscrollcommand=vertical.set, xscrollcommand=horizontal.set)
        horizontal.pack(side='bottom', fill='x'); vertical.pack(side='right', fill='y')
        tree.pack(side='left', fill='both', expand=True)
        return tree

    def browse_comparison(self, key):
        path = filedialog.askdirectory(title='Choose a review folder containing run.json')
        if path:
            self.compare_vars[key].set(path)

    def _comparison_ready(self):
        if self.dirty:
            raise ValueError('Save or reload current edits before using a comparison.')
        if self.praat_active():
            raise ValueError('Finish and save Praat before using a comparison.')

    def compare_reviews(self):
        def action():
            self._comparison_ready()
            if not self.compare_vars['left'].get().strip() or not self.compare_vars['right'].get().strip():
                raise ValueError('Choose the first and second review folders.')
            try:
                report = comparison.compare_runs(self.compare_vars['left'].get(), self.compare_vars['right'].get(),
                                                 float(self.compare_vars['tolerance'].get()))
            except Exception:
                self.comparison_status.set('Comparison failed. Any previous results remain unchanged; check the selected folders and compare again.')
                raise
            self.comparison_report = report
            self.comparison_entries = {item['id']: item for item in report['entries']}
            self.comparison_tree.delete(*self.comparison_tree.get_children())
            self.comparison_metrics.delete(*self.comparison_metrics.get_children())
            names = {'speaker_speech': 'Speaker and speech', 'valence': 'Valence', 'arousal': 'Arousal'}
            for tier in core.TIERS:
                metric = report['metrics']['tiers'][tier]
                agreement = 'No known pairs' if metric['agreement'] is None else f'{100*metric["agreement"]:.1f}%'
                self.comparison_metrics.insert('', 'end', iid=tier, values=(names[tier], agreement,
                    f'{metric["compared_seconds"]:.3f}', f'{metric["unknown_seconds"]:.3f}', f'{metric["missing_seconds"]:.3f}'))
            labels = lambda data: ' / '.join(data['labels'][tier] or '(empty)' for tier in core.TIERS)
            kinds = {'label_disagreement': 'Labels differ', 'missing_annotation': 'Annotation missing',
                     'needs_review': 'Needs review', 'boundary_shift': 'Boundary shifted', 'boundary_unmatched': 'Boundary unmatched'}
            for item in report['entries']:
                approved = ('Yes' if item['left']['approved'] else 'No') + ' / ' + ('Yes' if item['right']['approved'] else 'No')
                self.comparison_tree.insert('', 'end', iid=item['id'], values=(f'{item["start"]:.3f} to {item["end"]:.3f}',
                    kinds[item['kind']], labels(item['left']), labels(item['right']), approved, item['summary']))
            if report['entries']:
                self.comparison_tree.selection_set(report['entries'][0]['id'])
            boundary = report['metrics']['boundaries']
            self.comparison_status.set(f'{len(report["entries"])} differences or spans requiring review. '
                f'Boundaries matched: {boundary["matched_count"]} of {boundary["left_count"]} first and {boundary["right_count"]} second.')
            metrics = report['metrics']
            notes = (f'Agreement includes known draft labels and excludes unknown or missing values. '
                f'Both approved: {metrics["both_approved_seconds"]:.3f} of {metrics["active_union_seconds"]:.3f} active seconds. '
                'Approvals in the table are first / second. ')
            notes += ' '.join(report['warnings'])
            self.comparison_notes.set(notes)
        return self.guard(action)

    def _current_comparison(self):
        self._comparison_ready()
        if self.comparison_report is None:
            raise ValueError('Compare two review folders first.')
        comparison.ensure_current(self.comparison_report)
        return self.comparison_report

    def _selected_comparison(self):
        report = self._current_comparison()
        selection = self.comparison_tree.selection()
        if not selection:
            raise ValueError('Select a difference in the comparison table.')
        return report, self.comparison_entries[selection[0]]

    def _open_comparison(self):
        report, item = self._selected_comparison()
        self.vars['filter'].set('All')
        self.load_run(report['left_run'])
        candidates = self.tree.get_children()
        target = str(item['left_index'])
        if target not in candidates:
            overlapping = [(max(0., min(self.rows[int(key)]['end'], item['end'])
                          - max(self.rows[int(key)]['start'], item['start'])), key) for key in candidates]
            overlap, target = max(overlapping, default=(0., None))
            if overlap <= 0:
                target = None
        if target is not None:
            self.tree.selection_set(target); self.tree.see(target)
        else:
            self.tree.selection_remove(*self.tree.selection())
            self.focused_index = None
            self.status.set('First review opened. It has no labeled candidate for this difference; Play difference can still play the audio.')
        return item

    def open_comparison_interval(self):
        return self.guard(self._open_comparison)

    def play_comparison_difference(self):
        def action():
            item = self._open_comparison()
            self.play_range(item['start'], item['end'])
        return self.guard(action)

    def save_comparison(self):
        def action():
            report = self._current_comparison()
            directory = filedialog.askdirectory(title='Choose an output folder for a new comparison report',
                                                 initialdir=str(Path(report['left_run']).parent))
            if directory:
                destination = comparison.save_report(report, directory)
                self.comparison_status.set('Comparison report saved: ' + str(destination))
                return destination
        return self.guard(action)

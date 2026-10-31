"""Guided annotation controls and recoverable review actions."""
from pathlib import Path
import tkinter as tk
from tkinter import ttk

import core
import review_tools


class GuidedReviewMixin:
    def init_guided(self):
        self.loop_audio = tk.BooleanVar(value=False)
        self.playback_speed = tk.StringVar(value='1.0')
        self.draft_status = tk.StringVar(value='Forms are saved for recovery. Approval is always explicit.')
        self.review_progress = tk.StringVar(value='Prepare or load a recording to begin.')
        self.autosave_after = None
        self.undo_tokens = []

    def make_guided(self):
        page = self.guided_tab
        ttk.Label(page, text='Listen, label, then approve', font=('Segoe UI', 16, 'bold')).pack(anchor='w')
        ttk.Label(page, textvariable=self.review_progress).pack(anchor='w', pady=(2, 6))
        self.button_bar(page, [('Load run', self.choose_run), ('Previous', lambda:self.guided_next(-1)),
            ('Next', self.guided_next), ('Review list', lambda:self.tabs.select(self.review_tab)),
            ('Open in Praat', self.praat), ('Finish and save Praat', self.finish_praat)])
        sound = ttk.Frame(page); sound.pack(fill='x', pady=5)
        for text, command in [('Play interval', self.play_interval), ('Play context', self.play), ('Stop', self.stop_audio)]:
            ttk.Button(sound, text=text, command=command).pack(side='left', padx=(0, 6))
        ttk.Label(sound, text='Speed').pack(side='left', padx=(10, 5))
        ttk.Combobox(sound, textvariable=self.playback_speed, values=('1.0','0.85','0.75'), state='readonly', width=6).pack(side='left')
        ttk.Checkbutton(sound, text='Loop interval', variable=self.loop_audio).pack(side='left', padx=12)
        ttk.Checkbutton(sound, text='Play after Next', variable=self.autoplay).pack(side='left')
        self.guided_canvas = tk.Canvas(page, height=95, background='#f3f5f7', highlightthickness=0)
        self.guided_canvas.pack(fill='x', pady=6)
        self.guided_canvas.bind('<Configure>', self.redraw_selection)
        self.canvas.bind('<Configure>', self.redraw_selection)
        ttk.Label(page, textvariable=self.detail).pack(anchor='w')
        ttk.Label(page, textvariable=self.evidence, wraplength=1120).pack(anchor='w', pady=5)
        choices = [('Speaker and listener', 'speaker', [('FAN to child','FAN-CDS'),('FAN to adult','FAN-ADS'),
            ('MAN to child','MAN-CDS'),('MAN to adult','MAN-ADS'),('FAN ?','FAN-?'),('MAN ?','MAN-?'),('Unknown','?')]),
            ('Valence', 'valence', [('Positive','+1'),('Neutral','0'),('Negative','-1'),('Unknown','?')]),
            ('Arousal', 'arousal', [('High','+1'),('Low','-1'),('Unknown','?')])]
        for title, key, values in choices:
            box = ttk.LabelFrame(page, text=title, padding=5); box.pack(fill='x', pady=3)
            for caption, value in values:
                tk.Radiobutton(box, text=caption, variable=self.vars[key], value=value,
                    indicatoron=False, font=('Segoe UI', 11), padx=8, pady=6,
                    selectcolor='#dcecf5', relief='groove', borderwidth=1).pack(side='left', padx=3)
        bounds = ttk.Frame(page); bounds.pack(fill='x', pady=6)
        for key, title in [('start','Start seconds'),('end','End seconds')]:
            ttk.Label(bounds, text=title).pack(side='left', padx=(0, 5))
            ttk.Entry(bounds, textvariable=self.vars[key], width=12).pack(side='left', padx=(0, 12))
        ttk.Button(bounds, text='Apply boundaries', command=self.boundaries).pack(side='left')
        ttk.Label(bounds, text='Reviewer ID').pack(side='left', padx=(20, 5))
        ttk.Entry(bounds, textvariable=self.vars['reviewer'], width=18).pack(side='left')
        self.button_bar(page, [('Save labels', self.save_labels), ('Approve and next', self.approve_next),
            ('Exclude interval', self.exclude), ('Undo last change', self.undo_change), ('Export approved', self.export)])
        recovery = ttk.Frame(page); recovery.pack(fill='x', pady=4)
        ttk.Button(recovery, text='Restore saved form', command=self.restore_form).pack(side='left', padx=(0, 6))
        ttk.Button(recovery, text='Reset form', command=self.reset_form).pack(side='left')
        ttk.Label(recovery, textvariable=self.draft_status, wraplength=850).pack(side='left', padx=12)
        ttk.Label(page, text='FAN and MAN are LENA speaker classes. Follow your study protocol for emotion labels.\nNext saves valid form changes without approval. Ctrl+Enter approves; F5 plays context; Escape stops audio.',
                  wraplength=1100).pack(anchor='w', pady=4)

    def redraw_selection(self, event=None):
        if self.run and self.focused_index is not None and self.focused_index < len(self.rows):
            self.draw(self.rows[self.focused_index])

    def cancel_autosave(self):
        if self.autosave_after is not None:
            self.root.after_cancel(self.autosave_after)
            self.autosave_after = None

    def schedule_draft(self):
        self.cancel_autosave()
        if self.run and self.focused_index is not None and not self.praat_active():
            self.draft_status.set('Form changed. Saving recovery copy...')
            self.autosave_after = self.root.after(700, self.autosave_form)

    def autosave_form(self):
        self.autosave_after = None
        if not self.run or not self.dirty or self.focused_index is None or self.praat_active():
            return
        try:
            values = {key:self.vars[key].get() for key in ('speaker','valence','arousal','start','end')}
            review_tools.save_draft(self.run, self.focused_index, values, self.vars['reviewer'].get(), self.grid_hash)
            self.draft_status.set('Recovery form saved. Labels still need explicit saving or approval.')
        except (ValueError, OSError) as error:
            self.draft_status.set('Recovery form not saved: ' + str(error))

    def draft_notice(self):
        try:
            draft = review_tools.load_draft(self.run)
            self.draft_status.set('Saved form available. Choose Restore saved form to continue.' if draft else
                                  'Forms are saved for recovery. Approval is always explicit.')
        except (ValueError, OSError) as error:
            self.draft_status.set('Saved form needs attention: ' + str(error))

    def restore_form(self):
        def action():
            self.require_editable()
            draft = review_tools.load_draft(self.run)
            if not draft:
                self.draft_status.set('No recovery form is available.'); return
            self.dirty = False
            self.vars['filter'].set('All'); self.render()
            index = draft['index']
            if str(index) not in self.tree.get_children():
                raise ValueError('The saved form refers to an excluded interval.')
            self.tree.selection_set(str(index)); self.select()
            self.filling = True
            for key, value in draft['values'].items():self.vars[key].set(str(value))
            self.vars['reviewer'].set(draft['reviewer'])
            self.filling = False; self.dirty = True
            self.draft_status.set('Recovery form restored. Check it, then save or approve.')
        self.guard(action)

    def reset_form(self):
        def action():
            self.require_editable(); self.cancel_autosave()
            review_tools.clear_draft(self.run)
            self.dirty = False; self.reload_impl()
            self.draft_status.set('Form reset to the saved annotations.')
        self.guard(action)

    def record_edit(self, operation):
        self.require_editable(); self.cancel_autosave()
        if core.digest(self.run/'annotations.TextGrid') != self.grid_hash:
            raise ValueError('Annotations changed externally. Reload before saving.')
        if core.load_run(self.run)[2] != self.reviews:
            raise ValueError('Approvals changed externally. Reload before saving.')
        token = review_tools.checkpoint(self.run)
        try:
            result = operation()
        finally:
            token = review_tools.seal_checkpoint(self.run, token)
            if token['changed']:
                self.undo_tokens.append(token)
                self.undo_tokens = self.undo_tokens[-20:]
        review_tools.clear_draft(self.run)
        self.dirty = False
        self.draft_status.set('Saved. Undo is available for this session.')
        return result

    def undo_change(self):
        def action():
            self.require_editable(); self.cancel_autosave()
            if self.dirty:
                review_tools.clear_draft(self.run); self.dirty = False; self.reload_impl()
                self.draft_status.set('Unsaved form reset. Saved annotations were retained.'); return
            if not self.undo_tokens:raise ValueError('There is no saved change to undo in this session.')
            review_tools.undo(self.run, self.undo_tokens[-1], self.grid_hash)
            self.undo_tokens.pop()
            review_tools.clear_draft(self.run); self.reload_impl()
            self.draft_status.set('The previous annotations and approvals were restored.')
        self.guard(action)

    def guided_next(self, direction=1):
        def action():
            if self.dirty:self.save_labels_impl()
            self.next_candidate(direction)
        self.guard(action)

    def stop_audio(self):
        import winsound
        winsound.PlaySound(None, 0)

    def play_range(self, start, end, context=0., loop=False):
        import winsound
        self.require_run(); self.stop_audio()
        path = review_tools.make_playback(self.run, start, end, speed=float(self.playback_speed.get()), context=context)
        flags = winsound.SND_FILENAME | winsound.SND_ASYNC
        if loop:flags |= winsound.SND_LOOP
        winsound.PlaySound(str(path), flags)

    def play_interval(self):
        def action():
            row = self.rows[self.selected_index()]
            self.play_range(row['start'], row['end'], loop=self.loop_audio.get())
        self.guard(action)

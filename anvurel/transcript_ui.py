"""Transcript import, local generation, and links to annotation intervals."""
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, ttk
import uuid

import core
import transcripts


class TranscriptUIMixin:
    def init_transcripts(self, model_directory=None):
        self.transcript_document = None
        self.transcript_preview = tk.StringVar(master=self.root, value='No transcript attached to this excerpt.')
        self.transcript_status = tk.StringVar(master=self.root, value='Import a timed transcript or generate a local draft.')
        self.transcript_segment_detail = tk.StringVar(master=self.root, value='Select a text segment to play its exact audio interval.')
        self.transcript_vars = {
            'timeline': tk.StringVar(master=self.root, value='Excerpt'),
            'model': tk.StringVar(master=self.root, value='tiny'),
            'language': tk.StringVar(master=self.root, value='auto'),
        }
        self.transcript_download = tk.BooleanVar(master=self.root, value=False)
        self.transcript_model_directory = Path(model_directory) if model_directory else (
            Path(__file__).resolve().parent.parent / 'outputs/anvurel/models')
        self._transcript_operation = None

    def make_transcripts(self):
        page = self.transcript_tab
        ttk.Label(page, text='Transcript draft', font=('Segoe UI', 15, 'bold')).pack(anchor='w')
        ttk.Label(page, text='Use the text to find and check audio. Transcript text does not assign speaker, emotion, or approval labels.',
                  wraplength=1100).pack(anchor='w', pady=(3, 8))
        imported = ttk.LabelFrame(page, text='Import a timed transcript', padding=8)
        imported.pack(fill='x', pady=3)
        ttk.Label(imported, text='Times refer to').pack(side='left', padx=(0, 6))
        ttk.Combobox(imported, textvariable=self.transcript_vars['timeline'],
                     values=('Excerpt', 'Original recording'), state='readonly', width=21).pack(side='left', padx=(0, 12))
        ttk.Button(imported, text='Import JSON, SRT, or VTT', command=self.import_transcript_file).pack(side='left')
        generation = ttk.LabelFrame(page, text='Generate a transcript on this computer', padding=8)
        generation.pack(fill='x', pady=4)
        settings = ttk.Frame(generation); settings.pack(fill='x')
        ttk.Label(settings, text='Model').pack(side='left', padx=(0, 6))
        ttk.Combobox(settings, textvariable=self.transcript_vars['model'], values=transcripts.SUPPORTED_MODELS,
                     state='readonly', width=9).pack(side='left', padx=(0, 12))
        ttk.Label(settings, text='Language').pack(side='left', padx=(0, 6))
        ttk.Entry(settings, textvariable=self.transcript_vars['language'], width=9).pack(side='left', padx=(0, 12))
        ttk.Checkbutton(settings, text='Allow model download', variable=self.transcript_download).pack(side='left', padx=(0, 12))
        ttk.Button(settings, text='Generate transcript', command=self.generate_transcript).pack(side='left')
        ttk.Button(settings, text='Stop transcription', command=self.stop_transcription).pack(side='left', padx=6)
        ttk.Label(generation, text='Use auto to detect the language, or enter a language code such as en. Model downloads are off by default.\nThe installer includes the speech component. The source version needs setup_transcription.cmd.',
                  wraplength=1100).pack(anchor='w', pady=(6, 0))
        self.transcript_tree = self.table(page, ('start', 'end', 'text'), ('Start s', 'End s', 'Draft text'), (90, 90, 900))
        self.transcript_tree.bind('<<TreeviewSelect>>', self.select_transcript_segment)
        self.transcript_tree.bind('<Double-1>', lambda event: self.show_transcript_annotation())
        self.button_bar(page, [('Play text segment', self.play_transcript_segment),
                               ('Show matching annotation', self.show_transcript_annotation),
                               ('Refresh transcript', self.load_transcript_for_run)])
        ttk.Label(page, textvariable=self.transcript_segment_detail, wraplength=1100).pack(anchor='w', pady=4)
        ttk.Label(page, textvariable=self.transcript_status, wraplength=1100).pack(anchor='w', pady=4)

    def _fill_transcript_table(self):
        if not hasattr(self, 'transcript_tree'):
            return
        self.transcript_tree.delete(*self.transcript_tree.get_children())
        for index, segment in enumerate((self.transcript_document or {}).get('segments', [])):
            self.transcript_tree.insert('', 'end', iid=str(index), values=(
                f'{segment["start"]:.3f}', f'{segment["end"]:.3f}', segment['text']))
        children = self.transcript_tree.get_children()
        if children:
            self.transcript_tree.selection_set(children[0])
        else:
            self.transcript_segment_detail.set('No timed text segments are available.')

    def load_transcript_for_run(self):
        self.transcript_document = None
        try:
            if self.run is not None:
                self.transcript_document = transcripts.load(self.run)
            if self.transcript_document is None:
                self.transcript_status.set('No saved transcript for this excerpt. Import a timed transcript or generate a local draft.')
            else:
                count = len(self.transcript_document['segments'])
                self.transcript_status.set(f'{count} draft text segments loaded. Listen to confirm the words and timing.')
        except (OSError, ValueError, TypeError, KeyError) as error:
            self.transcript_status.set('Transcript needs attention: ' + str(error))
        self._fill_transcript_table()
        if self.run is not None and self.rows:
            try:
                row = self.rows[self.selected_index()]
            except (ValueError, IndexError):
                row = None
            if row is not None:
                self.update_transcript_selection(row)
                return
        self.transcript_preview.set('No transcript attached to this excerpt.')

    def update_transcript_selection(self, row):
        if self.transcript_document is None:
            self.transcript_preview.set('No transcript attached to this excerpt.')
            return
        segments = transcripts.for_interval(self.transcript_document, row['start'], row['end'])
        if not segments:
            self.transcript_preview.set('Draft transcript: no text overlaps this interval.')
            return
        text = ' '.join(segment['text'] for segment in segments)
        if len(text) > 400:
            text = text[:397] + '...'
        clipped = any(segment.get('clipped') for segment in segments)
        self.transcript_preview.set('Draft transcript: ' + text + (' [cue clipped at excerpt boundary]' if clipped else ''))

    def _require_transcript_action(self):
        self.require_run()
        if self.praat_active():
            raise ValueError('Finish and save Praat before working with transcript segments.')

    def _start_transcript_task(self, operation, message):
        self._require_transcript_action()
        if self.busy:
            raise ValueError('Wait for the current operation before working on the transcript.')
        if self.dirty:
            raise ValueError('Save or reset the current form before changing the transcript.')
        run = Path(self.run).resolve()
        token = uuid.uuid4().hex
        self._transcript_operation = (token, run)
        def progress(fraction, detail):
            self.events.put(('transcript_progress', token, str(run), (fraction, detail)))
        def task():
            try:
                document = operation(run, progress)
                self.events.put(('transcript_ready', token, str(run), document))
            except transcripts.TranscriptCancelled as error:
                self.events.put(('transcript_stopped', token, str(run), str(error)))
            except Exception as error:
                self.events.put(('transcript_error', token, str(run), str(error)))
        try:
            self.work(task)
        except Exception:
            self._transcript_operation = None
            raise
        self.transcript_status.set(message)
        self.status.set(message)

    def import_transcript_file(self, path=None):
        def action():
            self._require_transcript_action()
            filename = path or filedialog.askopenfilename(title='Choose a timed transcript', filetypes=[
                ('Timed transcripts', '*.json *.srt *.vtt'), ('All files', '*.*')])
            if not filename:
                return
            selected = self.transcript_vars['timeline'].get()
            timelines = {'Excerpt': 'excerpt', 'Original recording': 'original',
                         'excerpt': 'excerpt', 'original': 'original'}
            if selected not in timelines:
                raise ValueError('Choose whether imported times refer to the excerpt or the original recording.')
            timeline = timelines[selected]
            self._start_transcript_task(lambda run, progress: transcripts.import_transcript(run, filename, timeline=timeline),
                                        'Checking and importing transcript times...')
        self.guard(action)

    def generate_transcript(self):
        def action():
            model = self.transcript_vars['model'].get()
            language = self.transcript_vars['language'].get().strip()
            language = None if language.casefold() == 'auto' or not language else language
            allow_download = self.transcript_download.get()
            directory = self.transcript_model_directory
            cancelled = self.cancel.is_set
            self._start_transcript_task(lambda run, progress: transcripts.generate(
                run, model=model, model_directory=directory, allow_download=allow_download,
                language=language, progress=progress, cancelled=cancelled), 'Preparing a local transcript draft...')
        self.guard(action)

    def stop_transcription(self):
        if self._transcript_operation is not None and self.busy:
            self.cancel.set()
            self.transcript_status.set('Stopping after the current model or decoding step. The previous transcript will be retained.')

    def handle_transcript_event(self, event):
        if not event or event[0] not in ('transcript_ready', 'transcript_progress', 'transcript_error', 'transcript_stopped'):
            return False
        kind, token, run, payload = event
        current = self._transcript_operation
        if current != (token, Path(run).resolve()):
            return True
        if self.run is None or Path(self.run).resolve() != current[1]:
            if kind != 'transcript_progress':
                self._transcript_operation = None
            return True
        if kind == 'transcript_progress':
            fraction, message = payload
            self.transcript_status.set(f'{round(float(fraction) * 100)}%: {message}')
            self.status.set('Transcript: ' + message)
        else:
            self._transcript_operation = None
            if kind == 'transcript_ready':
                self.load_transcript_for_run()
                self.status.set('Transcript draft saved. Select text to play it or show its matching annotation.'
                                if self.transcript_document is not None else self.transcript_status.get())
            else:
                self.transcript_status.set(str(payload))
                self.status.set('Transcript: ' + str(payload))
        return True

    def _selected_transcript_segment(self):
        self._require_transcript_action()
        saved = transcripts.load(self.run)
        if saved is None:
            raise ValueError('Import or generate a transcript for this excerpt first.')
        if saved != self.transcript_document:
            raise ValueError('Transcript changed. Refresh the transcript before selecting a segment.')
        selection = self.transcript_tree.selection()
        if not selection:
            raise ValueError('Select a transcript segment first.')
        return saved['segments'][int(selection[0])]

    def select_transcript_segment(self, event=None):
        selection = self.transcript_tree.selection()
        if not selection or self.transcript_document is None:
            return
        segment = self.transcript_document['segments'][int(selection[0])]
        original = self.meta['source_offset']
        detail = (f'Excerpt {segment["start"]:.3f} to {segment["end"]:.3f} s. '
                  f'Original {segment["start"] + original:.3f} to {segment["end"] + original:.3f} s.')
        if segment.get('clipped'):
            detail += ' This cue crosses the excerpt boundary. Confirm its words by listening.'
        self.transcript_segment_detail.set(detail)

    def play_transcript_segment(self):
        def action():
            segment = self._selected_transcript_segment()
            self.play_range(segment['start'], segment['end'], context=0., loop=False)
        self.guard(action)

    def show_transcript_annotation(self):
        def action():
            if self.dirty:
                raise ValueError('Save or reset the current form before selecting another annotation.')
            segment = self._selected_transcript_segment()
            matches = [(max(0., min(segment['end'], row['end']) - max(segment['start'], row['start'])), index)
                       for index, row in enumerate(self.rows) if any(row[tier] for tier in core.TIERS)]
            matches = [(overlap, index) for overlap, index in matches if overlap > 0]
            if not matches:
                raise ValueError('No annotation overlaps this text segment. Listen to the audio and check its boundaries.')
            _, index = max(matches, key=lambda match: (match[0], -match[1]))
            self.vars['filter'].set('All')
            self.render()
            self.tree.selection_set(str(index))
            self.tree.see(str(index))
            self.select()
            self.tabs.select(self.guided_tab if hasattr(self, 'guided_tab') else self.review_tab)
        self.guard(action)

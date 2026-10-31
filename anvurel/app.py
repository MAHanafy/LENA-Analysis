"""ANVUREL desktop annotation assistant with local batch automation."""
import argparse
import json
import math
import os
import queue
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import automation
import batch
import core
import review_tools
from guided_ui import GuidedReviewMixin
from transcript_ui import TranscriptUIMixin
from comparison_ui import ComparisonUIMixin

BASE=Path(__file__).resolve().parent

class Application(GuidedReviewMixin,TranscriptUIMixin,ComparisonUIMixin):
    def __init__(self,root):
        self.root,self.run,self.rows=root,None,[]
        self.meta,self.reviews={},{}
        self.events=queue.Queue()
        self.cancel=threading.Event()
        self.busy,self.dirty,self.filling=False,False,False
        self.closing=False
        self.grid_hash,self.file_stamp=None,None
        self.focused_index=None
        self.praat_process,self.batch_path=None,None
        defaults={'source':'','its':'','output':str(BASE.parent/'outputs'/'anvurel'/'automation_runs'),
            'praat':str(BASE/'tools'/'Praat.exe'),'group':'Auto','offset':'0','length':'300',
            'reviewer':'','speaker':'?','valence':'?','arousal':'?','start':'','end':'',
            'folder':'','batch_group':'Auto','batch_mode':'first','filter':'Needs review'}
        self.vars={k:tk.StringVar(value=v) for k,v in defaults.items()}
        self.init_guided()
        self.init_transcripts(BASE.parent/'outputs'/'anvurel'/'models')
        self.init_comparison()
        self.refine=tk.BooleanVar(value=True);self.suggest=tk.BooleanVar(value=True)
        self.autoplay=tk.BooleanVar(value=False);self.autoreload=tk.BooleanVar(value=True)
        self.status=tk.StringVar(value='Select a recording or scan a folder. Processing stays local.')
        self.detail=tk.StringVar(value='Select a candidate to hear its context and review its labels.')
        self.evidence=tk.StringVar(value='No automatic valence or arousal model is included in this release.')
        root.title('ANVUREL Annotation Assistant '+automation.VERSION)
        root.geometry(f'{min(1280,root.winfo_screenwidth()-80)}x{min(950,root.winfo_screenheight()-90)}')
        root.minsize(1000,700)
        box=ttk.Frame(root,padding=10);box.pack(fill='both',expand=True)
        ttk.Label(box,text='ANVUREL Annotation Assistant',font=('Segoe UI',18,'bold')).pack(anchor='w')
        ttk.Label(box,text='Prepare folders • inspect suggestions • review in Praat • export approved samples').pack(anchor='w',pady=(0,7))
        self.tabs=ttk.Notebook(box);self.tabs.pack(fill='both',expand=True)
        self.prepare_tab,self.batch_tab,self.guided_tab,self.review_tab,self.transcript_tab,self.compare_tab=[ttk.Frame(self.tabs,padding=10) for _ in range(6)]
        for page,name in [(self.prepare_tab,'Prepare recording'),(self.batch_tab,'Batch preparation'),(self.guided_tab,'Guided review'),(self.review_tab,'Review samples'),(self.transcript_tab,'Transcript'),(self.compare_tab,'Compare reviewers')]:self.tabs.add(page,text=name)
        self.make_prepare();self.make_batch();self.make_review();self.make_guided();self.make_transcripts();self.make_comparison()
        ttk.Label(box,textvariable=self.status,wraplength=1180).pack(fill='x',pady=(7,0))
        for key in ('speaker','valence','arousal','start','end'):self.vars[key].trace_add('write',self.mark_dirty)
        root.bind('<Escape>',lambda e:self.stop_audio())
        for key,fn in [('<Control-s>',self.save_labels),('<Control-Return>',self.approve_next),('<Control-Right>',self.next_candidate),('<Control-Left>',lambda:self.next_candidate(-1)),('<F5>',self.play),('<F6>',self.praat)]:root.bind(key,lambda e,fn=fn:fn())
        root.after(300,self.poll);root.after(1000,self.watch)
        root.protocol('WM_DELETE_WINDOW',self.close)

    def close(self):
        if self.praat_active():
            messagebox.showinfo('Praat review','Finish and save the Praat session before closing ANVUREL.');return
        self.cancel.set()
        if self.busy:
            self.closing=True;self.status.set('Finishing the current excerpt before closing. Batch progress will be saved.');return
        self.cancel_autosave()
        if not self.autosave_form():
            messagebox.showinfo('Unsaved form','Correct the boundary times or reset the form before closing.');return
        self.stop_audio()
        for pending in self.root.tk.call('after','info'):
            self.root.after_cancel(pending)
        self.root.destroy()

    def entry(self,parent,row,key,label,kind='file'):
        ttk.Label(parent,text=label).grid(row=row,column=0,sticky='w',padx=(0,8),pady=5)
        ttk.Entry(parent,textvariable=self.vars[key]).grid(row=row,column=1,sticky='ew',pady=5)
        ttk.Button(parent,text='Browse',command=lambda:self.browse(key,kind)).grid(row=row,column=2,padx=(8,0))
        parent.columnconfigure(1,weight=1)

    def button_bar(self,parent,buttons):
        bar=ttk.Frame(parent);bar.pack(fill='x',pady=5)
        for label,fn in buttons:ttk.Button(bar,text=label,command=fn).pack(side='left',padx=(0,6))
        return bar

    def make_prepare(self):
        page=self.prepare_tab;fields=ttk.Frame(page);fields.pack(fill='x')
        for i,(key,label,kind) in enumerate([('source','WAV recording','file'),('its','Paired ITS optional','file'),('output','Output folder','dir'),('praat','Praat executable','file')]):self.entry(fields,i,key,label,kind)
        options=ttk.Frame(page);options.pack(fill='x',pady=10)
        for key,label,values in [('group','Group',('Auto','NH','HA','Reference')),('offset','Start seconds',None),('length','Excerpt seconds',None)]:
            ttk.Label(options,text=label).pack(side='left',padx=(0,6))
            widget=ttk.Combobox(options,textvariable=self.vars[key],values=values,state='readonly',width=12) if values else ttk.Entry(options,textvariable=self.vars[key],width=12)
            widget.pack(side='left',padx=(0,16))
        ttk.Checkbutton(page,text='Refine adult boundaries using Praat pauses',variable=self.refine).pack(anchor='w',pady=3)
        ttk.Checkbutton(page,text='Suggest CDS/ADS using LENA turn codes and nearby conversation turns',variable=self.suggest).pack(anchor='w',pady=3)
        ttk.Label(page,text='Suggestions remain unapproved. Conflicting interaction evidence stays uncertain.\nWithout ITS, sounding regions may include noise, TV or child vocalizations.\nThe default excerpt is five minutes; recordings are read in chunks.',wraplength=1050).pack(anchor='w',pady=12)
        bar=self.button_bar(page,[('Prepare draft',self.prepare),('Load existing run',self.choose_run)])
        self.prepare_button=bar.winfo_children()[0]
        ttk.Label(page,text='Prepare a draft, review its boundaries and labels, then explicitly approve usable samples.\nOld pilot runs remain readable. Independent raters should use separate run folders.',wraplength=1050).pack(anchor='w',pady=15)

    def make_batch(self):
        page=self.batch_tab;fields=ttk.Frame(page);fields.pack(fill='x')
        self.entry(fields,0,'folder','Recording folder','dir');self.entry(fields,1,'output','Output folder','dir')
        opts=ttk.Frame(page);opts.pack(fill='x',pady=8)
        for key,label,values in [('batch_group','Group override',('Auto','NH','HA','Reference')),('batch_mode','Excerpts',('first','all'))]:
            ttk.Label(opts,text=label).pack(side='left',padx=(0,6));ttk.Combobox(opts,textvariable=self.vars[key],values=values,state='readonly',width=14).pack(side='left',padx=(0,16))
        ttk.Label(opts,text='Seconds per excerpt').pack(side='left',padx=(0,6));ttk.Entry(opts,textvariable=self.vars['length'],width=10).pack(side='left')
        ttk.Label(page,text='first = first excerpt of each recording; all = every consecutive chunk. Auto group uses NH/HA folder names.\nRefinement and CDS/ADS settings come from Prepare recording. Scan first to check the workload.',wraplength=1100).pack(anchor='w',pady=(0,8))
        self.button_bar(page,[('Scan folder',self.scan_folder),('Prepare batch',self.prepare_batch),('Resume batch',self.resume_batch),('Stop after current excerpt',self.cancel.set),('Open selected run',self.open_batch_run)])
        self.batch_tree=self.table(page,('source','group','offset','status','detail'),('Recording','Group','Offset s','Status','Details'),(310,70,80,100,400))
        self.batch_tree.bind('<Double-1>',lambda e:self.open_batch_run())

    def table(self,page,cols,titles,widths):
        frame=ttk.Frame(page);frame.pack(fill='both',expand=True)
        tree=ttk.Treeview(frame,columns=cols,show='headings',selectmode='browse',height=9)
        for c,title,width in zip(cols,titles,widths):tree.heading(c,text=title);tree.column(c,width=width,anchor='w')
        scroll=ttk.Scrollbar(frame,orient='vertical',command=tree.yview);tree.configure(yscrollcommand=scroll.set)
        tree.pack(side='left',fill='both',expand=True);scroll.pack(side='right',fill='y')
        return tree

    def make_review(self):
        page=self.review_tab
        self.button_bar(page,[('Load run',self.choose_run),('Open selection in Praat',self.praat),('Finish and save Praat',self.finish_praat),('Reload',self.reload),('Align to speaker tier',self.align),('Run folder',self.folder)])
        filters=ttk.Frame(page);filters.pack(fill='x',pady=5)
        ttk.Label(filters,text='Show').pack(side='left',padx=(0,6))
        combo=ttk.Combobox(filters,textvariable=self.vars['filter'],values=('Needs review','Flagged first','All','Approved'),state='readonly',width=18)
        combo.pack(side='left');combo.bind('<<ComboboxSelected>>',lambda e:self.render())
        ttk.Checkbutton(filters,text='Auto reload saved TextGrid',variable=self.autoreload).pack(side='left',padx=12)
        ttk.Checkbutton(filters,text='Play after Next',variable=self.autoplay).pack(side='left',padx=8)
        self.tree=self.table(page,('interval','start','end','speaker','valence','arousal','flags','review'),('Interval','Start s','End s','Speaker / speech','Valence','Arousal','Flags','Review'),(55,75,75,125,60,60,260,95))
        self.tree.tag_configure('approved',foreground='#27603c');self.tree.tag_configure('flagged',foreground='#9b5111')
        self.tree.bind('<<TreeviewSelect>>',self.select)
        self.canvas=tk.Canvas(page,height=80,background='#f3f5f7',highlightthickness=0);self.canvas.pack(fill='x',pady=5)
        ttk.Label(page,textvariable=self.detail,wraplength=1160).pack(anchor='w')
        ttk.Label(page,textvariable=self.evidence,wraplength=1160).pack(anchor='w',pady=4)
        form=ttk.Frame(page);form.pack(fill='x',pady=5)
        for key,label,values,width in [('speaker','Speaker / speech',('?', 'FAN-?', 'MAN-?')+core.SPEAKERS,14),('valence','Valence',('?', '+1','0','-1'),5),('arousal','Arousal',('?', '+1','-1'),5)]:
            ttk.Label(form,text=label).pack(side='left',padx=(0,6));ttk.Combobox(form,textvariable=self.vars[key],values=values,state='readonly',width=width).pack(side='left',padx=(0,12))
        ttk.Button(form,text='Save labels  Ctrl+S',command=self.save_labels).pack(side='left',padx=4)
        ttk.Button(form,text='Play context  F5',command=self.play).pack(side='left',padx=4)
        bounds=ttk.Frame(page);bounds.pack(fill='x',pady=4)
        for key,label in [('start','Start seconds'),('end','End seconds')]:
            ttk.Label(bounds,text=label).pack(side='left',padx=(0,5));ttk.Entry(bounds,textvariable=self.vars[key],width=12).pack(side='left',padx=(0,10))
        ttk.Button(bounds,text='Apply boundaries to all tiers',command=self.boundaries).pack(side='left',padx=4)
        ttk.Button(bounds,text='Exclude selected',command=self.exclude).pack(side='left',padx=4)
        bottom=ttk.Frame(page);bottom.pack(fill='x',pady=5)
        ttk.Label(bottom,text='Reviewer ID').pack(side='left');ttk.Entry(bottom,textvariable=self.vars['reviewer'],width=15).pack(side='left',padx=6)
        for text,fn in [('Previous',lambda:self.next_candidate(-1)),('Next',self.next_candidate),('Save approve and next',self.approve_next),('Export approved',self.export)]:ttk.Button(bottom,text=text,command=fn).pack(side='left',padx=4)
        ttk.Label(page,text='Ctrl+Enter: save, approve, next • Ctrl+arrows: navigate • F6: Praat. Finish Praat before app edits or approval.\nValence and arousal remain human labels. Suggested CDS/ADS is not a validated probability.',wraplength=1100).pack(anchor='w',pady=(4,0))

    def mark_dirty(self,*args):
        if not self.filling:
            self.dirty=True;self.schedule_draft()

    def guard(self,action):
        try:return action()
        except Exception as e:messagebox.showerror('ANVUREL',str(e));return None

    def work(self,task):
        if self.busy:raise ValueError('Wait for the current job or stop the batch after its current excerpt.')
        self.busy=True;self.cancel.clear();self.prepare_button.state(['disabled'])
        def worker():
            try:task()
            except Exception as e:self.events.put(('error',str(e)))
            finally:self.events.put(('idle',))
        threading.Thread(target=worker,daemon=True).start()

    def browse(self,key,kind):
        path=filedialog.askdirectory() if kind=='dir' else filedialog.askopenfilename()
        if path:
            self.vars[key].set(path)
            if key=='source':
                sibling=Path(path).with_suffix('.its');self.vars['its'].set(str(sibling) if sibling.exists() else '')

    def prepare(self):
        def action():
            args={k:v.get() for k,v in self.vars.items()};refine,suggest=self.refine.get(),self.suggest.get()
            self.status.set('Preparing excerpt, suggestions, quality flags and Praat measurements...')
            def task():
                group=batch.infer_group(args['source']) if args['group']=='Auto' else args['group']
                run=core.prepare(args['source'],args['output'],group,float(args['offset']),float(args['length']),args['its'] or None,refine=refine,suggest=suggest)
                self.events.put(('ready',run))
            self.work(task)
        self.guard(action)

    def scan_folder(self):
        def action():
            folder,output=self.vars['folder'].get(),self.vars['output'].get()
            self.work(lambda:self.events.put(('scan',batch.scan(folder,output))))
            self.status.set('Scanning headers and WAV/ITS pairs...')
        self.guard(action)

    def prepare_batch(self):
        def action():
            args={k:v.get() for k,v in self.vars.items()};refine,suggest=self.refine.get(),self.suggest.get()
            def task():
                path=batch.create(args['folder'],args['output'],chunk=float(args['length']),mode=args['batch_mode'],group=args['batch_group'],refine=refine,suggest=suggest)
                self.events.put(('batch_path',path));self.run_batch_task(path)
            self.work(task);self.status.set('Creating preparation queue...')
        self.guard(action)

    def run_batch_task(self,path):
        result=batch.run(path,progress=lambda i,n,j:self.events.put(('progress',i,n,dict(j))),cancelled=self.cancel.is_set)
        self.events.put(('batch_done',path,result))

    def resume_batch(self):
        path=filedialog.askdirectory(title='Choose a batch folder containing batch.json')
        if path:self.guard(lambda:self.work(lambda:(self.events.put(('batch_path',Path(path))),self.run_batch_task(path))))

    def open_batch_run(self):
        def action():
            selection=self.batch_tree.selection()
            if not selection or not self.batch_path:raise ValueError('Select a prepared batch row first.')
            job=batch.load(self.batch_path)['jobs'][int(selection[0])]
            if not job.get('run'):raise ValueError('This excerpt has not completed preparation.')
            self.load_run(self.batch_path/job['run'])
        self.guard(action)

    def fill_batch(self,jobs):
        self.batch_tree.delete(*self.batch_tree.get_children())
        for i,j in enumerate(jobs):
            detail=j.get('error') or j.get('run') or f'{j.get("duration",j.get("length",0)):.1f} seconds'
            self.batch_tree.insert('', 'end',iid=str(i),values=(Path(j['source']).name,j['group'],f'{j.get("offset",0):.1f}',j.get('status','paired' if j.get('its') else 'no ITS'),detail))

    def poll(self):
        try:
            while True:
                ev=self.events.get_nowait()
                if self.handle_transcript_event(ev):continue
                if ev[0]=='idle':
                    self.busy=False;self.prepare_button.state(['!disabled'])
                    if self.closing:self.close();return
                elif ev[0]=='error':self.status.set(ev[1]);messagebox.showerror('ANVUREL',ev[1])
                elif ev[0]=='ready':self.guard(lambda:self.load_run(ev[1]))
                elif ev[0]=='scan':
                    self.batch_path=None;self.fill_batch(ev[1]);count=sum(bool(r['its']) for r in ev[1])
                    self.status.set(f'{len(ev[1])} WAV files found; {count} have ITS pairs. Choose first or all excerpts before preparing.')
                elif ev[0]=='batch_path':self.batch_path=Path(ev[1]);self.fill_batch(batch.load(self.batch_path)['jobs'])
                elif ev[0]=='progress':
                    i,n,j=ev[1:];self.fill_batch(batch.load(self.batch_path)['jobs']);self.status.set(f'Batch {i}/{n}: {j["status"]} | {Path(j["source"]).name} | {j.get("error","")}')
                elif ev[0]=='batch_done':
                    self.batch_path=Path(ev[1]);self.fill_batch(ev[2]['jobs']);done=sum(j['status']=='done' for j in ev[2]['jobs'])
                    self.status.set(f'Batch saved: {done}/{len(ev[2]["jobs"])} completed. Resume continues unfinished jobs. {self.batch_path}')
        except queue.Empty:pass
        self.root.after(300,self.poll)

    def require_run(self):
        if self.run is None:raise ValueError('Prepare or load a run first.')

    def praat_active(self):return self.praat_process is not None and self.praat_process.poll() is None

    def require_editable(self):
        self.require_run()
        if self.praat_active():raise ValueError('Finish and save Praat before editing or approving in the app.')

    def choose_run(self):
        if self.praat_active():messagebox.showinfo('Praat review','Finish and save Praat before switching runs.');return
        path=filedialog.askdirectory(title='Choose a run folder containing run.json')
        if path:self.guard(lambda:self.load_run(path))

    def load_run(self,path):
        if self._transcript_operation is not None and self.busy:raise ValueError('Stop transcription and wait for it to finish before switching runs.')
        candidate=Path(path).resolve()
        if self.praat_active():raise ValueError('Finish Praat before loading a run.')
        core.load_run(candidate)
        self.cancel_autosave()
        if not self.autosave_form():raise ValueError('Save or reset the current form before switching runs.')
        self.stop_audio()
        if self.run!=candidate:self.undo_tokens=[]
        self.run=candidate;self.dirty=False;self.focused_index=None;self.reload_impl();self.tabs.select(self.guided_tab);self.draft_notice()

    def reload(self):
        self.cancel_autosave()
        self.dirty=False
        self.guard(self.reload_impl)

    def reload_impl(self):
        self.require_run();self.meta,self.rows,self.reviews=core.load_run(self.run)
        self.grid_hash=core.digest(self.run/'annotations.TextGrid')
        stat=(self.run/'annotations.TextGrid').stat();self.file_stamp=(stat.st_mtime_ns,stat.st_size)
        self.notes=json.loads((self.run/'suggestions.json').read_text(encoding='utf-8')) if (self.run/'suggestions.json').exists() else []
        self.quality={q['interval']-1:q for q in automation.quality_metrics(self.run/'excerpt.wav',self.rows)}
        self.rate,self.samples=core.mono_audio(self.run/'excerpt.wav')
        self.filling=True
        for key,value in [('source',self.meta['source']),('its',self.meta.get('its_source') or ''),('group',self.meta['group']),('offset',str(self.meta['source_offset']))]:self.vars[key].set(value)
        self.filling=False;self.dirty=False;self.render()
        self.load_transcript_for_run()
        approved=sum(core.valid(r) and core.signature(r) in self.reviews for r in self.rows)
        count=sum(any(r[t] for t in core.TIERS) for r in self.rows)
        self.review_progress.set(f'{approved} of {count} candidates approved. Unknown labels remain for review.')
        self.status.set(f'{self.run.name} | {self.meta["group"]} | {count} candidates | {approved} approved | source offset {self.meta["source_offset"]:.3f} s')

    def render(self):
        if self.run is None:return
        if self.dirty:
            self.status.set('Save or reload edits before changing the review filter.');return
        selected=self.tree.selection();selected=selected[0] if selected else None
        self.tree.delete(*self.tree.get_children());items=[]
        for i,r in enumerate(self.rows):
            if not any(r[t] for t in core.TIERS):continue
            approved=core.valid(r) and core.signature(r) in self.reviews
            flags=sorted(set(self.quality.get(i,{}).get('flags',[])+automation.evidence_for(r,self.notes).get('flags',[])))
            if self.vars['filter'].get()=='Needs review' and approved:continue
            if self.vars['filter'].get()=='Approved' and not approved:continue
            items.append((i,r,approved,flags))
        if self.vars['filter'].get()=='Flagged first':items.sort(key=lambda x:(not bool(x[3]),x[0]))
        for i,r,approved,flags in items:
            self.tree.insert('', 'end',iid=str(i),values=(i+1,f'{r["start"]:.3f}',f'{r["end"]:.3f}',r['speaker_speech'],r['valence'],r['arousal'],', '.join(flags),'Approved' if approved else 'Needs review'),tags=('approved' if approved else 'flagged' if flags else '',))
        ids=self.tree.get_children()
        if ids:self.tree.selection_set(selected if selected in ids else ids[0])

    def selected_index(self):
        self.require_run()
        if not self.tree.selection():raise ValueError('Select a candidate first.')
        return int(self.tree.selection()[0])

    def select(self,event=None):
        if not self.tree.selection():return
        index=int(self.tree.selection()[0])
        if self.dirty:
            if self.focused_index is not None and str(self.focused_index) in self.tree.get_children():
                if index!=self.focused_index:self.tree.selection_set(str(self.focused_index))
            self.status.set('Unsaved edits retained. Save or Reload before selecting another candidate.');return
        self.focused_index=index
        self.stop_audio()
        candidates=[i for i,r in enumerate(self.rows) if any(r[t] for t in core.TIERS)]
        approved=sum(core.valid(r) and core.signature(r) in self.reviews for r in self.rows)
        if index in candidates:self.review_progress.set(f'Candidate {candidates.index(index)+1} of {len(candidates)} | {approved} approved')
        row=self.rows[index];self.filling=True
        for key,tier in [('speaker','speaker_speech'),('valence','valence'),('arousal','arousal')]:self.vars[key].set(row[tier])
        self.vars['start'].set(f'{row["start"]:.6f}');self.vars['end'].set(f'{row["end"]:.6f}')
        self.filling=False;self.dirty=False
        self.detail.set(f'Excerpt {row["start"]:.3f}–{row["end"]:.3f} s | Original {self.meta["source_offset"]+row["start"]:.3f}–{self.meta["source_offset"]+row["end"]:.3f} s')
        ev=automation.evidence_for(row,self.notes)
        descriptions=[f'{e["pair"]} ({e["source"]}, gap {e["gap_seconds"]:.2f}s)' for e in ev.get('evidence',[])[:3]]
        self.evidence.set('Initial suggestion: '+ev['reason']+(' | '+'; '.join(descriptions) if descriptions else '')+'. Human review required.')
        self.draw(row)
        self.update_transcript_selection(row)

    def draw(self,row):
        a=max(0,row['start']-1);b=min(self.meta['duration'],row['end']+1)
        x=self.samples[round(a*self.rate):round(b*self.rate)]
        for canvas in (self.canvas,self.guided_canvas):
            canvas.delete('all');w=max(canvas.winfo_width(),100);h=max(canvas.winfo_height(),80)
            canvas.create_rectangle(w*(row['start']-a)/(b-a),0,w*(row['end']-a)/(b-a),h,fill='#e3edf4',outline='')
            step=max(1,len(x)//w)
            for k,start in enumerate(range(0,len(x),step)):
                if k>=w:break
                chunk=x[start:start+step];canvas.create_line(k,h/2-float(chunk.max())*h*.45,k,h/2-float(chunk.min())*h*.45,fill='#245d78')

    def save_labels_impl(self,approve=False):
        self.require_editable();idx=self.selected_index();_,rows,_=core.load_run(self.run)
        if rows!=self.rows:raise ValueError('TextGrid changed externally. Reload before saving.')
        start,end=float(self.vars['start'].get()),float(self.vars['end'].get())
        if not all(math.isfinite(value) for value in (start,end)) or abs(start-rows[idx]['start'])>1e-6 or abs(end-rows[idx]['end'])>1e-6:raise ValueError('Apply valid boundary changes before saving labels.')
        rows[idx].update(speaker_speech=self.vars['speaker'].get(),valence=self.vars['valence'].get(),arousal=self.vars['arousal'].get())
        if approve and (not self.vars['reviewer'].get().strip() or not core.valid(rows[idx])):
            raise ValueError('Enter a reviewer ID and complete all labels before approval.')
        def operation():
            core.save_annotations(self.run,rows,self.grid_hash)
            if approve:core.approve(self.run,idx,self.vars['reviewer'].get())
        self.record_edit(operation);self.reload_impl()
        if str(idx) in self.tree.get_children():self.tree.selection_set(str(idx))
        return idx

    def save_labels(self):self.guard(self.save_labels_impl)

    def approve_next(self):
        def action():
            idx=self.save_labels_impl(approve=True)
            self.reload_impl();ids=self.tree.get_children();following=next((x for x in ids if int(x)>idx),ids[0] if ids else None)
            if following:self.tree.selection_set(following);self.tree.see(following)
            if self.autoplay.get() and following:self.root.after(50,self.play)
        self.guard(action)

    def boundaries(self):
        def action():
            self.require_editable();idx=self.selected_index()
            labels=dict(speaker_speech=self.vars['speaker'].get(),valence=self.vars['valence'].get(),arousal=self.vars['arousal'].get())
            self.record_edit(lambda:core.set_boundaries(self.run,idx,float(self.vars['start'].get()),float(self.vars['end'].get()),self.grid_hash,labels=labels))
            self.reload_impl()
            if str(idx) in self.tree.get_children():self.tree.selection_set(str(idx))
        self.guard(action)

    def align(self):
        def action():
            self.require_editable()
            if self.dirty:raise ValueError('Save or Reload current form edits before aligning tiers.')
            self.record_edit(lambda:core.synchronize_tiers(self.run,core.digest(self.run/'annotations.TextGrid')));self.reload_impl()
        self.guard(action)

    def exclude(self):
        def action():
            self.require_editable();idx=self.selected_index();_,rows,_=core.load_run(self.run)
            if rows!=self.rows:raise ValueError('Reload changed annotations before excluding.')
            rows[idx].update(**{t:'' for t in core.TIERS});self.record_edit(lambda:core.save_annotations(self.run,rows,self.grid_hash,action='excluded'));self.reload_impl()
        self.guard(action)

    def next_candidate(self,direction=1):
        def action():
            if self.dirty:raise ValueError('Save or reload current edits before navigating.')
            ids=self.tree.get_children();selected=str(self.selected_index())
            if not ids:return
            target=ids[(ids.index(selected)+direction)%len(ids)];self.tree.selection_set(target);self.tree.see(target)
            if self.praat_active():
                row=self.rows[int(target)];core.navigate_praat(self.vars['praat'].get(),self.run,row['start'],row['end'])
            if self.autoplay.get():self.root.after(50,self.play)
        self.guard(action)

    def play(self):
        def action():
            row=self.rows[self.selected_index()];self.play_range(row['start'],row['end'],context=1.)
        self.guard(action)

    def praat(self):
        def action():
            self.require_run()
            if self.dirty:raise ValueError('Save form edits before opening Praat.')
            self.stop_audio();self.cancel_autosave()
            row=self.rows[self.selected_index()]
            if self.praat_active():core.navigate_praat(self.vars['praat'].get(),self.run,row['start'],row['end'])
            else:self.praat_process=core.open_praat(self.vars['praat'].get(),self.run,row['start'],row['end'])
            self.status.set('Praat review active. Finish and save Praat before editing or approving in this app.')
        self.guard(action)

    def finish_praat(self):
        def action():
            self.require_run()
            if not self.praat_active():self.praat_process=None;self.reload_impl();return
            core.require_single_praat()
            script=core.review_script(self.run,close=True)
            subprocess.Popen([str(Path(self.vars['praat'].get()).resolve()),'--send',str(script)])
            self.status.set('Saving the dedicated Praat session. The app reloads when it closes.')
        self.guard(action)

    def watch(self):
        try:
            if self.run:
                ended=self.praat_process is not None and self.praat_process.poll() is not None
                if ended:self.praat_process=None
                stat=(self.run/'annotations.TextGrid').stat();stamp=(stat.st_mtime_ns,stat.st_size)
                if ended or self.autoreload.get() and stamp!=self.file_stamp:
                    if self.dirty:self.status.set('TextGrid changed externally. Unsaved form retained; Reload discards that form.')
                    else:
                        try:self.reload_impl()
                        except Exception as e:self.file_stamp=stamp;self.status.set('Saved TextGrid needs attention: '+str(e)+' Use Align to speaker tier if appropriate.')
        except OSError as e:self.status.set(str(e))
        self.root.after(1000,self.watch)

    def export(self):
        def action():
            self.require_editable()
            if self.dirty:raise ValueError('Save or reload form edits before export.')
            dest=core.export(self.run);self.status.set('Export complete: '+str(dest));messagebox.showinfo('Export complete',str(dest))
        self.guard(action)

    def folder(self):self.guard(lambda:(self.require_run(),os.startfile(self.run)))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare',metavar='WAV');parser.add_argument('--its')
    parser.add_argument('--output',default=str(BASE.parent/'outputs'/'anvurel'/'automation_runs'))
    parser.add_argument('--group',choices=['Auto','NH','HA','Reference'],default='Auto')
    parser.add_argument('--offset',type=float,default=0);parser.add_argument('--length',type=float,default=300)
    parser.add_argument('--no-refine',action='store_true');parser.add_argument('--no-suggest',action='store_true')
    parser.add_argument('--batch',metavar='FOLDER');parser.add_argument('--mode',choices=['first','all'],default='first')
    parser.add_argument('--resume',metavar='BATCH_FOLDER');parser.add_argument('--export',metavar='RUN_FOLDER')
    parser.add_argument('--sync',metavar='RUN_FOLDER');parser.add_argument('--load',metavar='RUN_FOLDER')
    parser.add_argument('--pilot',action='store_true',help='Open the latest prepared pilot in this project')
    args=parser.parse_args()
    if args.prepare:print(core.prepare(args.prepare,args.output,args.group if args.group!='Auto' else batch.infer_group(args.prepare),args.offset,args.length,args.its,refine=not args.no_refine,suggest=not args.no_suggest))
    elif args.batch or args.resume:
        path=Path(args.resume) if args.resume else batch.create(args.batch,args.output,chunk=args.length,mode=args.mode,group=args.group,refine=not args.no_refine,suggest=not args.no_suggest)
        print('Batch:',path,flush=True);batch.run(path,progress=lambda i,n,j:print(f'{i}/{n}: {j["status"]} {Path(j["source"]).name}',flush=True))
    elif args.export:print(core.export(args.export))
    elif args.sync:core.synchronize_tiers(args.sync);print('Aligned:',args.sync)
    else:
        root=tk.Tk();app=Application(root)
        if args.load:app.guard(lambda:app.load_run(args.load))
        elif args.pilot:
            pointer=BASE.parent/'outputs'/'anvurel'/'latest_pilot.json'
            if pointer.exists():
                data=json.loads(pointer.read_text(encoding='utf-8'))
                app.guard(lambda:app.load_run(pointer.parent/data['run']))
            else:app.status.set('No saved pilot yet. Prepare a recording or load an existing run.')
        root.mainloop()

if __name__=='__main__':main()

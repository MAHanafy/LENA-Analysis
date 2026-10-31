"""Persistent, restartable local preparation queue. Never overwrites a reviewed run."""
import contextlib
import hashlib
import json
import math
import os
import time
import uuid
from datetime import datetime
from pathlib import Path

import core

SKIP_DIRS={'.git','.venv','__pycache__','tools','outputs','runs','history'}

def infer_group(path):
    return next((p.upper() for p in reversed(Path(path).resolve().parent.parts) if p.upper() in ('NH','HA')), 'Reference')

def fingerprint(path):
    p=Path(path)
    stat=p.stat()
    return dict(path=str(p.resolve()),size=stat.st_size,mtime_ns=stat.st_mtime_ns)

def scan(folder, output=None):
    root=Path(folder).resolve()
    if not root.is_dir(): raise ValueError('Recording folder does not exist: '+str(root))
    output=Path(output).resolve() if output else None
    found=[]
    for current,dirs,files in os.walk(root,followlinks=False):
        dirs[:]=sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith('batch_')
                       and not d.startswith('run_') and not Path(current,d).is_symlink()
                       and (output is None or Path(current,d).resolve()!=output))
        names={f.lower():f for f in files}
        for name in sorted(files):
            if not name.lower().endswith('.wav'): continue
            wav=Path(current,name)
            if wav.is_symlink(): continue
            its_name=names.get((wav.stem+'.its').lower())
            group=infer_group(wav)
            try:
                info=core.audio_info(wav)
                if info['duration']<=0: raise ValueError('Empty audio')
                found.append(dict(source=str(wav),its=str(wav.with_name(its_name)) if its_name else None,
                                  group=group,duration=info['duration'],error=''))
            except Exception as e:
                found.append(dict(source=str(wav),its=None,group=group,duration=0.,error=str(e) or type(e).__name__))
    return found

def create(folder, output, *, chunk=300., mode='first', group='Auto', refine=True, suggest=True):
    if not math.isfinite(chunk) or not 0<chunk<=3600: raise ValueError('Chunk duration must be between 0 and 3600 seconds.')
    if mode not in ('first','all'): raise ValueError('Batch mode must be first or all.')
    if group not in ('Auto','NH','HA','Reference'): raise ValueError('Invalid group override.')
    folder,output=Path(folder).resolve(),Path(output).resolve()
    if folder==output: raise ValueError('Choose an output folder different from the recording folder.')
    recordings=scan(folder,output)
    if not recordings: raise ValueError('No WAV recordings found in this folder.')
    jobs=[]
    for r in recordings:
        if r['error']:
            jobs.append(dict(r,offset=0.,length=0.,status='blocked',run=None,error=r['error']))
            continue
        identity=dict(wav=fingerprint(r['source']),its=fingerprint(r['its']) if r['its'] else None)
        if r['its']: identity['its']['sha256']=core.digest(r['its'])
        n=1 if mode=='first' else math.ceil(r['duration']/chunk)
        for k in range(n):
            offset=k*chunk
            job=dict(source=r['source'],its=r['its'],group=r['group'] if group=='Auto' else group,
                     offset=offset,length=min(chunk,r['duration']-offset),identity=identity,
                     status='pending',run=None,error='')
            key=json.dumps(dict(identity=identity,offset=offset,chunk=chunk,refine=refine,suggest=suggest,group=job['group']),sort_keys=True)
            job['id']=hashlib.sha256(key.encode()).hexdigest()[:20]
            jobs.append(job)
    path=output/('batch_'+datetime.now().strftime('%Y%m%d_%H%M%S_')+uuid.uuid4().hex[:8])
    path.mkdir(parents=True,exist_ok=False)
    core.save_json(path/'batch.json',dict(version=2,created_utc=core.now(),input_folder=str(folder),
                     chunk=chunk,mode=mode,refine=refine,suggest=suggest,jobs=jobs))
    report(path)
    return path

@contextlib.contextmanager
def queue_lock(path):
    """An OS lock releases automatically after process termination."""
    lock=Path(path)/'.queue.lock'
    f=lock.open('a+b')
    try:
        f.seek(0,2)
        if f.tell()==0: f.write(b'0');f.flush()
        f.seek(0)
        if os.name=='nt':
            import msvcrt
            msvcrt.locking(f.fileno(),msvcrt.LK_NBLCK,1)
        else:
            import fcntl
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except OSError:
        f.close()
        raise ValueError('This batch is already being processed in another application.')
    try:
        yield
    finally:
        f.seek(0)
        if os.name=='nt':
            msvcrt.locking(f.fileno(),msvcrt.LK_UNLCK,1)
        else:
            fcntl.flock(f,fcntl.LOCK_UN)
        f.close()

def load(path):
    return json.loads((Path(path)/'batch.json').read_text(encoding='utf-8'))

def report(path):
    data=load(path)
    rows=[dict(recording=j['source'],group=j['group'],offset=j['offset'],length=j['length'],
               status=j['status'],run=j.get('run') or '',error=j.get('error',''),
               seconds=j.get('processing_seconds','')) for j in data['jobs']]
    core.write_csv(Path(path)/'batch_report.csv',rows,['recording','group','offset','length','status','run','error','seconds'])

def run(path, progress=None, cancelled=None):
    path=Path(path).resolve()
    with queue_lock(path):
        data=load(path)
        for i,job in enumerate(data['jobs']):
            if cancelled and cancelled(): break
            if job['status'] in ('done','blocked'):
                if job['status']=='done' and not (path/job['run']/'run.json').exists():
                    job.update(status='needs_check',error='Completed run missing. Restore it or create a new batch; no reviewed data was overwritten.')
                if progress: progress(i+1,len(data['jobs']),job)
                continue
            if job['status']=='needs_check': continue
            started=time.monotonic()
            try:
                for key,filename in [('wav',job['source']),('its',job['its'])]:
                    if filename:
                        actual=fingerprint(filename)
                        expected={k:v for k,v in job['identity'][key].items() if k!='sha256'}
                        if actual!=expected: raise ValueError('Source changed since batch creation; create a new batch.')
                        if key=='its' and core.digest(filename)!=job['identity'][key]['sha256']:
                            raise ValueError('ITS content changed since batch creation.')
                # A checkpoint is written before processing; failed or interrupted jobs can be retried.
                job.update(status='running',error='')
                core.save_json(path/'batch.json',data)
                if progress: progress(i+1,len(data['jobs']),job)
                output=core.prepare(job['source'],path/'runs',job['group'],job['offset'],job['length'],job['its'],
                                    refine=data['refine'],suggest=data['suggest'])
                job.update(status='done',run=str(output.relative_to(path)),error='')
            except Exception as e:
                job.update(status='failed',error=str(e) or type(e).__name__)
            job['processing_seconds']=round(time.monotonic()-started,3)
            core.save_json(path/'batch.json',data)
            report(path)
            if progress: progress(i+1,len(data['jobs']),job)
        core.save_json(path/'batch.json',data)
        report(path)
        return data

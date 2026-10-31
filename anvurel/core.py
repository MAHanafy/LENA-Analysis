"""Local annotation preparation and reviewed export. No external AI calls."""
from __future__ import annotations
import csv
import hashlib
import itertools
import json
import math
import shutil
import subprocess
import uuid
import wave
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import parselmouth
from parselmouth.praat import call

TIERS = ('speaker_speech', 'valence', 'arousal')
SPEAKERS = ('FAN-CDS', 'FAN-ADS', 'MAN-CDS', 'MAN-ADS')

def now():
    return datetime.now(timezone.utc).isoformat()

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def save_json(path, data):
    path = Path(path)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, indent=2, allow_nan=False), encoding='utf-8')
    temp.replace(path)

def write_csv(path, rows, fields):
    with Path(path).open('w', newline='', encoding='utf-8-sig') as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)

def audio_info(path):
    with wave.open(str(path), 'rb') as w:
        return dict(rate=w.getframerate(), channels=w.getnchannels(),
                    width=w.getsampwidth(), frames=w.getnframes(),
                    duration=w.getnframes() / w.getframerate())

def copy_audio(source, dest, start, end):
    """Copy PCM bytes, preserving channels and sample format."""
    info = audio_info(source)
    if not (math.isfinite(start) and math.isfinite(end) and 0 <= start < end <= info['duration'] + 1e-7):
        raise ValueError('Audio interval is outside the recording.')
    lo, hi = round(start * info['rate']), round(end * info['rate'])
    if hi <= lo:
        raise ValueError('Interval is shorter than one sample.')
    with wave.open(str(source), 'rb') as src, wave.open(str(dest), 'wb') as dst:
        dst.setparams(src.getparams())
        src.setpos(lo)
        data = src.readframes(hi - lo)
        if len(data) != (hi - lo) * info['channels'] * info['width']:
            raise ValueError('Recording is truncated.')
        dst.writeframes(data)
    return lo / info['rate'], hi / info['rate']

def mono_audio(path):
    with wave.open(str(path), 'rb') as w:
        rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        a = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        a = (a ^ 0x800000) - 0x800000
    elif width in (1, 2, 4):
        a = np.frombuffer(raw, dtype={1: 'u1', 2: '<i2', 4: '<i4'}[width]).astype(float)
        if width == 1:
            a -= 128
    else:
        raise ValueError('Use uncompressed PCM WAV with 8, 16, 24, or 32 bit samples.')
    a = (a / (2 ** (width * 8 - 1))).reshape(-1, channels).mean(axis=1)
    return rate, a

def energy_candidates(path):
    """Energy regions, not validated speech detection or utterance boundaries."""
    rate, x = mono_audio(path)
    n = max(1, round(rate * .02))
    rms = np.array([np.sqrt(np.mean(x[i:i+n] ** 2)) for i in range(0, len(x), n)])
    db = 20 * np.log10(np.maximum(rms, 1e-10))
    threshold = max(-50., min(-25., float(np.percentile(db, 20)) + 10))
    active = np.flatnonzero(db > threshold)
    groups = []
    for idx in active:
        start, end = idx * n / rate, min(len(x), (idx + 1) * n) / rate
        if groups and start - groups[-1][1] <= .2:
            groups[-1][1] = end
        else:
            groups.append([start, end])
    return [(a, b, '?') for a, b in groups if b - a >= .12]

def its_candidates(path, offset, duration):
    root = ET.parse(path).getroot()
    # ITS summary bars repeat Recording elements; only processing recordings contain segments.
    recordings = [e for e in root.iter() if e.tag.split('}')[-1] == 'Recording'
                  and any(c.tag.split('}')[-1] in ('Conversation', 'Pause') for c in e)]
    if not recordings:
        raise ValueError('No LENA processing recordings found in ITS.')
    def seconds(value):
        # LENA elapsed durations in this project use PT...S.
        if not value.startswith('PT') or not value.endswith('S'):
            raise ValueError('Unsupported ITS time format: ' + value)
        return float(value[2:-1])
    result = []
    for recording in recordings:
      origin = seconds(recording.attrib['startTime'])
      finish = seconds(recording.attrib['endTime'])
      for e in recording.iter():
        if e.tag.split('}')[-1] != 'Segment' or e.get('spkr') not in ('FAN', 'MAN'):
            continue
        absolute_a, absolute_b = seconds(e.attrib['startTime']), seconds(e.attrib['endTime'])
        if not origin - .01 <= absolute_a < absolute_b <= finish + .01:
            raise ValueError('ITS segment times do not use the expected absolute elapsed timeline.')
        a, b = absolute_a - offset, absolute_b - offset
        if b > 0 and a < duration:
            result.append((max(0., a), min(duration, b), e.attrib['spkr'] + '-?'))
    return sorted(result)

def write_grid(path, duration, intervals):
    def quoted(s):
        return '"' + str(s).replace('"', '""') + '"'
    text = ['File type = "ooTextFile"', 'Object class = "TextGrid"', '',
            'xmin = 0', f'xmax = {duration:.12f}', 'tiers? <exists>', 'size = 3', 'item []:']
    for j, name in enumerate(TIERS, 1):
        text += [f'    item [{j}]:', '        class = "IntervalTier"', f'        name = "{name}"',
                 '        xmin = 0', f'        xmax = {duration:.12f}', f'        intervals: size = {len(intervals)}']
        for k, row in enumerate(intervals, 1):
            text += [f'        intervals [{k}]:', f'            xmin = {row["start"]:.12f}',
                     f'            xmax = {row["end"]:.12f}', f'            text = {quoted(row[name])}']
    target = Path(path)
    temp = target.with_name(target.name + '.' + uuid.uuid4().hex + '.tmp')
    temp.write_text('\n'.join(text) + '\n', encoding='utf-8')
    temp.replace(target)

def read_grid(path):
    grid = parselmouth.read(str(path))
    if call(grid, 'Get number of tiers') != 3:
        raise ValueError('Exactly three interval tiers are required: ' + ', '.join(TIERS))
    tiers = []
    for j, expected in enumerate(TIERS, 1):
        if call(grid, 'Get tier name', j) != expected:
            raise ValueError('Tier names/order must be ' + ', '.join(TIERS))
        tiers.append([(float(call(grid, 'Get start time of interval', j, k)),
                       float(call(grid, 'Get end time of interval', j, k)),
                       call(grid, 'Get label of interval', j, k).strip())
                      for k in range(1, int(call(grid, 'Get number of intervals', j)) + 1)])
    if any(len(t) != len(tiers[0]) for t in tiers):
        raise ValueError('Tier boundaries differ. Align all three tiers before reloading.')
    rows = []
    for items in zip(*tiers):
        a, b, _ = items[0]
        if not 0 <= a < b or not all(math.isfinite(t) for t in (a, b)):
            raise ValueError('Invalid TextGrid interval.')
        if any(abs(x[0] - a) > 1e-7 or abs(x[1] - b) > 1e-7 for x in items):
            raise ValueError('Tier boundaries differ. Align all three tiers before reloading.')
        if rows and abs(a - rows[-1]['end']) > 1e-7:
            raise ValueError('TextGrid intervals must be contiguous.')
        rows.append(dict(start=a, end=b, **{name: item[2] for name, item in zip(TIERS, items)}))
    return rows

def signature(row):
    return hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()

def valid(row):
    return row['speaker_speech'] in SPEAKERS and row['valence'] in ('+1', '0', '-1') and row['arousal'] in ('+1', '-1')

def features(path, rows):
    rate, x = mono_audio(path)
    result = []
    for i, row in enumerate(rows):
        if not any(row[t] for t in TIERS):
            continue
        a = x[round(row['start'] * rate):round(row['end'] * rate)]
        item = dict(interval=i + 1, start=row['start'], end=row['end'], duration=len(a) / rate,
                    rms_dbfs=20 * math.log10(max(float(np.sqrt(np.mean(a * a))), 1e-10)),
                    f0_mean_hz='', f0_range_hz='', voiced_fraction='', measurement_note='')
        try:
            pitch = parselmouth.Sound(a, sampling_frequency=rate).to_pitch_ac(pitch_floor=60, pitch_ceiling=600)
            f = pitch.selected_array['frequency']
            voiced = f[f > 0]
            item['voiced_fraction'] = float(np.mean(f > 0))
            if len(voiced):
                item['f0_mean_hz'] = float(np.mean(voiced))
                item['f0_range_hz'] = float(np.ptp(voiced))
        except parselmouth.PraatError as e:
            item['measurement_note'] = str(e)
        result.append(item)
    return result

def prepare(source, output, group='Reference', offset=0., length=300., its=None, *, refine=True, suggest=True):
    import automation
    source = Path(source).resolve()
    info = audio_info(source)
    if its and Path(its).stem.lower() != source.stem.lower():
        raise ValueError('ITS and WAV filenames must have matching stems for automatic alignment.')
    if group not in ('NH', 'HA', 'Reference'):
        raise ValueError('Choose NH, HA, or Reference.')
    if not (math.isfinite(offset) and math.isfinite(length) and 0 <= offset < info['duration'] and 0 < length <= 3600):
        raise ValueError('Select a valid start and a duration between 0 and 3600 seconds.')
    run = Path(output).resolve() / ('run_' + datetime.now().strftime('%Y%m%d_%H%M%S_') + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    start, end = copy_audio(source, run / 'excerpt.wav', offset, min(offset + length, info['duration']))
    duration = end - start
    rows, suggestions = automation.build_draft(run / 'excerpt.wav', its, start, refine=refine, suggest=suggest)
    write_grid(run / 'annotations.TextGrid', duration, rows)
    measurements = features(run / 'excerpt.wav', rows)
    write_csv(run / 'acoustics.csv', measurements, ['interval', 'start', 'end', 'duration', 'rms_dbfs', 'f0_mean_hz', 'f0_range_hz', 'voiced_fraction', 'measurement_note'])
    quality = automation.quality_metrics(run / 'excerpt.wav', rows)
    write_csv(run / 'quality.csv', [dict(q,flags='; '.join(q['flags'])) for q in quality],
              ['interval','start','end','near_full_scale_fraction','rms_dbfs','flags'])
    save_json(run / 'suggestions.json', suggestions)
    save_json(run / 'run.json', dict(version=2, app_version=automation.VERSION, created_utc=now(), source=str(source), group=group,
              source_offset=start, source_end=end, duration=duration, audio=info,
              excerpt_sha256=digest(run / 'excerpt.wav'), segmentation=('LENA ITS + Praat pauses' if refine else 'LENA ITS adult segments') if its else 'Praat sounding regions',
              its_source=str(Path(its).resolve()) if its else None,
              refine_pauses=refine, suggest_cds_ads=suggest,
              notes='CDS/ADS are unvalidated rule suggestions; emotion is unknown. F0 settings: 60-600 Hz.'))
    save_json(run / 'reviews.json', {})
    log_event(run, 'prepared', candidates=len(suggestions))
    return run

def load_run(run):
    run = Path(run)
    meta = json.loads((run / 'run.json').read_text(encoding='utf-8'))
    if digest(run / 'excerpt.wav') != meta['excerpt_sha256']:
        raise ValueError('Excerpt audio changed; prepare a new run.')
    rows = read_grid(run / 'annotations.TextGrid')
    if not rows or abs(rows[0]['start']) > 1e-7 or abs(rows[-1]['end'] - meta['duration']) > 1e-7:
        raise ValueError('TextGrid duration differs from excerpt audio.')
    reviews = json.loads((run / 'reviews.json').read_text(encoding='utf-8'))
    return meta, rows, reviews

def approve(run, index, reviewer):
    meta, rows, reviews = load_run(run)
    if not reviewer.strip():
        raise ValueError('Enter a reviewer name or ID.')
    if not valid(rows[index]):
        raise ValueError('Complete all three labels before approving.')
    reviews[signature(rows[index])] = dict(reviewer=reviewer.strip(), approved_utc=now())
    save_json(Path(run) / 'reviews.json', reviews)
    log_event(run, 'approved', interval=index+1, reviewer=reviewer.strip(), signature=signature(rows[index]))

def export(run):
    run = Path(run)
    meta, rows, reviews = load_run(run)
    selected = [(i, row) for i, row in enumerate(rows) if valid(row) and signature(row) in reviews]
    if not selected:
        raise ValueError('No approved intervals. Complete labels and approve reviewed samples first.')
    dest = run / ('export_' + uuid.uuid4().hex[:8])
    dest.mkdir()
    manifest, counts = [], {}
    for i, row in selected:
        speaker, valence, arousal = (row[t] for t in TIERS)
        category = ('positive' if valence == '+1' else 'negative' if valence == '-1' else 'neutral') + ('_high' if arousal == '+1' else '_low')
        folder = dest / meta['group'] / speaker / category
        folder.mkdir(parents=True, exist_ok=True)
        clip = folder / f'interval_{i+1:05d}.wav'
        a, b = copy_audio(run / 'excerpt.wav', clip, row['start'], row['end'])
        review = reviews[signature(row)]
        manifest.append(dict(sample_id=clip.stem, run_id=run.name, source=meta['source'], group=meta['group'],
            source_start=meta['source_offset'] + a, source_end=meta['source_offset'] + b,
            excerpt_start=a, excerpt_end=b, speaker_speech=speaker, valence=valence, arousal=arousal,
            reviewer=review['reviewer'], approved_utc=review['approved_utc'], clip_path=str(clip.relative_to(dest))))
        counts[(speaker, valence, arousal)] = counts.get((speaker, valence, arousal), 0) + 1
    write_csv(dest / 'manifest.csv', manifest, list(manifest[0]))
    coverage = [dict(speaker_speech=s, valence=v, arousal=a, target_16=v != '0', count=counts.get((s,v,a),0))
                for s,v,a in itertools.product(SPEAKERS, ('+1','-1','0'), ('+1','-1'))]
    write_csv(dest / 'coverage.csv', coverage, ['speaker_speech','valence','arousal','target_16','count'])
    measured = features(run / 'excerpt.wav', [row for _, row in selected])
    for measurement, (i, _) in zip(measured, selected):
        measurement['interval'] = i + 1
    write_csv(dest / 'acoustics.csv', measured, ['interval','start','end','duration','rms_dbfs','f0_mean_hz','f0_range_hz','voiced_fraction','measurement_note'])
    shutil.copy2(run / 'annotations.TextGrid', dest / 'reviewed.TextGrid')
    shutil.copy2(run / 'excerpt.wav', dest / 'excerpt.wav')
    shutil.copy2(run / 'run.json', dest / 'run.json')
    shutil.copy2(run / 'reviews.json', dest / 'reviews.json')
    if (run / 'suggestions.json').exists():
        shutil.copy2(run / 'suggestions.json', dest / 'suggestions.json')
    import automation
    quality = automation.quality_metrics(run / 'excerpt.wav', rows)
    write_csv(dest / 'quality.csv', [dict(q,flags='; '.join(q['flags'])) for q in quality],
              ['interval','start','end','near_full_scale_fraction','rms_dbfs','flags'])
    log_event(run, 'exported', export_folder=dest.name, samples=len(manifest))
    return dest

def log_event(run, action, **fields):
    with (Path(run) / 'activity.jsonl').open('a',encoding='utf-8') as f:
        f.write(json.dumps(dict(utc=now(),action=action,**fields))+'\n')

def save_annotations(run, rows, expected_hash=None, action='labels_saved'):
    """Back up and replace only the version the reviewer actually loaded."""
    run = Path(run)
    path = run / 'annotations.TextGrid'
    if expected_hash and digest(path) != expected_hash:
        raise ValueError('TextGrid changed externally. Reload before saving.')
    meta = json.loads((run / 'run.json').read_text(encoding='utf-8'))
    candidate = run / ('validate_' + uuid.uuid4().hex + '.TextGrid')
    try:
        write_grid(candidate,meta['duration'],rows)
        parsed = read_grid(candidate)
        if not parsed or abs(parsed[0]['start'])>1e-7 or abs(parsed[-1]['end']-meta['duration'])>1e-7:
            raise ValueError('Annotations must cover the complete excerpt.')
        history = run / 'history'
        history.mkdir(exist_ok=True)
        shutil.copy2(path, history / (datetime.now().strftime('%Y%m%d_%H%M%S_')+uuid.uuid4().hex[:8]+'.TextGrid'))
        if expected_hash and digest(path) != expected_hash:
            raise ValueError('TextGrid changed during save. Reload before saving.')
        candidate.replace(path)
        log_event(run, action)
    finally:
        candidate.unlink(missing_ok=True)

def set_boundaries(run, index, start, end, expected_hash=None, labels=None):
    meta,rows,_ = load_run(run)
    if not (math.isfinite(start) and math.isfinite(end) and 0<=start<end<=meta['duration']):
        raise ValueError('Invalid interval boundaries.')
    if index==0 and abs(start)>1e-7 or index==len(rows)-1 and abs(end-meta['duration'])>1e-7:
        raise ValueError('Outer boundaries must stay at 0 and the excerpt duration.')
    if index and start<=rows[index-1]['start'] or index+1<len(rows) and end>=rows[index+1]['end']:
        raise ValueError('The change would swallow a neighbouring interval. Split or merge explicitly instead.')
    rows[index].update(start=start,end=end)
    if labels:
        rows[index].update({t:labels[t] for t in TIERS})
    if index: rows[index-1]['end']=start
    if index+1<len(rows): rows[index+1]['start']=end
    save_annotations(run,rows,expected_hash,action='boundaries_saved')

def synchronize_tiers(run, expected_hash=None):
    """Use speaker boundaries; preserve unambiguous labels, mark conflicts ?."""
    run=Path(run)
    grid=parselmouth.read(str(run/'annotations.TextGrid'))
    if int(call(grid,'Get number of tiers'))!=3:
        raise ValueError('Exactly three interval tiers are required.')
    tiers=[]
    for j,name in enumerate(TIERS,1):
        if call(grid,'Get tier name',j)!=name:
            raise ValueError('Tier names/order must be '+', '.join(TIERS))
        tiers.append([(float(call(grid,'Get start time of interval',j,k)),
                       float(call(grid,'Get end time of interval',j,k)),
                       call(grid,'Get label of interval',j,k).strip())
                      for k in range(1,int(call(grid,'Get number of intervals',j))+1)])
    rows=[]
    for a,b,label in tiers[0]:
        row=dict(start=a,end=b,speaker_speech=label)
        for name,tier in zip(TIERS[1:],tiers[1:]):
            labels={txt for x,y,txt in tier if x<b-1e-7 and y>a+1e-7 and txt}
            row[name]=next(iter(labels)) if len(labels)==1 else '?' if labels else ''
        rows.append(row)
    save_annotations(run,rows,expected_hash,action='tiers_synchronized')
    return rows

def review_script(run, start=0., end=None, *, close=False):
    """Use an isolated Praat GUI with uniquely named objects, never menu clicks."""
    run=Path(run).resolve()
    meta,rows,_=load_run(run)
    name='ANVUREL_'+run.name.replace('-','_')
    def q(value):
        return '"'+str(value).replace('"','""')+'"'
    if close:
        text=[f'selectObject: {q("TextGrid "+name)}',f'Save as text file: {q(run/"annotations.TextGrid")}',
              'Remove',f'selectObject: {q("Sound "+name)}','Remove','Quit']
        path=run/'finish_review.praat'
    else:
        start=max(0.,min(float(start),meta['duration']))
        end=min(meta['duration'],float(end) if end is not None else min(start+10,meta['duration']))
        if end<=start: raise ValueError('Choose a non-empty Praat selection.')
        text=[f'sound = Read from file: {q(run/"excerpt.wav")}',f'Rename: {q(name)}',
              f'grid = Read from file: {q(run/"annotations.TextGrid")}',f'Rename: {q(name)}',
              'selectObject: sound, grid','View & Edit','editor: grid',
              f'Zoom: {max(0,start-1):.12f}, {min(meta["duration"],end+1):.12f}',
              f'Select: {start:.12f}, {end:.12f}','endeditor']
        path=run/'open_review.praat'
    path.write_text('\n'.join(text)+'\n',encoding='utf-8')
    return path

def running_praat_pids():
    """Process inventory only; no window manipulation or closing other sessions."""
    import os
    if os.name!='nt':return []
    import ctypes
    from ctypes import wintypes
    class Entry(ctypes.Structure):
        _fields_=[('size',wintypes.DWORD),('usage',wintypes.DWORD),('pid',wintypes.DWORD),
                  ('heap',ctypes.c_size_t),('module',wintypes.DWORD),('threads',wintypes.DWORD),
                  ('parent',wintypes.DWORD),('priority',wintypes.LONG),('flags',wintypes.DWORD),
                  ('name',wintypes.WCHAR*260)]
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateToolhelp32Snapshot.argtypes=[wintypes.DWORD,wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype=wintypes.HANDLE
    for name in ('Process32FirstW','Process32NextW'):
        getattr(kernel,name).argtypes=[wintypes.HANDLE,ctypes.POINTER(Entry)]
        getattr(kernel,name).restype=wintypes.BOOL
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    handle=kernel.CreateToolhelp32Snapshot(2,0)
    if handle==ctypes.c_void_p(-1).value:raise OSError('Unable to check active Praat processes.')
    entry=Entry();entry.size=ctypes.sizeof(entry);pids=[]
    try:
        ok=kernel.Process32FirstW(handle,ctypes.byref(entry))
        while ok:
            if entry.name.lower()=='praat.exe':pids.append(entry.pid)
            ok=kernel.Process32NextW(handle,ctypes.byref(entry))
    finally:kernel.CloseHandle(handle)
    return pids

def require_single_praat():
    if len(running_praat_pids())>1:
        raise ValueError('Multiple Praat application instances are open. Save and close the other instance before automated navigation or finishing review.')

def open_praat(executable, run, start=0., end=None):
    exe, run = Path(executable).resolve(), Path(run).resolve()
    if not exe.is_file():
        raise ValueError('Select your installed Praat executable.')
    if running_praat_pids():
        raise ValueError('Praat is already open. Save and close it before starting the app-controlled review session, so commands reach the correct editor.')
    script=review_script(run,start,end)
    return subprocess.Popen([str(exe), '--new-send', '--no-pref-files', str(script)])

def navigate_praat(executable, run, start, end):
    require_single_praat()
    run=Path(run).resolve()
    meta=json.loads((run/'run.json').read_text(encoding='utf-8'))
    name='ANVUREL_'+run.name.replace('-','_')
    script=run/('navigate_'+uuid.uuid4().hex[:8]+'.praat')
    script.write_text(f'editor: "TextGrid {name}"\nZoom: {max(0,start-1):.12f}, {min(meta["duration"],end+1):.12f}\nSelect: {start:.12f}, {end:.12f}\nendeditor\n',encoding='utf-8')
    return subprocess.Popen([str(Path(executable).resolve()),'--send',str(script)])

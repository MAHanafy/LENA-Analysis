"""Explainable LENA suggestions and optional Praat pause refinement.

Rules adapt +lena/classify_interactions.m across conversation types. Suggestions are not approvals or
calibrated probabilities. All elapsed times refer to the original WAV timeline.
"""
import math
import re
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

import numpy as np
import parselmouth
from parselmouth.praat import call

VERSION = '2.0.1'
ADULTS = ('FAN', 'MAN')
TALKERS = ('CHN', 'FAN', 'MAN')

def tag(e):
    return e.tag.rsplit('}', 1)[-1]

def seconds(text):
    match = re.fullmatch(r'PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?', text)
    if not match or not any(match.groups()):
        raise ValueError('Invalid ITS elapsed time: ' + str(text))
    return sum(float(v or 0) * m for v, m in zip(match.groups(), (3600, 60, 1)))

def read_its(path):
    root = ET.parse(path).getroot()
    result, conversation = [], 0
    recordings = [e for e in root.iter() if tag(e) == 'Recording'
                  and any(tag(c) in ('Conversation', 'Pause') for c in e)]
    if not recordings:
        raise ValueError('No processing recordings found in ITS.')
    for ri, recording in enumerate(recordings):
        low, high = seconds(recording.attrib['startTime']), seconds(recording.attrib['endTime'])
        for block in recording:
            if tag(block) not in ('Conversation', 'Pause'):
                continue
            conversation += 1
            children = list(block)
            for si, e in enumerate(children):
                if tag(e) != 'Segment':
                    continue
                speaker = e.get('spkr', '')
                if speaker not in TALKERS:
                    continue
                parts = e.get('conversationInfo', '').removeprefix('|').split('|')
                code = parts[5] if len(parts) >= 7 else ''
                near = any(0 <= j < len(children) and tag(children[j]) == 'Segment'
                           and children[j].get('spkr') in TALKERS for j in (si - 1, si + 1))
                spans = []
                if speaker == 'CHN':
                    for key in e.attrib:
                        match = re.fullmatch(r'startUtt(\d+)', key)
                        if match and 'endUtt' + match[1] in e.attrib:
                            spans.append((seconds(e.attrib[key]), seconds(e.attrib['endUtt' + match[1]])))
                elif 'startTime' in e.attrib and 'endTime' in e.attrib:
                    spans.append((seconds(e.attrib['startTime']), seconds(e.attrib['endTime'])))
                words = float(e.get('femaleAdultWordCnt' if speaker == 'FAN' else 'maleAdultWordCnt', '0'))
                for ui, (a, b) in enumerate(sorted(spans)):
                    if not (math.isfinite(a) and math.isfinite(b) and low - .01 <= a < b <= high + .01):
                        raise ValueError('ITS segment does not use the expected absolute elapsed timeline.')
                    result.append(dict(id=f'{ri}:{si}:{conversation}:{ui}', start=a, end=b,
                        speaker=speaker, conversation=conversation, code=code,
                        aicm=tag(block) == 'Conversation' and block.get('type') == 'AICM',
                        in_conversation=tag(block) == 'Conversation',conversation_type=block.get('type',''),
                        valid=near and b-a >= .1 and (speaker == 'CHN' or words > 0 or code not in ('', 'NT'))))
    return sorted(result, key=lambda s: (s['start'], s['end']))

def directional(a, b):
    return a + 'to' + b if a in TALKERS and b in TALKERS and (a != 'CHN' or b != 'CHN') else ''

def code_label(code, a, b):
    expected = directional(a, b)
    if code == 'TIMR' and b == 'CHN':
        return 'MANtoCHN'
    if code == 'TIFR' and b == 'CHN':
        return 'FANtoCHN'
    if code == 'TIMI' and a == 'MAN':
        return expected
    if code in ('TIFI', 'TIFE') and a == 'FAN':
        return expected
    return ''

def interaction_suggestions(segments, window=5., aicm_only=False):
    """Retain conflicting evidence as unknown rather than choosing a label."""
    groups, evidence = defaultdict(list), defaultdict(list)
    for s in segments:
        if s['in_conversation'] and s['valid'] and (not aicm_only or s['aicm']):
            groups[s['conversation']].append(s)
    for items in groups.values():
        items.sort(key=lambda s: (s['start'], s['end']))
        for j, target in enumerate(items):
            prior = next((s for s in reversed(items[:j]) if 0 <= target['start'] - s['end'] <= window), None)
            if prior is None:
                continue
            # FAN/MAN are classes, not individual identities. Same-class turns may be one person.
            if prior['speaker'] == target['speaker']:
                continue
            label, origin = '', ''
            for code, origin_name in ((target['code'], 'LENA_target'), (prior['code'], 'LENA_source')):
                label = code_label(code, prior['speaker'], target['speaker'])
                if label:
                    origin = origin_name
                    break
            if not label:
                label, origin = directional(prior['speaker'], target['speaker']), 'adjacency'
            if not label:
                continue
            speech = 'CDS' if 'CHN' in label else 'ADS'
            between = [s for s in items if prior['start'] < s['start'] < target['start']]
            if speech == 'ADS' and any(s['speaker'] == 'CHN' for s in between):
                continue
            ev = dict(speech_type=speech, source=origin, pair=label,
                      gap_seconds=round(target['start'] - prior['end'], 6),
                      from_start=prior['start'], to_start=target['start'])
            for s in (prior, target):
                if s['speaker'] in ADULTS:
                    evidence[s['id']].append(ev)
    suggestions = {}
    for s in segments:
        if s['speaker'] not in ADULTS:
            continue
        ev = sorted(evidence[s['id']], key=lambda v: v['gap_seconds'])
        labels = {v['speech_type'] for v in ev}
        speech = next(iter(labels)) if len(labels) == 1 else '?'
        reason = ('conflicting CDS/ADS evidence' if len(labels) > 1 else
                  'no supported interaction evidence' if not labels else ev[0]['source'])
        suggestions[s['id']] = dict(label=s['speaker'] + '-' + speech,
                                     reason=reason, evidence=ev)
    return suggestions

def sounding_regions(samples, rate, *, min_pause=.25):
    """Praat intensity segmentation. It does not distinguish speech from noise."""
    duration = len(samples) / rate
    if duration < .12 or np.max(np.abs(samples),initial=0.) < 1e-10:
        return []
    sound = parselmouth.Sound(samples, sampling_frequency=rate)
    grid = call(sound, 'To TextGrid (silences)', 100, 0., -25., min_pause, .12, 'silent', 'sounding')
    return [(float(call(grid, 'Get start time of interval', 1, i)),
             float(call(grid, 'Get end time of interval', 1, i)))
            for i in range(1, int(call(grid, 'Get number of intervals', 1)) + 1)
            if call(grid, 'Get label of interval', 1, i) == 'sounding']

def build_draft(audio_path, its, offset, *, refine=True, suggest=True):
    # Local import keeps core's existing API usable for old runs.
    import core
    rate, samples = core.mono_audio(audio_path)
    duration = len(samples) / rate
    segments = read_its(its) if its else []
    predictions = interaction_suggestions(segments) if its and suggest else {}
    parents = []
    for s in segments:
        if s['speaker'] in ADULTS and s['end'] > offset and s['start'] < offset + duration:
            a, b = max(0., s['start'] - offset), min(duration, s['end'] - offset)
            pred = predictions.get(s['id'], dict(label=s['speaker']+'-?', reason='suggestions disabled', evidence=[]))
            parents.append(dict(start=a, end=b, label=pred['label'], source_segment=s['id'],
                                reason=pred['reason'], evidence=pred['evidence'], flags=[]))
    if not its:
        try:
            spans = sounding_regions(samples, rate)
        except parselmouth.PraatError:
            spans = [(a,b) for a,b,_ in core.energy_candidates(audio_path)]
        parents = [dict(start=a,end=b,label='?',source_segment=f'audio:{i}',
                        reason='No ITS speaker or interaction labels', evidence=[],
                        flags=['speaker_unknown']) for i,(a,b) in enumerate(spans)]
    fragments = []
    for parent in parents:
        parts = [(parent['start'], parent['end'])]
        if its and refine:
            a, b = parent['start'], parent['end']
            try:
                spans = sounding_regions(samples[round(a*rate):round(b*rate)], rate)
                parts = [(max(a,a+x-.03),min(b,a+y+.03)) for x,y in spans]
                if not parts:
                    parts = [(a,b)]
                    parent['flags'].append('no_clear_sounding_region')
            except parselmouth.PraatError:
                parent['flags'].append('pause_refinement_unavailable')
            # Merge padding that overlaps within the same original segment.
            merged = []
            for a,b in parts:
                if merged and a <= merged[-1][1]:
                    merged[-1] = (merged[-1][0], max(b,merged[-1][1]))
                else:
                    merged.append((a,b))
            parts = merged
        fragments.extend(dict(parent, start=a,end=b) for a,b in parts if b > a)
    points = sorted({0.,duration} | {float(f[k]) for f in fragments for k in ('start','end')})
    rows, notes = [], []
    for a,b in zip(points,points[1:]):
        active = [f for f in fragments if f['start'] < b-1e-8 and f['end'] > a+1e-8]
        flags = sorted({flag for f in active for flag in f['flags']})
        if len(active) > 1:
            flags.append('overlapping_adult_segments')
        row = dict(start=a,end=b,speaker_speech=active[0]['label'] if len(active)==1 else '?' if active else '',
                   valence='?' if active else '',arousal='?' if active else '')
        rows.append(row)
        if active:
            notes.append(dict(start=a,end=b,proposed_speaker_speech=row['speaker_speech'],
                reason=active[0]['reason'] if len(active)==1 else 'overlapping adult segments',
                evidence=[ev for f in active for ev in f['evidence']],
                source_segments=sorted({f['source_segment'] for f in active}), flags=flags))
    return rows, notes

def quality_metrics(path, rows):
    import core
    rate, samples = core.mono_audio(path)
    result = []
    for i,row in enumerate(rows):
        if not any(row[t] for t in core.TIERS):
            continue
        x = samples[round(row['start']*rate):round(row['end']*rate)]
        near = float(np.mean(np.abs(x) >= .999)) if len(x) else 0.
        db = 20 * math.log10(max(float(np.sqrt(np.mean(x*x))),1e-10)) if len(x) else -200.
        flags = []
        if row['end']-row['start'] < .2: flags.append('very_short')
        if near > .001: flags.append('possible_clipping')
        if db < -45: flags.append('very_quiet')
        if row['speaker_speech'] not in core.SPEAKERS: flags.append('speaker_or_listener_uncertain')
        result.append(dict(interval=i+1,start=row['start'],end=row['end'],near_full_scale_fraction=near,
                           rms_dbfs=db,flags=flags))
    return result

def evidence_for(row, notes):
    return next((n for n in notes if abs(n['start']-row['start']) < 1e-7
                 and abs(n['end']-row['end']) < 1e-7),
                dict(reason='Boundaries changed or no original suggestion',evidence=[],flags=[]))

"""Snapshot transcript drafts and map their cues to approved audio clips."""
from __future__ import annotations

import csv
import io
import json
from pathlib import Path

import core
import transcripts

FIELDS = ('sample_id', 'interval', 'segment', 'excerpt_start', 'excerpt_end',
          'source_start', 'source_end', 'clip_start', 'clip_end', 'text',
          'partial_cue', 'draft')


def prepare_export(run, selected):
    """Validate inputs and prepare a detached snapshot before export files exist.

    Each CSV row describes how a transcript cue overlaps an approved clip.
    Text is included only when the complete cue falls inside the clip. For a
    partial cue, times are retained for review but text is blank so the export
    cannot disclose words from outside the approved audio.
    """
    run = Path(run)
    metadata, annotations, approvals = core.load_run(run)
    document = transcripts.load(run)
    if document is None:
        return None
    if (document['audio_sha256'] != metadata['excerpt_sha256']
            or abs(document['source_offset'] - metadata['source_offset']) > 1e-6
            or abs(document['duration'] - metadata['duration']) > 1e-6):
        raise ValueError('Transcript and annotations refer to different audio or excerpt times.')
    try:
        json.dumps(document, ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError) as error:
        raise ValueError('Transcript metadata cannot be exported as valid JSON.') from error
    records = []
    seen = set()
    rate = core.audio_info(run / 'excerpt.wav')['rate']
    for index, row in selected:
        if (not isinstance(index, int) or isinstance(index, bool)
                or not 0 <= index < len(annotations) or index in seen):
            raise ValueError('Each exported interval needs a unique current annotation index.')
        seen.add(index)
        if row != annotations[index] or not core.valid(row) or core.signature(row) not in approvals:
            raise ValueError('An exported interval changed or is no longer approved. Reload before exporting.')
        first_frame, last_frame = round(row['start'] * rate), round(row['end'] * rate)
        if last_frame <= first_frame:
            raise ValueError('An approved interval is shorter than one audio sample and cannot be exported.')
        clip_start, clip_end = first_frame / rate, last_frame / rate
        for segment_index, segment in enumerate(document['segments'], 1):
            start = max(clip_start, segment['start'])
            end = min(clip_end, segment['end'])
            if end <= start:
                continue
            partial = (segment.get('clipped') is True
                       or start > segment['start'] + 1e-9
                       or end < segment['end'] - 1e-9)
            records.append(dict(sample_id=f'interval_{index+1:05d}', interval=index+1,
                segment=segment_index, excerpt_start=start, excerpt_end=end,
                source_start=metadata['source_offset'] + start,
                source_end=metadata['source_offset'] + end,
                clip_start=start-clip_start, clip_end=end-clip_start,
                text='' if partial else segment['text'], partial_cue=partial, draft=True))
    return {'rows': records}


def write_export(bundle, destination):
    """Write only transcript mappings for approved clips into an export folder."""
    if bundle is None:
        return
    destination = Path(destination)
    csv_path = destination / 'transcript_segments.csv'
    if csv_path.exists():
        raise FileExistsError('Transcript export files already exist in the destination.')
    text = io.StringIO(newline='')
    writer = csv.DictWriter(text, fieldnames=FIELDS, extrasaction='raise')
    writer.writeheader()
    writer.writerows(bundle['rows'])
    with csv_path.open('xb') as stream:
        stream.write(text.getvalue().encode('utf-8-sig'))

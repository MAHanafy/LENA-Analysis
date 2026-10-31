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

    Each CSV row describes the overlap of one transcript cue and one approved
    clip. Text remains the complete cue. A partial cue flag makes clear that
    the text is not a word alignment for that shorter clip.
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
        snapshot = json.loads(json.dumps(document, ensure_ascii=False, allow_nan=False))
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
        for segment_index, segment in enumerate(snapshot['segments'], 1):
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
                text=segment['text'], partial_cue=partial, draft=True))
    return {'document': snapshot, 'rows': records}


def write_export(bundle, destination):
    """Write the prepared transcript snapshot and CSV into an export folder."""
    if bundle is None:
        return
    destination = Path(destination)
    json_path = destination / 'transcript.json'
    csv_path = destination / 'transcript_segments.csv'
    if json_path.exists() or csv_path.exists():
        raise FileExistsError('Transcript export files already exist in the destination.')
    # Serialize both files before writing either one. The caller can then
    # publish the completed export directory as one operation.
    document = json.dumps(bundle['document'], indent=2, ensure_ascii=False, allow_nan=False) + '\n'
    text = io.StringIO(newline='')
    writer = csv.DictWriter(text, fieldnames=FIELDS, extrasaction='raise')
    writer.writeheader()
    writer.writerows(bundle['rows'])
    with json_path.open('xb') as stream:
        stream.write(document.encode('utf-8'))
    with csv_path.open('xb') as stream:
        stream.write(text.getvalue().encode('utf-8-sig'))

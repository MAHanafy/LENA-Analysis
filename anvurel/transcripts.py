"""Timed transcript drafts attached to one prepared audio excerpt.

Transcript text never changes speaker, emotion, or approval records. Generation
uses a local speech model. Downloading a model requires an explicit opt in.
"""
from __future__ import annotations

import contextlib
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import uuid
from datetime import datetime, timezone
import wave

VERSION = 1
SUPPORTED_MODELS = ('tiny', 'base', 'small')
_EPSILON = 1e-6


class TranscriptCancelled(RuntimeError):
    """The caller stopped transcription before a replacement was saved."""


def _digest(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _number(value, name):
    if isinstance(value, bool):
        raise ValueError(f'{name} must be a finite number.')
    try:
        value = float(value)
    except (TypeError, ValueError, OverflowError) as error:
        raise ValueError(f'{name} must be a finite number.') from error
    if not math.isfinite(value):
        raise ValueError(f'{name} must be a finite number.')
    return value


def _identity(run):
    run = Path(run)
    metadata = json.loads((run / 'run.json').read_text(encoding='utf-8'))
    duration = _number(metadata.get('duration'), 'Excerpt duration')
    offset = _number(metadata.get('source_offset'), 'Source offset')
    checksum = _digest(run / 'excerpt.wav')
    if duration <= 0 or offset < 0 or checksum != metadata.get('excerpt_sha256'):
        raise ValueError('Excerpt audio differs from its run record. Prepare a new run.')
    with wave.open(str(run / 'excerpt.wav'), 'rb') as audio:
        actual = audio.getnframes() / audio.getframerate()
        tolerance = 1 / audio.getframerate() + _EPSILON
    if abs(actual - duration) > tolerance:
        raise ValueError('Excerpt duration differs from its run record.')
    return {'audio_sha256': checksum, 'duration': duration, 'source_offset': offset}


def _previous(run):
    path = Path(run) / 'transcript.json'
    return _digest(path) if path.exists() else None


def _text(value, name):
    if not isinstance(value, str) or '\x00' in value:
        raise ValueError(f'{name} must be text without null characters.')
    return value.strip()


def _segments(raw, duration, offset=0., timeline='excerpt'):
    if timeline not in ('excerpt', 'original'):
        raise ValueError('Transcript timeline must be excerpt or original.')
    if not isinstance(raw, list):
        raise ValueError('Transcript segments must be a list.')
    shift = offset if timeline == 'original' else 0.
    result = []
    for index, item in enumerate(raw, 1):
        if not isinstance(item, dict):
            raise ValueError(f'Transcript segment {index} must be an object.')
        start = _number(item.get('start'), f'Segment {index} start')
        end = _number(item.get('end'), f'Segment {index} end')
        text = _text(item.get('text'), f'Segment {index} text')
        if not 0 <= start < end:
            raise ValueError(f'Segment {index} has an invalid time range.')
        if timeline == 'excerpt' and end > duration + _EPSILON:
            raise ValueError(f'Segment {index} extends beyond the excerpt.')
        words = item.get('words')
        if words is not None and not isinstance(words, list):
            raise ValueError(f'Segment {index} words must be a list.')
        converted_words = []
        for word_index, word in enumerate(words or [], 1):
            if not isinstance(word, dict):
                raise ValueError(f'Word {word_index} in segment {index} must be an object.')
            a = _number(word.get('start'), 'Word start')
            b = _number(word.get('end'), 'Word end')
            value = _text(word.get('word', word.get('text')), 'Word')
            # Whisper can assign zero duration to punctuation. Preserve the text,
            # but never let word times extend beyond their parent segment.
            if not start - _EPSILON <= a <= b <= end + _EPSILON:
                raise ValueError(f'A word in segment {index} is outside its segment.')
            probability = word.get('probability')
            if probability is not None:
                probability = _number(probability, 'Word probability')
                if not 0 <= probability <= 1:
                    raise ValueError('Word probability must be between zero and one.')
            if b - shift < 0 or a - shift > duration:
                continue
            converted = {'start': max(0., a - shift),
                         'end': min(duration, b - shift), 'word': value}
            if converted['start'] <= converted['end']:
                if probability is not None:
                    converted['probability'] = probability
                converted_words.append(converted)
        a, b = start - shift, end - shift
        if b <= 0 or a >= duration:
            continue
        segment = {'start': max(0., a), 'end': min(duration, b), 'text': text}
        if item.get('clipped') is True or a < 0 or b > duration:
            segment['clipped'] = True
        if words is not None:
            segment['words'] = converted_words
        result.append(segment)
    return sorted(result, key=lambda item: (item['start'], item['end']))


def _document(identity, segments, origin):
    return {'version': VERSION, 'draft': True, **identity, 'timeline': 'excerpt',
            'origin': origin, 'segments': segments}


def _validate(document, identity):
    if (not isinstance(document, dict) or type(document.get('version')) is not int
            or document.get('version') != VERSION):
        raise ValueError('Unsupported transcript file version.')
    if document.get('draft') is not True or document.get('timeline') != 'excerpt':
        raise ValueError('Transcript must be a draft on the excerpt timeline.')
    if document.get('audio_sha256') != identity['audio_sha256']:
        raise ValueError('Transcript belongs to different audio. Import or generate it again.')
    for key in ('duration', 'source_offset'):
        if abs(_number(document.get(key), key) - identity[key]) > _EPSILON:
            raise ValueError('Transcript timing differs from this excerpt.')
    if not isinstance(document.get('origin'), dict):
        raise ValueError('Transcript origin is missing.')
    document = dict(document, **identity)
    document['segments'] = _segments(document.get('segments'), identity['duration'])
    return document


@contextlib.contextmanager
def _write_lock(run):
    path = Path(run) / '.transcript.lock'
    handle = path.open('a+b')
    locked = False
    try:
        handle.seek(0, 2)
        if handle.tell() == 0:
            handle.write(b'0')
            handle.flush()
        handle.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
        except OSError as error:
            raise ValueError('Another process is saving this transcript. Try again later.') from error
        yield
    finally:
        if locked:
            handle.seek(0)
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()


def _save(run, document, expected_previous):
    run = Path(run)
    with _write_lock(run):
        document = _validate(document, _identity(run))
        if _previous(run) != expected_previous:
            raise ValueError('Transcript changed while processing. Reload before replacing it.')
        path = run / 'transcript.json'
        temporary = run / ('transcript_' + uuid.uuid4().hex + '.tmp')
        try:
            with temporary.open('w', encoding='utf-8', newline='\n') as output:
                json.dump(document, output, indent=2, ensure_ascii=False, allow_nan=False)
                output.write('\n')
                output.flush()
                os.fsync(output.fileno())
            if path.exists():
                history = run / 'history'
                history.mkdir(exist_ok=True)
                stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')
                shutil.copyfile(path, history / f'transcript_{stamp}_{uuid.uuid4().hex[:8]}.json')
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    return document


def load(run):
    """Read a draft, rejecting stale audio or a different excerpt timeline."""
    path = Path(run) / 'transcript.json'
    if not path.exists():
        return None
    return _validate(json.loads(path.read_text(encoding='utf-8-sig')), _identity(run))


def _timestamp(value):
    match = re.fullmatch(r'(?:(\d+):)?(\d{2}):(\d{2})[,.](\d{3})', value.strip())
    if not match:
        raise ValueError('Subtitle times must use hours, minutes, seconds, and milliseconds.')
    hours, minutes, seconds, millis = match.groups()
    if int(minutes) >= 60 or int(seconds) >= 60:
        raise ValueError('Subtitle minutes and seconds must be below sixty.')
    return int(hours or 0) * 3600 + int(minutes) * 60 + int(seconds) + int(millis) / 1000


def _subtitles(text, webvtt=False):
    text = text.replace('\r\n', '\n').replace('\r', '\n').lstrip('\ufeff')
    blocks = re.split(r'\n[ \t]*\n', text.strip())
    if webvtt:
        if not blocks or not blocks[0].splitlines()[0].startswith('WEBVTT'):
            raise ValueError('A VTT file must begin with WEBVTT.')
        blocks = blocks[1:]
    result = []
    for block in blocks:
        lines = block.splitlines()
        if not lines:
            continue
        if webvtt and lines[0].split(' ', 1)[0] in ('NOTE', 'STYLE', 'REGION'):
            continue
        position = next((i for i in range(min(2, len(lines))) if '-->' in lines[i]), None)
        if position is None:
            raise ValueError('Subtitle cue has no timing line.')
        start, end = lines[position].split('-->', 1)
        end_parts = end.strip().split()
        if not end_parts:
            raise ValueError('Subtitle cue has no end time.')
        value = ' '.join(lines[position + 1:])
        value = html.unescape(re.sub(r'<[^>]*>', '', value)).strip()
        result.append({'start': _timestamp(start), 'end': _timestamp(end_parts[0]), 'text': value})
    return result


def import_transcript(run, path, timeline='excerpt'):
    """Import Whisper JSON, SRT, or VTT and attach it to this excerpt.

    Original timeline imports are intersected with the excerpt. A clipped cue
    keeps a clipped flag because its text may extend outside the playable part.
    """
    identity = _identity(run)
    previous = _previous(run)
    path = Path(path)
    content = path.read_text(encoding='utf-8-sig')
    kind = path.suffix.lower()
    language = None
    if kind == '.json':
        raw = json.loads(content)
        if not isinstance(raw, dict):
            raise ValueError('Transcript JSON must be an object containing segments.')
        if 'audio_sha256' in raw:
            raw = _validate(raw, identity)
            if timeline != 'excerpt':
                raise ValueError('A saved transcript already uses excerpt times.')
        segments = raw.get('segments')
        origin = raw.get('origin')
        language = raw.get('language', origin.get('language') if isinstance(origin, dict) else None)
    elif kind in ('.srt', '.vtt'):
        segments = _subtitles(content, webvtt=kind == '.vtt')
    else:
        raise ValueError('Choose a Whisper JSON, SRT, or VTT transcript.')
    converted = _segments(segments, identity['duration'], identity['source_offset'], timeline)
    if segments and not converted:
        raise ValueError('No transcript segments overlap this excerpt. Check the selected timeline.')
    origin = {'kind': 'import', 'format': kind[1:], 'filename': path.name,
              'input_sha256': _digest(path), 'input_timeline': timeline,
              'created_utc': datetime.now(timezone.utc).isoformat()}
    if language is not None:
        origin['language'] = _text(language, 'Language')
    return _save(run, _document(identity, converted, origin), previous)


def for_interval(document, start, end):
    """Return transcript segments overlapping a selected annotation interval."""
    start, end = _number(start, 'Interval start'), _number(end, 'Interval end')
    if not 0 <= start < end:
        raise ValueError('Select a valid audio interval.')
    if document is None:
        return []
    return [segment for segment in document['segments']
            if segment['start'] < end and segment['end'] > start]


def _check_cancel(cancelled):
    if cancelled is not None and cancelled():
        raise TranscriptCancelled('Transcription stopped. The previous transcript was retained.')


def _notify(progress, fraction, message):
    if progress:
        progress(max(0., min(1., float(fraction))), message)


def _load_model(model, model_directory, allow_download):
    os.environ.setdefault('HF_HUB_DISABLE_TELEMETRY', '1')
    try:
        from faster_whisper import WhisperModel
        from faster_whisper.utils import download_model
    except ImportError as error:
        raise RuntimeError('The optional speech component is not installed. Run setup_transcription.cmd first.') from error
    local = Path(model).expanduser()
    if local.is_dir():
        location = local.resolve()
    else:
        if model not in SUPPORTED_MODELS:
            raise ValueError('Choose tiny, base, small, or an existing local model folder.')
        location = Path(download_model(model, cache_dir=str(model_directory) if model_directory else None,
            local_files_only=not allow_download, use_auth_token=False))
    # Without this check, the library can download a missing tokenizer even when
    # a model directory or a cached model has been supplied.
    required = ('model.bin', 'config.json', 'tokenizer.json')
    if not all((location / name).is_file() for name in required):
        raise ValueError('The local model is incomplete. Model, configuration, and tokenizer files are required.')
    instance = WhisperModel(str(location), device='cpu', compute_type='int8', cpu_threads=4,
                           local_files_only=True, use_auth_token=False)
    revision = location.name if re.fullmatch('[0-9a-f]{40}', location.name) else None
    return instance, revision


def _speech_audio(run):
    """Supply 16 kHz mono PCM directly, avoiding optional file decoder APIs."""
    import core
    import numpy as np
    import parselmouth
    rate, samples = core.mono_audio(Path(run) / 'excerpt.wav')
    if rate != 16000:
        sound = parselmouth.Sound(samples, sampling_frequency=rate)
        samples = sound.resample(16000, 50).values[0]
    return np.ascontiguousarray(samples, dtype=np.float32)


def generate(run, model='tiny', model_directory=None, allow_download=False,
             language=None, progress=None, cancelled=None):
    """Generate a local transcript draft, replacing nothing until completion.

    Cancellation is checked between model loading and decoded segments. A model
    load or a decoding step already in progress must finish before it can stop.
    Progress callbacks receive a fraction and a short message.
    """
    identity = _identity(run)
    previous = _previous(run)
    model = str(model)
    if language is not None:
        language = _text(language, 'Language') or None
    _check_cancel(cancelled)
    _notify(progress, 0., 'Loading the speech model')
    instance, revision = _load_model(model, model_directory, allow_download)
    _check_cancel(cancelled)
    _notify(progress, .02, 'Transcribing the excerpt locally')
    audio = _speech_audio(run)
    _check_cancel(cancelled)
    iterator, info = instance.transcribe(audio, language=language,
        beam_size=5, word_timestamps=True, vad_filter=True, condition_on_previous_text=False)
    segments = []
    for segment in iterator:
        _check_cancel(cancelled)
        item = {'start': float(segment.start), 'end': float(segment.end), 'text': segment.text}
        if segment.words is not None:
            item['words'] = [{'start': float(word.start), 'end': float(word.end),
                              'word': word.word, 'probability': float(word.probability)}
                             for word in segment.words]
        segments.append(item)
        _notify(progress, .02 + .96 * min(1., float(segment.end) / identity['duration']),
                f'Transcribed through {min(float(segment.end), identity["duration"]):.1f} seconds')
    _check_cancel(cancelled)
    # The decoder reports times on a 20 ms grid. Its last endpoint can fall
    # slightly past the exact sample duration; clip only that rounding margin.
    for segment in segments:
        if identity['duration'] < segment['end'] <= identity['duration'] + .03:
            segment['end'] = identity['duration']
        for word in segment.get('words', []):
            if segment['end'] < word['end'] <= segment['end'] + .03:
                word['end'] = segment['end']
    converted = _segments(segments, identity['duration'])
    origin = {'kind': 'generated', 'engine': 'faster-whisper',
              'model': Path(model).name, 'device': 'cpu', 'compute_type': 'int8',
              'language': str(info.language), 'input_timeline': 'excerpt',
              'created_utc': datetime.now(timezone.utc).isoformat()}
    if revision:
        origin['model_revision'] = revision
    probability = getattr(info, 'language_probability', None)
    if probability is not None:
        origin['language_probability'] = _number(probability, 'Language probability')
        if not 0 <= origin['language_probability'] <= 1:
            raise ValueError('Language probability must be between zero and one.')
    _check_cancel(cancelled)
    saved = _save(run, _document(identity, converted, origin), previous)
    _notify(progress, 1., 'Transcript draft saved')
    return saved

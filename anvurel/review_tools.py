"""Form recovery, guarded undo, and pitch preserving review playback."""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import uuid

import parselmouth
from parselmouth.praat import call

import core

DRAFT_NAME = 'form_draft.json'
FORM_FIELDS = ('speaker', 'valence', 'arousal', 'start', 'end')


def _hash(data):
    return hashlib.sha256(data).hexdigest()


def _atomic_bytes(path, data):
    path = Path(path)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('xb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _state(run):
    run = Path(run).resolve()
    grid = (run / 'annotations.TextGrid').read_bytes()
    approval = (run / 'reviews.json').read_bytes()
    metadata = (run / 'run.json').read_bytes()
    meta, rows, reviews = core.load_run(run)
    if (grid != (run / 'annotations.TextGrid').read_bytes()
            or approval != (run / 'reviews.json').read_bytes()
            or metadata != (run / 'run.json').read_bytes()):
        raise ValueError('Annotations changed while reading. Reload the run and try again.')
    return dict(run=run, meta=meta, rows=rows, reviews=reviews, grid=grid,
                approval=approval, grid_hash=_hash(grid), review_hash=_hash(approval),
                meta_hash=_hash(metadata), audio_hash=meta['excerpt_sha256'])


def _form(values, duration):
    if not isinstance(values, dict) or set(values) != set(FORM_FIELDS):
        raise ValueError('A form draft needs speaker, valence, arousal, start, and end values.')
    permitted = {'speaker': ('', '?', 'FAN-?', 'MAN-?') + core.SPEAKERS,
                 'valence': ('', '?', '+1', '0', '-1'), 'arousal': ('', '?', '+1', '-1')}
    if any(values[key] not in choices for key, choices in permitted.items()):
        raise ValueError('The form draft contains an unsupported label.')
    try:
        start, end = float(values['start']), float(values['end'])
    except (TypeError, ValueError):
        raise ValueError('Draft start and end times must be numbers.') from None
    if not all(math.isfinite(value) for value in (start, end)) or not 0 <= start < end <= duration:
        raise ValueError('Draft times must describe an interval inside the excerpt.')
    return {**{key: values[key] for key in permitted}, 'start': str(values['start']), 'end': str(values['end'])}


def save_draft(run, index, values, reviewer, expected_grid_hash):
    """Save an incomplete form without editing the TextGrid or any approval."""
    state = _state(run)
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < len(state['rows']):
        raise ValueError('The selected draft interval does not exist.')
    if expected_grid_hash != state['grid_hash']:
        raise ValueError('Annotations changed externally. Reload before saving a form draft.')
    if not isinstance(reviewer, str) or len(reviewer) > 256:
        raise ValueError('Reviewer ID must be text of at most 256 characters.')
    form = _form(values, state['meta']['duration'])
    row = state['rows'][index]
    data = dict(version=1, saved_utc=core.now(), run=str(state['run']),
                audio_sha256=state['audio_hash'], grid_sha256=state['grid_hash'],
                index=index, interval_start=row['start'], interval_end=row['end'],
                values=form, reviewer=reviewer)
    if core.digest(state['run'] / 'annotations.TextGrid') != state['grid_hash']:
        raise ValueError('Annotations changed during draft save. Reload before saving.')
    _atomic_bytes(state['run'] / DRAFT_NAME,
                  json.dumps(data, indent=2, allow_nan=False).encode('utf-8'))
    return data


def load_draft(run):
    """Return a recoverable form or reject a form bound to older annotations."""
    run = Path(run).resolve()
    path = run / DRAFT_NAME
    if not path.exists():
        return None
    try:
        draft = json.loads(path.read_text(encoding='utf-8'))
        state = _state(run)
        if not isinstance(draft, dict) or draft.get('version') != 1:
            raise ValueError('Unsupported saved form draft.')
        if draft.get('run') != str(run) or draft.get('audio_sha256') != state['audio_hash']:
            raise ValueError('The saved form draft belongs to a different run or audio excerpt.')
        if draft.get('grid_sha256') != state['grid_hash']:
            raise ValueError('The saved form draft uses older annotations. Discard it or inspect it before continuing.')
        index = draft['index']
        if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < len(state['rows']):
            raise ValueError('The saved form interval does not exist.')
        row = state['rows'][index]
        if draft['interval_start'] != row['start'] or draft['interval_end'] != row['end']:
            raise ValueError('The saved form boundaries differ from the current annotations.')
        draft['values'] = _form(draft['values'], state['meta']['duration'])
        if not isinstance(draft['reviewer'], str) or len(draft['reviewer']) > 256:
            raise ValueError('The saved reviewer ID is invalid.')
        return draft
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError('The saved form draft is incomplete or unreadable. It has been retained for inspection.') from error


def clear_draft(run):
    (Path(run).resolve() / DRAFT_NAME).unlink(missing_ok=True)


def checkpoint(run):
    """Take a snapshot in memory before one annotation operation."""
    state = _state(run)
    return dict(version=1, run=str(state['run']), audio_hash=state['audio_hash'],
                meta_hash=state['meta_hash'], before_grid=state['grid'],
                before_reviews=state['approval'], before_grid_hash=state['grid_hash'],
                before_review_hash=state['review_hash'], used=False)


def _token_identity(state, token):
    if not isinstance(token, dict) or token.get('version') != 1:
        raise ValueError('This undo record is not supported.')
    if token.get('used'):
        raise ValueError('This action has already been undone.')
    if token.get('run') != str(state['run']) or token.get('audio_hash') != state['audio_hash'] or token.get('meta_hash') != state['meta_hash']:
        raise ValueError('The undo record belongs to a different run or preparation state.')
    try:
        intact = (_hash(token['before_grid']) == token['before_grid_hash']
                  and _hash(token['before_reviews']) == token['before_review_hash'])
    except (KeyError, TypeError):
        intact = False
    if not intact:
        raise ValueError('The undo snapshot has changed and cannot be restored.')


def seal_checkpoint(run, token):
    """Record the completed operation, including approvals, before enabling undo."""
    state = _state(run)
    _token_identity(state, token)
    if 'after_grid_hash' in token:
        raise ValueError('This undo record has already been sealed.')
    token.update(after_grid_hash=state['grid_hash'], after_review_hash=state['review_hash'],
                 changed=(state['grid_hash'] != token['before_grid_hash'] or state['review_hash'] != token['before_review_hash']))
    return token


def undo(run, token, expected_grid_hash):
    """Restore one sealed operation only when its annotations and approvals still match."""
    state = _state(run)
    _token_identity(state, token)
    if 'after_grid_hash' not in token:
        raise ValueError('This action was not completed and cannot be undone.')
    if (expected_grid_hash != state['grid_hash'] or token['after_grid_hash'] != state['grid_hash']
            or token['after_review_hash'] != state['review_hash']):
        raise ValueError('Annotations or approvals changed after this action. Reload before continuing.')
    run = state['run']
    history = run / 'history'
    history.mkdir(exist_ok=True)
    prefix = 'before_undo_' + uuid.uuid4().hex
    _atomic_bytes(history / (prefix + '.TextGrid'), state['grid'])
    _atomic_bytes(history / (prefix + '.reviews.json'), state['approval'])
    if core.digest(run / 'annotations.TextGrid') != state['grid_hash'] or core.digest(run / 'reviews.json') != state['review_hash']:
        raise ValueError('Annotations changed during undo. No undo was applied.')
    grid_restored = False
    try:
        _atomic_bytes(run / 'annotations.TextGrid', token['before_grid'])
        grid_restored = True
        if core.digest(run / 'reviews.json') != state['review_hash']:
            raise ValueError('Approvals changed during undo. Reload the run.')
        _atomic_bytes(run / 'reviews.json', token['before_reviews'])
    except Exception:
        # Replace only our restored grid if the second write failed.
        if grid_restored and core.digest(run / 'annotations.TextGrid') == token['before_grid_hash']:
            _atomic_bytes(run / 'annotations.TextGrid', state['grid'])
        raise
    token['used'] = True


def make_playback(run, start, end, speed=1.0, context=0.0):
    """Create a review WAV; slower playback uses Praat duration manipulation."""
    state = _state(run)
    try:
        start, end, speed, context = map(float, (start, end, speed, context))
    except (TypeError, ValueError):
        raise ValueError('Playback times, speed, and context must be numbers.') from None
    if not all(math.isfinite(value) for value in (start, end, speed, context)):
        raise ValueError('Playback values must be finite.')
    if not 0 <= start < end <= state['meta']['duration']:
        raise ValueError('The playback interval must be inside the excerpt.')
    if not .5 <= speed <= 1.5 or not 0 <= context <= 5:
        raise ValueError('Use a playback speed from 0.5 to 1.5 and context from 0 to 5 seconds.')
    run = state['run']
    source = run / 'excerpt.wav'
    target = run / 'playback_guided.wav'
    temporary = run / ('playback_' + uuid.uuid4().hex + '.wav')
    a, b = max(0, start-context), min(state['meta']['duration'], end+context)
    try:
        core.copy_audio(source, temporary, a, b)
        if abs(speed - 1) > 1e-9:
            sound = parselmouth.Sound(str(temporary))
            if sound.n_channels > 1:
                sound = call(sound, 'Convert to mono')
            try:
                manipulation = call(sound, 'To Manipulation', .01, 60, 600)
                tier = call(manipulation, 'Extract duration tier')
                call(tier, 'Add point', 0., 1 / speed)
                call(tier, 'Add point', sound.duration, 1 / speed)
                call([tier, manipulation], 'Replace duration tier')
                result = call(manipulation, 'Get resynthesis (overlap-add)')
                result.save(str(temporary), parselmouth.SoundFileFormat.WAV)
            except parselmouth.PraatError as error:
                raise ValueError('Pitch preserving playback could not be prepared. Use normal speed or include more context.') from error
        if core.digest(source) != state['audio_hash']:
            raise ValueError('Excerpt audio changed while preparing playback. Reload the run.')
        temporary.replace(target)
        return target
    finally:
        temporary.unlink(missing_ok=True)

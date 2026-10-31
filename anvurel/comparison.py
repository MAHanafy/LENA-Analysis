"""Read independent annotations and report differences without changing either run."""
from __future__ import annotations

import bisect
from datetime import datetime
import json
import math
from pathlib import Path
import uuid

import core


KNOWN = {'speaker_speech': set(core.SPEAKERS),
         'valence': {'+1', '0', '-1'}, 'arousal': {'+1', '-1'}}
EPSILON = 1e-7


def _active(row):
    return any(row[tier] for tier in core.TIERS)


def _side(rows, reviews, index):
    row = rows[index]
    review = reviews.get(core.signature(row)) if isinstance(reviews, dict) else None
    reviewer = review.get('reviewer') if isinstance(review, dict) else None
    approved_utc = review.get('approved_utc') if isinstance(review, dict) else None
    try:
        dated = isinstance(approved_utc, str) and datetime.fromisoformat(approved_utc).tzinfo is not None
    except ValueError:
        dated = False
    approved = bool(core.valid(row) and isinstance(reviewer, str) and reviewer.strip() and dated)
    return dict(interval=index + 1, start=row['start'], end=row['end'],
                labels={tier: row[tier] for tier in core.TIERS}, active=_active(row),
                approved=approved, reviewer=reviewer.strip() if approved else None)


def _identity(meta):
    duration = meta.get('duration')
    offset = meta.get('source_offset')
    if (isinstance(duration, bool) or not isinstance(duration, (int, float))
            or not math.isfinite(duration) or duration <= 0
            or isinstance(offset, bool) or not isinstance(offset, (int, float))
            or not math.isfinite(offset) or offset < 0):
        raise ValueError('Run timing must contain a positive duration and a valid source offset.')
    if meta.get('group') not in ('NH', 'HA', 'Reference'):
        raise ValueError('Run has an unsupported group.')
    return dict(excerpt_sha256=meta['excerpt_sha256'], source_offset=offset,
                duration=duration, group=meta['group'])


def _row_at(rows, time):
    """Use the interval after a boundary; the final endpoint belongs to the last row."""
    return min(len(rows) - 1, bisect.bisect_right(rows, time, key=lambda row: row['end']))


def _snapshot(run):
    return {name: core.digest(Path(run) / name)
            for name in ('excerpt.wav', 'annotations.TextGrid', 'run.json', 'reviews.json')}


def ensure_current(report):
    """Reject a report after either input changes; callers must compare again."""
    if report.get('version') != 1 or not isinstance(report.get('inputs'), dict):
        raise ValueError('Comparison input checksums are missing. Compare the reviews again.')
    for side in ('left', 'right'):
        if _snapshot(report[side + '_run']) != report['inputs'].get(side):
            raise ValueError('A review changed after this comparison. Compare the reviews again.')
    return True


def _boundaries(rows):
    return [(rows[index]['start'], index if _active(rows[index]) else index - 1)
            for index in range(1, len(rows))
            if _active(rows[index - 1]) or _active(rows[index])]


def _boundary_pairs(left, right, tolerance):
    """Match once in chronological order, maximizing the number within tolerance."""
    pairs, left_missing, right_missing = [], [], []
    i = j = 0
    while i < len(left) and j < len(right):
        a, b = left[i][0], right[j][0]
        if a < b - tolerance - EPSILON:
            left_missing.append(left[i]); i += 1
        elif b < a - tolerance - EPSILON:
            right_missing.append(right[j]); j += 1
        else:
            pairs.append((left[i], right[j])); i += 1; j += 1
    return pairs, left_missing + left[i:], right_missing + right[j:]


def compare_runs(left, right, boundary_tolerance=0.05):
    """Compare the same audio excerpt using elapsed time rather than row positions.

    Tier agreement is a duration fraction among spans where both labels are known.
    It describes agreement, not accuracy. Boundaries are matched separately in time
    order, at most once per side, within the requested tolerance.
    """
    if (isinstance(boundary_tolerance, bool) or not isinstance(boundary_tolerance, (int, float))
            or not math.isfinite(boundary_tolerance) or boundary_tolerance < 0):
        raise ValueError('Boundary tolerance must be a finite number of seconds at or above zero.')
    left, right = Path(left).resolve(), Path(right).resolve()
    if left == right:
        raise ValueError('Choose two different review folders.')
    inputs = dict(left=_snapshot(left), right=_snapshot(right))
    lm, lrows, lreviews = core.load_run(left)
    rm, rrows, rreviews = core.load_run(right)
    identity, other = _identity(lm), _identity(rm)
    if (identity['excerpt_sha256'] != other['excerpt_sha256']
            or abs(identity['source_offset'] - other['source_offset']) > EPSILON
            or abs(identity['duration'] - other['duration']) > EPSILON
            or identity['group'] != other['group']):
        raise ValueError('Choose reviews of the same audio excerpt, source offset, duration, and group.')
    duration, offset = identity['duration'], identity['source_offset']
    lsides = [_side(lrows, lreviews, index) for index in range(len(lrows))]
    rsides = [_side(rrows, rreviews, index) for index in range(len(rrows))]
    reviewers = {name: sorted({side['reviewer'] for side in sides if side['approved']})
                 for name, sides in (('left', lsides), ('right', rsides))}
    warnings = []
    if not reviewers['left'] or not reviewers['right']:
        warnings.append('At least one review has no valid approval with a reviewer ID. Independent review is not established.')
    if set(reviewers['left']) & set(reviewers['right']):
        warnings.append('The same reviewer ID appears on both sides. These approvals do not establish independent review.')

    metrics = {tier: dict(agree_seconds=0., compared_seconds=0., agreement=None,
                         unknown_seconds=0., missing_seconds=0.) for tier in core.TIERS}
    entries = []

    def entry(kind, start, end, li, ri, different=(), unknown=(), issues=(), summary=''):
        entries.append(dict(id=f'difference_{len(entries)+1:05}', kind=kind,
            start=start, end=end, source_start=offset + start, source_end=offset + end,
            left_index=li, right_index=ri, left=dict(lsides[li]), right=dict(rsides[ri]),
            different_tiers=list(different), unknown_tiers=list(unknown),
            issues=list(issues), summary=summary))

    points = sorted({0., duration} | {row['start'] for row in lrows + rrows}
                    | {row['end'] for row in lrows + rrows})
    li = ri = 0
    active_seconds = reviewed_seconds = 0.
    for start, end in zip(points, points[1:]):
        if end - start <= EPSILON:
            continue
        midpoint = (start + end) / 2
        while li + 1 < len(lrows) and lrows[li]['end'] <= midpoint:
            li += 1
        while ri + 1 < len(rrows) and rrows[ri]['end'] <= midpoint:
            ri += 1
        a, b = lsides[li], rsides[ri]
        if not (a['active'] or b['active']):
            continue
        seconds = end - start
        active_seconds += seconds
        both = a['active'] and b['active']
        if both and a['approved'] and b['approved']:
            reviewed_seconds += seconds
        different, unknown, issues = [], [], []
        if not both:
            issues.append('Annotation is missing on one side.')
        for tier in core.TIERS:
            item = metrics[tier]
            av, bv = a['labels'][tier], b['labels'][tier]
            if not both:
                item['missing_seconds'] += seconds
            elif av not in KNOWN[tier] or bv not in KNOWN[tier]:
                item['unknown_seconds'] += seconds
                unknown.append(tier)
            else:
                item['compared_seconds'] += seconds
                if av == bv:
                    item['agree_seconds'] += seconds
                else:
                    different.append(tier)
        if unknown:
            issues.append('One or more labels are unknown or unsupported.')
        if not (a['approved'] and b['approved']):
            issues.append('Both sides do not have valid approvals for this span.')
        if not both:
            entry('missing_annotation', start, end, li, ri, different, unknown, issues,
                  'Annotation is missing on one side.')
        elif different:
            entry('label_disagreement', start, end, li, ri, different, unknown, issues,
                  'Different labels: ' + ', '.join(different) + '.')
        elif issues:
            entry('needs_review', start, end, li, ri, different, unknown, issues,
                  'Labels or approvals still need review.')

    for item in metrics.values():
        if item['compared_seconds'] > EPSILON:
            item['agreement'] = item['agree_seconds'] / item['compared_seconds']

    pairs, lmissing, rmissing = _boundary_pairs(_boundaries(lrows), _boundaries(rrows), boundary_tolerance)
    boundary_metrics = dict(tolerance_seconds=boundary_tolerance,
        left_count=len(_boundaries(lrows)), right_count=len(_boundaries(rrows)),
        matched_count=len(pairs), left_unmatched=[time for time, _ in lmissing],
        right_unmatched=[time for time, _ in rmissing],
        matches=[dict(left=a[0], right=b[0], delta_seconds=b[0]-a[0]) for a, b in pairs])
    for (at, ai), (bt, bi) in pairs:
        if abs(at - bt) > EPSILON:
            entry('boundary_shift', min(at, bt), max(at, bt), ai, bi,
                  issues=['Matched boundary times differ.'],
                  summary=f'Boundary differs by {abs(at-bt):.3f} seconds.')
            entries[-1]['left_boundary'] = at
            entries[-1]['right_boundary'] = bt
    for side, missing in (('left', lmissing), ('right', rmissing)):
        for time, index in missing:
            ai = index if side == 'left' else _row_at(lrows, time)
            bi = index if side == 'right' else _row_at(rrows, time)
            entry('boundary_unmatched', max(0., time - .1), min(duration, time + .1), ai, bi,
                  issues=['A boundary has no match within tolerance.'],
                  summary=f'Boundary on the {side} has no match within tolerance.')
            entries[-1]['boundary_side'] = side
            entries[-1]['boundary_time'] = time
    entries.sort(key=lambda item: (item['start'], item['end'], item['kind']))
    for index, item in enumerate(entries, 1):
        item['id'] = f'difference_{index:05}'
    if inputs != dict(left=_snapshot(left), right=_snapshot(right)):
        raise ValueError('A review changed while it was being compared. Compare the reviews again.')
    return dict(version=1, created_utc=core.now(), identity=identity, inputs=inputs,
        left_run=str(left), right_run=str(right), reviewers=reviewers, warnings=warnings,
        metrics=dict(tiers=metrics, boundaries=boundary_metrics,
            active_union_seconds=active_seconds, both_approved_seconds=reviewed_seconds,
            left_active_intervals=sum(side['active'] for side in lsides),
            right_active_intervals=sum(side['active'] for side in rsides),
            agreement_scope='Duration with a known label on both sides, including draft labels. Unknown and missing labels are excluded. Both approved duration is reported separately.'),
        entries=entries)


def save_report(report, output):
    """Write a new report folder. Reports never apply a consensus annotation."""
    if report.get('version') != 1 or not isinstance(report.get('entries'), list):
        raise ValueError('Unsupported comparison report.')
    ensure_current(report)
    encoded = json.dumps(report, indent=2, allow_nan=False)
    output = Path(output).resolve()
    for key in ('left_run', 'right_run'):
        review = Path(report[key]).resolve()
        if output == review or review in output.parents:
            raise ValueError('Save comparisons outside the input review folders.')
    output.mkdir(parents=True, exist_ok=True)
    destination = output / ('comparison_' + uuid.uuid4().hex[:12])
    destination.mkdir(exist_ok=False)
    rows = []
    for item in report['entries']:
        row = {name: item[name] for name in ('id', 'kind', 'start', 'end', 'source_start', 'source_end')}
        row.update(summary=item['summary'], different_tiers='; '.join(item['different_tiers']),
                   unknown_tiers='; '.join(item['unknown_tiers']), issues='; '.join(item['issues']))
        for side in ('left', 'right'):
            data = item[side]
            row.update({f'{side}_{tier}': data['labels'][tier] for tier in core.TIERS})
            row.update({f'{side}_{key}': data[key] for key in ('interval', 'approved', 'reviewer')})
        rows.append(row)
    fields = ['id', 'kind', 'start', 'end', 'source_start', 'source_end', 'summary',
              'different_tiers', 'unknown_tiers', 'issues']
    for side in ('left', 'right'):
        fields += [f'{side}_{tier}' for tier in core.TIERS]
        fields += [f'{side}_{key}' for key in ('interval', 'approved', 'reviewer')]
    core.write_csv(destination / 'differences.csv', rows, fields)
    tier_rows = [dict(tier=tier, **values) for tier, values in report['metrics']['tiers'].items()]
    core.write_csv(destination / 'agreement.csv', tier_rows,
        ['tier', 'agree_seconds', 'compared_seconds', 'agreement', 'unknown_seconds', 'missing_seconds'])
    (destination / 'comparison.json').write_text(encoded, encoding='utf-8')
    return destination

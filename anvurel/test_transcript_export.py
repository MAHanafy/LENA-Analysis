"""Verify transcript snapshots and clip time mapping using generated recordings."""
import csv
import json
from pathlib import Path

import core
import transcript_export
import transcripts
from test_automation import Fixture


class TranscriptExportTests(Fixture):
    def setUp(self):
        super().setUp()
        self.run = self.make_run()
        self.metadata, self.rows, _ = core.load_run(self.run)
        self.indices = [index for index, row in enumerate(self.rows) if row['speaker_speech']]
        for index in self.indices:
            self.rows[index].update(speaker_speech='FAN-CDS', valence='+1', arousal='-1')
        core.save_annotations(self.run, self.rows, core.digest(self.run / 'annotations.TextGrid'))
        for index in self.indices:
            core.approve(self.run, index, 'rater_one')
        self.selected = [(index, self.rows[index]) for index in self.indices]

    def transcript_source(self, segments):
        source = self.root / 'transcript_input.json'
        source.write_text(json.dumps({'segments': segments}), encoding='utf-8')
        return source

    def import_segments(self, segments, timeline='excerpt'):
        return transcripts.import_transcript(self.run, self.transcript_source(segments), timeline=timeline)

    def set_offset(self, offset):
        path = self.run / 'run.json'
        metadata = json.loads(path.read_text())
        metadata['source_offset'] = offset
        metadata['source_end'] = offset + metadata['duration']
        path.write_text(json.dumps(metadata), encoding='utf-8')

    def destination(self):
        destination = self.root / 'export'
        destination.mkdir()
        return destination

    def test_nonzero_offset_and_partial_cue_map_to_original_and_clip_time(self):
        self.set_offset(20.)
        index, row = self.selected[0]
        cue_start, cue_end = row['start'] - .2, row['end'] + .2
        self.import_segments([{'start': cue_start, 'end': cue_end, 'text': 'Full cue text'}])
        bundle = transcript_export.prepare_export(self.run, self.selected[:1])
        record = bundle['rows'][0]
        self.assertEqual(record['sample_id'], f'interval_{index+1:05d}')
        self.assertEqual(record['interval'], index + 1)
        self.assertEqual(record['segment'], 1)
        self.assertEqual(record['excerpt_start'], row['start'])
        self.assertEqual(record['excerpt_end'], row['end'])
        self.assertEqual(record['source_start'], row['start'] + 20.)
        self.assertEqual(record['source_end'], row['end'] + 20.)
        self.assertEqual(record['clip_start'], 0.)
        self.assertAlmostEqual(record['clip_end'], row['end'] - row['start'])
        self.assertEqual(record['text'], 'Full cue text')
        self.assertTrue(record['partial_cue'])
        self.assertTrue(record['draft'])
        self.assertEqual(bundle['document']['segments'][0]['start'], cue_start)

    def test_complete_cue_inside_clip_has_offset_and_no_partial_flag(self):
        _, row = self.selected[0]
        start, end = row['start'] + .1, row['end'] - .1
        self.import_segments([{'start': start, 'end': end, 'text': 'Inside cue'}])
        record = transcript_export.prepare_export(self.run, self.selected[:1])['rows'][0]
        self.assertAlmostEqual(record['clip_start'], .1)
        self.assertAlmostEqual(record['clip_end'], end - row['start'])
        self.assertFalse(record['partial_cue'])

    def test_one_cue_can_map_to_many_clips_without_repeating_annotation_indices(self):
        self.import_segments([{'start': 0., 'end': 6., 'text': 'Long cue spanning clips'}])
        records = transcript_export.prepare_export(self.run, self.selected)['rows']
        self.assertEqual(len(records), len(self.selected))
        self.assertEqual({row['segment'] for row in records}, {1})
        self.assertEqual(len({row['sample_id'] for row in records}), len(self.selected))
        self.assertTrue(all(row['partial_cue'] for row in records))

    def test_touching_cues_do_not_overlap_a_clip(self):
        _, row = self.selected[0]
        self.import_segments([{'start': 0., 'end': row['start'], 'text': 'Before'},
                              {'start': row['end'], 'end': 6., 'text': 'After'}])
        bundle = transcript_export.prepare_export(self.run, self.selected[:1])
        self.assertEqual(bundle['rows'], [])
        destination = self.destination()
        transcript_export.write_export(bundle, destination)
        with (destination / 'transcript_segments.csv').open(encoding='utf-8-sig', newline='') as stream:
            reader = csv.DictReader(stream)
            self.assertEqual(tuple(reader.fieldnames), transcript_export.FIELDS)
            self.assertEqual(list(reader), [])

    def test_original_timeline_clipping_is_still_marked_partial(self):
        self.set_offset(20.)
        self.import_segments([{'start': 19., 'end': 27., 'text': 'Cue clipped to excerpt'}], timeline='original')
        bundle = transcript_export.prepare_export(self.run, self.selected)
        self.assertTrue(bundle['document']['segments'][0]['clipped'])
        self.assertTrue(all(row['partial_cue'] for row in bundle['rows']))

    def test_no_transcript_produces_no_files_or_directory(self):
        bundle = transcript_export.prepare_export(self.run, self.selected)
        self.assertIsNone(bundle)
        destination = self.root / 'not_created'
        transcript_export.write_export(bundle, destination)
        self.assertFalse(destination.exists())

    def test_stale_transcript_and_audio_are_rejected_before_writing(self):
        self.import_segments([{'start': 1., 'end': 2., 'text': 'Draft'}])
        path = self.run / 'transcript.json'
        document = json.loads(path.read_text())
        document['audio_sha256'] = 'wrong'
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(ValueError, 'different audio'):
            transcript_export.prepare_export(self.run, self.selected)
        path.unlink()
        with (self.run / 'excerpt.wav').open('ab') as stream:
            stream.write(b'changed')
        with self.assertRaisesRegex(ValueError, 'Excerpt audio changed'):
            transcript_export.prepare_export(self.run, self.selected)
        self.assertFalse((self.root / 'export').exists())

    def test_changed_or_unapproved_selection_is_rejected(self):
        self.import_segments([{'start': 0., 'end': 6., 'text': 'Draft'}])
        index, row = self.selected[0]
        wrong = dict(row, valence='-1')
        with self.assertRaisesRegex(ValueError, 'changed or is no longer approved'):
            transcript_export.prepare_export(self.run, [(index, wrong)])
        (self.run / 'reviews.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'changed or is no longer approved'):
            transcript_export.prepare_export(self.run, self.selected)

    def test_json_and_csv_are_detached_clean_snapshots_and_run_stays_unchanged(self):
        _, row = self.selected[0]
        document = self.import_segments([{'start': row['start'], 'end': row['end'],
            'text': 'Text with commas, quotes "and" Unicode café',
            'words': [{'start': row['start'], 'end': row['end'], 'word': 'café', 'probability': .9}]}])
        before = {path.name: path.read_bytes() for path in self.run.iterdir() if path.is_file()}
        bundle = transcript_export.prepare_export(self.run, self.selected[:1])
        document['segments'][0]['text'] = 'Changed in a caller object'
        destination = self.destination()
        transcript_export.write_export(bundle, destination)
        snapshot = json.loads((destination / 'transcript.json').read_text(encoding='utf-8'))
        self.assertTrue(snapshot['draft'])
        self.assertEqual(snapshot['audio_sha256'], core.digest(self.run / 'excerpt.wav'))
        self.assertNotIn('Changed in a caller object', snapshot['segments'][0]['text'])
        self.assertEqual(snapshot, bundle['document'])
        with (destination / 'transcript_segments.csv').open(encoding='utf-8-sig', newline='') as stream:
            reader = csv.DictReader(stream)
            self.assertEqual(tuple(reader.fieldnames), transcript_export.FIELDS)
            records = list(reader)
        self.assertEqual(records[0]['text'], snapshot['segments'][0]['text'])
        self.assertEqual(records[0]['draft'], 'True')
        self.assertEqual(records[0]['partial_cue'], 'False')
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.run.iterdir() if path.is_file()})
        with self.assertRaises(FileExistsError):
            transcript_export.write_export(bundle, destination)

    def test_duplicate_indices_and_invalid_json_metadata_are_rejected(self):
        self.import_segments([{'start': 0., 'end': 6., 'text': 'Draft'}])
        with self.assertRaisesRegex(ValueError, 'unique current annotation index'):
            transcript_export.prepare_export(self.run, self.selected + self.selected)
        path = self.run / 'transcript.json'
        document = json.loads(path.read_text())
        document['origin']['bad_number'] = float('nan')
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(ValueError, 'valid JSON'):
            transcript_export.prepare_export(self.run, self.selected)

    def test_clip_mapping_uses_sample_quantized_manifest_bounds(self):
        self.set_offset(20.)
        index, _ = self.selected[0]
        core.set_boundaries(self.run, index, .800013, 1.800017,
                            core.digest(self.run / 'annotations.TextGrid'))
        _, rows, _ = core.load_run(self.run)
        row = rows[index]
        core.approve(self.run, index, 'rater_one')
        self.import_segments([{'start': .75, 'end': 1.9, 'text': 'Cue across the physical clip'},
                              {'start': .800020, 'end': 1.799999, 'text': 'Cue within the physical clip'}])
        physical_clip = self.root / 'physical_clip.wav'
        a, b = core.copy_audio(self.run / 'excerpt.wav', physical_clip, row['start'], row['end'])
        self.assertNotEqual(a, row['start'])
        self.assertNotEqual(b, row['end'])
        records = transcript_export.prepare_export(self.run, [(index, row)])['rows']
        whole, inner = records
        self.assertEqual(whole['excerpt_start'], a)
        self.assertEqual(whole['excerpt_end'], b)
        self.assertEqual(whole['source_start'], 20. + a)
        self.assertEqual(whole['source_end'], 20. + b)
        self.assertEqual(whole['clip_start'], 0.)
        self.assertEqual(whole['clip_end'], b-a)
        self.assertAlmostEqual(whole['clip_end'], core.audio_info(physical_clip)['duration'])
        self.assertTrue(whole['partial_cue'])
        self.assertAlmostEqual(inner['clip_start'], .800020-a)
        self.assertAlmostEqual(inner['clip_end'], 1.799999-a)
        self.assertFalse(inner['partial_cue'])

    def test_selected_interval_shorter_than_one_sample_is_rejected(self):
        index, _ = self.selected[0]
        core.set_boundaries(self.run, index, .800013, .800019,
                            core.digest(self.run / 'annotations.TextGrid'))
        _, rows, _ = core.load_run(self.run)
        core.approve(self.run, index, 'rater_one')
        self.import_segments([{'start': 0., 'end': 6., 'text': 'Long cue'}])
        with self.assertRaisesRegex(ValueError, 'shorter than one audio sample'):
            transcript_export.prepare_export(self.run, [(index, rows[index])])
        self.assertFalse((self.root / 'export').exists())

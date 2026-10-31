"""Exercise transcript timing, identity checks, and safe replacement."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import threading
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import wave

import numpy as np

import transcripts


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.run = self.root / 'run'
        self.run.mkdir()
        with wave.open(str(self.run / 'excerpt.wav'), 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            audio.writeframes(b'\0\0' * 64000)
        self.metadata = {'duration': 4., 'source_offset': 10.,
                         'excerpt_sha256': transcripts._digest(self.run / 'excerpt.wav')}
        self.write_metadata()
        for name in ('annotations.TextGrid', 'reviews.json', 'run.json'):
            if not (self.run / name).exists():
                (self.run / name).write_text('untouched', encoding='utf-8')
        self.records = {name: (self.run / name).read_bytes()
                        for name in ('annotations.TextGrid', 'reviews.json', 'run.json')}

    def tearDown(self):
        self.temp.cleanup()

    def write_metadata(self):
        (self.run / 'run.json').write_text(json.dumps(self.metadata), encoding='utf-8')

    def source(self, content, suffix='.json'):
        path = self.root / ('input' + suffix)
        path.write_text(content if isinstance(content, str) else json.dumps(content), encoding='utf-8')
        return path

    def initial(self):
        return transcripts.import_transcript(self.run, self.source({
            'segments': [{'start': .5, 'end': 1.5, 'text': 'Previous words'}]}))

    def assert_records_unchanged(self):
        for name, data in self.records.items():
            self.assertEqual((self.run / name).read_bytes(), data, name)

    def engine(self, segments, language='en'):
        instance = Mock()
        instance.transcribe.return_value = (iter(segments), SimpleNamespace(language=language, language_probability=.8))
        return instance

    def segment(self, start=.5, end=1.5, text='Test words', words=None):
        return SimpleNamespace(start=start, end=end, text=text, words=words)

    def test_json_words_identity_and_interval_connections(self):
        document = transcripts.import_transcript(self.run, self.source({'language': 'en', 'segments': [
            {'start': 1., 'end': 2., 'text': ' Check this ', 'words': [
                {'start': 1.1, 'end': 1.4, 'word': 'Check', 'probability': .7},
                {'start': 1.5, 'end': 1.9, 'word': 'this', 'probability': .8}]},
            {'start': 2.5, 'end': 3., 'text': 'Next'}]}))
        self.assertEqual(document['audio_sha256'], self.metadata['excerpt_sha256'])
        self.assertEqual(document['timeline'], 'excerpt')
        self.assertTrue(document['draft'])
        self.assertEqual(document['segments'][0]['text'], 'Check this')
        self.assertEqual(transcripts.load(self.run), document)
        self.assertEqual([s['text'] for s in transcripts.for_interval(document, 1.8, 2.5)], ['Check this'])
        self.assertEqual(transcripts.for_interval(document, 2., 2.5), [])
        self.assertEqual(transcripts.for_interval(None, 0., 1.), [])
        self.assert_records_unchanged()

    def test_original_timeline_clips_cues_and_words(self):
        document = transcripts.import_transcript(self.run, self.source({'segments': [
            {'start': 9., 'end': 11., 'text': 'Partly outside', 'words': [
                {'start': 9.1, 'end': 9.7, 'word': 'Outside'},
                {'start': 10.1, 'end': 10.8, 'word': 'Inside'}]},
            {'start': 13.5, 'end': 14.5, 'text': 'End clipped'},
            {'start': 15., 'end': 16., 'text': 'Not in this excerpt'}]}), timeline='original')
        self.assertEqual(len(document['segments']), 2)
        first, last = document['segments']
        self.assertEqual((first['start'], first['end']), (0., 1.))
        self.assertTrue(first['clipped'])
        self.assertEqual(len(first['words']), 1)
        self.assertAlmostEqual(first['words'][0]['start'], .1)
        self.assertEqual((last['start'], last['end']), (3.5, 4.))
        self.assertTrue(last['clipped'])
        self.assertEqual(document['origin']['input_timeline'], 'original')

    def test_original_timeline_with_no_overlap_preserves_previous(self):
        self.initial()
        previous = (self.run / 'transcript.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'No transcript segments overlap'):
            transcripts.import_transcript(self.run, self.source({'segments': [
                {'start': 100., 'end': 101., 'text': 'Elsewhere'}]}), timeline='original')
        self.assertEqual((self.run / 'transcript.json').read_bytes(), previous)

    def test_bad_segment_times_preserve_previous(self):
        self.initial()
        previous = (self.run / 'transcript.json').read_bytes()
        for start, end in [(float('nan'), 2), (1, float('inf')), (-1, 1), (2, 2),
                           (2, 1), (0, 4.1), (False, 1), ('bad', 1)]:
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                transcripts.import_transcript(self.run, self.source({'segments': [
                    {'start': start, 'end': end, 'text': 'Invalid'}]}))
            self.assertEqual((self.run / 'transcript.json').read_bytes(), previous)
        self.assert_records_unchanged()

    def test_word_outside_segment_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'outside its segment'):
            transcripts.import_transcript(self.run, self.source({'segments': [
                {'start': 1., 'end': 2., 'text': 'Bad word', 'words': [
                    {'start': .5, 'end': 1.5, 'word': 'Bad'}]}]}))
        self.assertFalse((self.run / 'transcript.json').exists())

    def test_word_probability_must_be_finite_and_bounded(self):
        for probability in (float('nan'), -1, 1.1):
            with self.subTest(probability=probability), self.assertRaises(ValueError):
                transcripts.import_transcript(self.run, self.source({'segments': [
                    {'start': 1., 'end': 2., 'text': 'Word', 'words': [
                        {'start': 1., 'end': 1.5, 'word': 'Word', 'probability': probability}]}]}))

    def test_zero_duration_word_keeps_punctuation(self):
        document = transcripts.import_transcript(self.run, self.source({'segments': [
            {'start': 1., 'end': 2., 'text': 'Word.', 'words': [
                {'start': 1., 'end': 1.5, 'word': 'Word'},
                {'start': 1.5, 'end': 1.5, 'word': '.'}]}]}))
        self.assertEqual(document['segments'][0]['words'][1]['word'], '.')

    def test_srt_multiline_text_and_entities(self):
        path = self.source('1\n00:00:01,100 --> 00:00:02,200\n<i>Check</i> &amp;\nlisten\n', '.srt')
        document = transcripts.import_transcript(self.run, path)
        self.assertEqual(document['segments'], [{'start': 1.1, 'end': 2.2, 'text': 'Check & listen'}])

    def test_vtt_identifiers_settings_and_notes(self):
        path = self.source('WEBVTT\nKind: captions\n\nNOTE artificial example\nignored\n\ncue-name\n00:01.000 --> 00:02.500 align:start\n<v Voice>Check the audio</v>\n', '.vtt')
        document = transcripts.import_transcript(self.run, path)
        self.assertEqual(document['segments'], [{'start': 1., 'end': 2.5, 'text': 'Check the audio'}])

    def test_invalid_caption_and_unsupported_file(self):
        for content, suffix in [('Plain text', '.srt'), ('00:00:02,000 --> 00:00:01,000\nReversed', '.srt'),
                                ('00:00:01.000 --> 00:00:02.000\nNo header', '.vtt'), ('Text', '.txt')]:
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                transcripts.import_transcript(self.run, self.source(content, suffix))

    def test_native_import_cannot_belong_to_other_audio(self):
        document = self.initial()
        document['audio_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'different audio'):
            transcripts.import_transcript(self.run, self.source(document))

    def test_native_import_cannot_reinterpret_excerpt_as_original(self):
        document = self.initial()
        with self.assertRaisesRegex(ValueError, 'already uses excerpt'):
            transcripts.import_transcript(self.run, self.source(document), timeline='original')

    def test_load_rejects_changed_audio_even_with_updated_run_checksum(self):
        self.initial()
        path = self.run / 'excerpt.wav'
        data = bytearray(path.read_bytes())
        data[-1] = 1
        path.write_bytes(data)
        self.metadata['excerpt_sha256'] = transcripts._digest(path)
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, 'different audio'):
            transcripts.load(self.run)

    def test_load_rejects_different_source_offset(self):
        self.initial()
        self.metadata['source_offset'] = 20.
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, 'timing differs'):
            transcripts.load(self.run)

    def test_load_missing_and_invalid_versions(self):
        self.assertIsNone(transcripts.load(self.run))
        document = self.initial()
        document['version'] = 22
        (self.run / 'transcript.json').write_text(json.dumps(document), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            transcripts.load(self.run)

    def test_replacement_keeps_exact_previous_transcript_backup(self):
        self.initial()
        previous = (self.run / 'transcript.json').read_bytes()
        transcripts.import_transcript(self.run, self.source({'segments': [
            {'start': 2., 'end': 3., 'text': 'New words'}]}))
        backups = list((self.run / 'history').glob('transcript_*.json'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), previous)
        self.assert_records_unchanged()

    def test_atomic_replacement_failure_preserves_prior_file(self):
        self.initial()
        previous = (self.run / 'transcript.json').read_bytes()
        with patch.object(transcripts.os, 'replace', side_effect=OSError('Busy file')):
            with self.assertRaisesRegex(OSError, 'Busy file'):
                transcripts.import_transcript(self.run, self.source({'segments': [
                    {'start': 2., 'end': 3., 'text': 'Replacement'}]}))
        self.assertEqual((self.run / 'transcript.json').read_bytes(), previous)
        self.assertEqual(list(self.run.glob('transcript_*.tmp')), [])

    def test_generation_saves_timed_words_and_requests_local_cpu_engine(self):
        word = SimpleNamespace(start=.6, end=1., word='Check', probability=.8)
        instance = self.engine([self.segment(words=[word])])
        progress = []
        cache = self.root / 'models'
        with patch.object(transcripts, '_load_model', return_value=(instance, 'a' * 40)) as loader:
            document = transcripts.generate(self.run, model='tiny', model_directory=cache,
                progress=lambda fraction, message: progress.append((fraction, message)))
        loader.assert_called_once_with('tiny', cache, False)
        self.assertEqual(instance.transcribe.call_args.kwargs['word_timestamps'], True)
        self.assertEqual(instance.transcribe.call_args.kwargs['vad_filter'], True)
        self.assertEqual(document['origin']['device'], 'cpu')
        self.assertEqual(document['origin']['model_revision'], 'a' * 40)
        self.assertEqual(document['segments'][0]['words'][0]['start'], .6)
        self.assertEqual(progress[-1][0], 1.)
        self.assertEqual(transcripts.load(self.run), document)
        self.assert_records_unchanged()

    def test_generator_failure_never_replaces_previous_transcript(self):
        self.initial()
        previous = (self.run / 'transcript.json').read_bytes()
        def broken():
            yield self.segment()
            raise RuntimeError('Decoder stopped')
        instance = self.engine([])
        instance.transcribe.return_value = (broken(), SimpleNamespace(language='en'))
        with patch.object(transcripts, '_load_model', return_value=(instance, None)):
            with self.assertRaisesRegex(RuntimeError, 'Decoder stopped'):
                transcripts.generate(self.run)
        self.assertEqual((self.run / 'transcript.json').read_bytes(), previous)

    def test_cancel_before_loading_and_during_generation_preserves_previous(self):
        self.initial()
        previous = (self.run / 'transcript.json').read_bytes()
        event = threading.Event()
        event.set()
        with patch.object(transcripts, '_load_model') as loader:
            with self.assertRaises(transcripts.TranscriptCancelled):
                transcripts.generate(self.run, cancelled=event.is_set)
            loader.assert_not_called()
        event.clear()
        def stopped():
            yield self.segment()
            event.set()
            yield self.segment(2., 3., 'Unfinished')
        instance = self.engine([])
        instance.transcribe.return_value = (stopped(), SimpleNamespace(language='en'))
        with patch.object(transcripts, '_load_model', return_value=(instance, None)):
            with self.assertRaises(transcripts.TranscriptCancelled):
                transcripts.generate(self.run, cancelled=event.is_set)
        self.assertEqual((self.run / 'transcript.json').read_bytes(), previous)

    def test_concurrent_transcript_change_is_not_overwritten(self):
        self.initial()
        replacement = None
        def changed():
            nonlocal replacement
            transcript = transcripts.load(self.run)
            transcript['segments'][0]['text'] = 'Saved by another reviewer'
            replacement = json.dumps(transcript).encode('utf-8')
            (self.run / 'transcript.json').write_bytes(replacement)
            yield self.segment()
        instance = self.engine([])
        instance.transcribe.return_value = (changed(), SimpleNamespace(language='en'))
        with patch.object(transcripts, '_load_model', return_value=(instance, None)):
            with self.assertRaisesRegex(ValueError, 'changed while processing'):
                transcripts.generate(self.run)
        self.assertEqual((self.run / 'transcript.json').read_bytes(), replacement)

    def test_audio_changes_during_generation_are_rejected(self):
        self.initial()
        previous = (self.run / 'transcript.json').read_bytes()
        def changed():
            path = self.run / 'excerpt.wav'
            path.write_bytes(path.read_bytes()[:-2] + b'\x01\0')
            yield self.segment()
        instance = self.engine([])
        instance.transcribe.return_value = (changed(), SimpleNamespace(language='en'))
        with patch.object(transcripts, '_load_model', return_value=(instance, None)):
            with self.assertRaisesRegex(ValueError, 'audio differs'):
                transcripts.generate(self.run)
        self.assertEqual((self.run / 'transcript.json').read_bytes(), previous)

    def test_decoder_rounding_at_excerpt_end_is_clipped(self):
        word = SimpleNamespace(start=3.6, end=4.01, word='End', probability=.8)
        instance = self.engine([self.segment(3.5, 4.01, 'End', [word])])
        with patch.object(transcripts, '_load_model', return_value=(instance, None)):
            document = transcripts.generate(self.run)
        self.assertEqual(document['segments'][0]['end'], 4.)
        self.assertEqual(document['segments'][0]['words'][0]['end'], 4.)

    def test_empty_generation_is_a_valid_draft_without_annotations(self):
        instance = self.engine([])
        with patch.object(transcripts, '_load_model', return_value=(instance, None)):
            document = transcripts.generate(self.run)
        self.assertEqual(document['segments'], [])
        self.assertTrue(document['draft'])
        self.assert_records_unchanged()

    def test_generation_supplies_resampled_mono_array_instead_of_file_decoder(self):
        rate = 48000
        signal = np.sin(2 * np.pi * 200 * np.arange(rate * 4) / rate)
        stereo = np.column_stack((.4 * signal, .2 * signal))
        with wave.open(str(self.run / 'excerpt.wav'), 'wb') as audio:
            audio.setparams((2, 2, rate, 0, 'NONE', 'not compressed'))
            audio.writeframes((stereo * 32767).astype('<i2').tobytes())
        self.metadata['excerpt_sha256'] = transcripts._digest(self.run / 'excerpt.wav')
        self.write_metadata()
        instance = self.engine([])
        with patch.object(transcripts, '_load_model', return_value=(instance, None)):
            transcripts.generate(self.run)
        supplied = instance.transcribe.call_args.args[0]
        self.assertIsInstance(supplied, np.ndarray)
        self.assertEqual(supplied.shape, (64000,))
        self.assertEqual(supplied.dtype, np.dtype('float32'))
        self.assertTrue(supplied.flags.c_contiguous)
        self.assertGreater(np.max(np.abs(supplied)), .29)
        self.assertLess(np.max(np.abs(supplied)), .31)
        frequency = np.fft.rfftfreq(len(supplied), 1 / 16000)[np.argmax(np.abs(np.fft.rfft(supplied)))]
        self.assertAlmostEqual(frequency, 200., places=2)

    def test_cached_model_never_fetches_missing_tokenizer(self):
        local = self.root / 'cached_model'
        local.mkdir()
        for name in ('model.bin', 'config.json'):
            (local / name).write_bytes(b'fixture')
        package, utils = ModuleType('faster_whisper'), ModuleType('faster_whisper.utils')
        package.WhisperModel = Mock()
        utils.download_model = Mock(return_value=str(local))
        with patch.dict(sys.modules, {'faster_whisper': package, 'faster_whisper.utils': utils}):
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                transcripts._load_model('tiny', self.root / 'cache', False)
        self.assertEqual(utils.download_model.call_args.kwargs['local_files_only'], True)
        self.assertEqual(utils.download_model.call_args.kwargs['use_auth_token'], False)
        package.WhisperModel.assert_not_called()

    def test_complete_local_model_uses_cpu_and_no_network(self):
        local = self.root / 'local_model'
        local.mkdir()
        for name in ('model.bin', 'config.json', 'tokenizer.json'):
            (local / name).write_bytes(b'fixture')
        package, utils = ModuleType('faster_whisper'), ModuleType('faster_whisper.utils')
        package.WhisperModel = Mock(return_value='engine')
        utils.download_model = Mock()
        with patch.dict(sys.modules, {'faster_whisper': package, 'faster_whisper.utils': utils}):
            engine, revision = transcripts._load_model(str(local), None, False)
        self.assertEqual(engine, 'engine')
        self.assertIsNone(revision)
        self.assertEqual(package.WhisperModel.call_args.kwargs['device'], 'cpu')
        self.assertEqual(package.WhisperModel.call_args.kwargs['compute_type'], 'int8')
        self.assertEqual(package.WhisperModel.call_args.kwargs['local_files_only'], True)
        utils.download_model.assert_not_called()


if __name__ == '__main__':
    unittest.main()

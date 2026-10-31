import csv
import json
import tempfile
import unittest
import wave
from pathlib import Path
import numpy as np
import core

class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root/'synthetic.wav'
        self.rate=16000
        t=np.arange(self.rate*6)/self.rate
        self.samples=(np.sin(2*np.pi*200*t)*10000).astype('<i2')
        with wave.open(str(self.source),'wb') as w:
            w.setparams((1,2,self.rate,0,'NONE','not compressed'));w.writeframes(self.samples.tobytes())
        self.run=core.prepare(self.source,self.root/'runs',offset=2,length=2)
    def tearDown(self):self.temp.cleanup()
    def label(self):
        rows=[dict(start=0.,end=.25,speaker_speech='',valence='',arousal=''),
              dict(start=.25,end=1.25,speaker_speech='FAN-CDS',valence='+1',arousal='-1'),
              dict(start=1.25,end=2.,speaker_speech='',valence='',arousal='')]
        core.write_grid(self.run/'annotations.TextGrid',2,rows)
        return rows
    def test_approval_export_provenance_and_pcm(self):
        self.label()
        with self.assertRaises(ValueError):core.export(self.run)
        core.approve(self.run,1,'rater_01')
        dest=core.export(self.run)
        with (dest/'manifest.csv').open(encoding='utf-8-sig') as f:
            manifest=list(csv.DictReader(f))
        self.assertEqual(len(manifest),1)
        self.assertEqual(float(manifest[0]['source_start']),2.25)
        clip=dest/manifest[0]['clip_path']
        with wave.open(str(clip),'rb') as w:
            self.assertEqual(w.readframes(w.getnframes()),self.samples[36000:52000].tobytes())
        with (dest/'coverage.csv').open(encoding='utf-8-sig') as f:
            coverage=list(csv.DictReader(f))
        self.assertEqual(sum(x['target_16']=='True' for x in coverage),16)
        self.assertEqual(sum(int(x['count']) for x in coverage),1)
        self.assertTrue((dest/'excerpt.wav').exists())
    def test_changed_label_or_boundary_invalidates_approval(self):
        rows=self.label();core.approve(self.run,1,'rater')
        rows[1]['valence']='-1';core.write_grid(self.run/'annotations.TextGrid',2,rows)
        with self.assertRaises(ValueError):core.export(self.run)
        core.approve(self.run,1,'rater')
        rows[1]['end']=1.3;rows[2]['start']=1.3
        core.write_grid(self.run/'annotations.TextGrid',2,rows)
        with self.assertRaises(ValueError):core.export(self.run)
    def test_unknown_labels_cannot_be_approved(self):
        rows=self.label();rows[1]['arousal']='?';core.write_grid(self.run/'annotations.TextGrid',2,rows)
        with self.assertRaises(ValueError):core.approve(self.run,1,'rater')
    def test_tier_boundary_mismatch_rejected(self):
        self.label();p=self.run/'annotations.TextGrid'
        text=p.read_text();text=text.replace('xmax = 1.250000000000','xmax = 1.240000000000',1)
        p.write_text(text)
        with self.assertRaises((ValueError,core.parselmouth.PraatError)):core.load_run(self.run)
    def test_audio_mutation_rejected(self):
        self.label();p=self.run/'excerpt.wav';b=bytearray(p.read_bytes());b[-10]^=1;p.write_bytes(b)
        with self.assertRaises(ValueError):core.load_run(self.run)
    def test_its_processing_recordings_exclude_summary_bars(self):
        p=self.root/'synthetic.its'
        p.write_text('<Root><ProcessingUnit><Recording startTime="PT0S" endTime="PT3S"><Conversation><Segment startTime="PT2.2S" endTime="PT2.7S" spkr="FAN"/></Conversation></Recording><Recording startTime="PT3S" endTime="PT6S"><Pause><Segment startTime="PT3.1S" endTime="PT3.5S" spkr="MAN"/></Pause></Recording></ProcessingUnit><Bar><Recording startTime="PT0S" endTime="PT6S"/></Bar></Root>')
        regions=core.its_candidates(p,2,2)
        self.assertEqual(len(regions),2)
        self.assertEqual(regions[0][2],'FAN-?')
        self.assertAlmostEqual(regions[1][0],1.1)
    def test_pitch_measurement_on_known_tone(self):
        self.label();f=core.features(self.run/'excerpt.wav',core.read_grid(self.run/'annotations.TextGrid'))
        self.assertAlmostEqual(f[0]['f0_mean_hz'],200,delta=3)
    def test_no_candidates_yields_valid_silence_grid(self):
        source=self.root/'silence.wav'
        with wave.open(str(source),'wb') as w:
            w.setparams((1,2,16000,0,'NONE','not compressed'));w.writeframes(bytes(32000))
        run=core.prepare(source,self.root/'runs')
        _,rows,_=core.load_run(run)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['speaker_speech'],'')

if __name__=='__main__':unittest.main()

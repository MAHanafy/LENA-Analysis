import csv
import json
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np
from parselmouth.praat import call
import automation
import batch
import core

class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.source=self.root/'NH'/'synthetic.wav';self.source.parent.mkdir()
        self.rate=16000
        x=np.zeros(self.rate*6)
        for a,b in [(1.,1.8),(2.4,3.2)]:
            t=np.arange(round((b-a)*self.rate))/self.rate
            x[round(a*self.rate):round(b*self.rate)]=.3*np.sin(2*np.pi*200*t)
        with wave.open(str(self.source),'wb') as w:
            w.setparams((1,2,self.rate,0,'NONE','not compressed'));w.writeframes((x*32767).astype('<i2').tobytes())
    def tearDown(self):self.temp.cleanup()
    def its(self,body,kind='AICM'):
        p=self.source.with_suffix('.its')
        p.write_text(f'<Root><ProcessingUnit><Recording startTime="PT0S" endTime="PT6S"><Conversation type="{kind}">{body}</Conversation></Recording></ProcessingUnit><Bar><Recording startTime="PT0S" endTime="PT6S"/></Bar></Root>')
        return p
    def adult(self,speaker,a,b,code='NT'):
        attr='femaleAdultWordCnt' if speaker=='FAN' else 'maleAdultWordCnt'
        return f'<Segment spkr="{speaker}" startTime="PT{a}S" endTime="PT{b}S" {attr}="3" conversationInfo="|RC|1|1|1|AICM|{code}|FI|"/>'
    def child(self,a,b,code='NT'):
        return f'<Segment spkr="CHN" childUttCnt="1" startUtt1="PT{a}S" endUtt1="PT{b}S" conversationInfo="|RC|1|1|1|AICM|{code}|FI|"/>'
    def make_run(self):return core.prepare(self.source,self.root/'runs',length=6)

class SuggestionTests(Fixture):
    def test_cds_metadata_and_provenance(self):
        p=self.its(self.adult('FAN',0,1)+self.child(1.2,2,'TIFR'))
        s=automation.read_its(p);pred=automation.interaction_suggestions(s)[s[0]['id']]
        self.assertEqual(pred['label'],'FAN-CDS');self.assertEqual(pred['reason'],'LENA_target')
        self.assertAlmostEqual(pred['evidence'][0]['gap_seconds'],.2)
    def test_ads_adult_turns(self):
        p=self.its(self.adult('FAN',0,1)+self.adult('MAN',1.1,2))
        s=automation.read_its(p);pred=automation.interaction_suggestions(s)
        self.assertEqual([pred[x['id']]['label'] for x in s],['FAN-ADS','MAN-ADS'])
    def test_same_class_turns_do_not_prove_ads(self):
        p=self.its(self.adult('FAN',0,1)+self.adult('FAN',1.1,2))
        s=automation.read_its(p);pred=automation.interaction_suggestions(s)
        self.assertTrue(all(pred[x['id']]['label']=='FAN-?' for x in s))
    def test_conflicting_cds_ads_remains_unknown(self):
        p=self.its(self.adult('MAN',0,.8)+self.adult('FAN',1,2)+self.child(2.1,2.5))
        s=automation.read_its(p);pred=automation.interaction_suggestions(s)[s[1]['id']]
        self.assertEqual(pred['label'],'FAN-?');self.assertIn('conflicting',pred['reason'])
    def test_other_conversation_types_and_optional_matlab_scope(self):
        p=self.its(self.adult('FAN',0,1)+self.child(1.2,2),kind='AICF')
        s=automation.read_its(p)
        self.assertEqual(automation.interaction_suggestions(s)[s[0]['id']]['label'],'FAN-CDS')
        self.assertEqual(automation.interaction_suggestions(s,aicm_only=True)[s[0]['id']]['label'],'FAN-?')
    def test_gap_limit_no_forced_label(self):
        p=self.its(self.adult('FAN',0,.2)+self.child(5.5,6))
        s=automation.read_its(p)
        self.assertEqual(automation.interaction_suggestions(s)[s[0]['id']]['label'],'FAN-?')
    def test_pause_refinement_and_original_time_coordinates(self):
        p=self.its(self.adult('FAN',.8,3.5)+self.child(3.6,4))
        run=core.prepare(self.source,self.root/'runs',offset=.5,length=4,its=p)
        meta,rows,_=core.load_run(run)
        adult=[r for r in rows if r['speaker_speech']]
        self.assertEqual(len(adult),2)
        self.assertTrue(all(r['speaker_speech']=='FAN-CDS' for r in adult))
        self.assertTrue(1.7<adult[0]['end']+.5<2.0)
        self.assertEqual(meta['source_offset'],.5)
        self.assertTrue(all(r['valence']=='?' for r in adult))
    def test_overlap_is_flagged_and_retained(self):
        p=self.its(self.adult('FAN',1,2.5)+self.adult('MAN',2,3))
        run=core.prepare(self.source,self.root/'runs',length=4,its=p,refine=False)
        notes=json.loads((run/'suggestions.json').read_text())
        overlap=next(n for n in notes if 'overlapping_adult_segments' in n['flags'])
        self.assertEqual(overlap['proposed_speaker_speech'],'?')
    def test_suggestion_does_not_follow_changed_boundaries(self):
        row=dict(start=1.,end=2.)
        self.assertEqual(automation.evidence_for(row,[dict(start=1.,end=1.9,reason='old')])['evidence'],[])
    def test_quality_clipping_flag(self):
        p=self.root/'clipped.wav'
        with wave.open(str(p),'wb') as w:
            w.setparams((1,2,self.rate,0,'NONE','not compressed'));w.writeframes(np.full(self.rate,32767,dtype='<i2').tobytes())
        q=automation.quality_metrics(p,[dict(start=0,end=1,speaker_speech='FAN-CDS',valence='?',arousal='?')])
        self.assertIn('possible_clipping',q[0]['flags'])

class ReviewTests(Fixture):
    def labeled_run(self):
        run=self.make_run()
        rows=[dict(start=0.,end=.5,speaker_speech='',valence='',arousal=''),
              dict(start=.5,end=2.,speaker_speech='FAN-CDS',valence='+1',arousal='-1'),
              dict(start=2.,end=6.,speaker_speech='',valence='',arousal='')]
        core.write_grid(run/'annotations.TextGrid',6,rows)
        return run
    def test_shared_boundary_edit_and_approval_invalidation(self):
        run=self.labeled_run();core.approve(run,1,'reviewer')
        core.set_boundaries(run,1,.6,2.1,core.digest(run/'annotations.TextGrid'))
        _,rows,reviews=core.load_run(run)
        self.assertEqual(rows[0]['end'],.6);self.assertEqual(rows[2]['start'],2.1)
        self.assertNotIn(core.signature(rows[1]),reviews)
        self.assertTrue(list((run/'history').glob('*.TextGrid')))
    def test_external_edit_not_overwritten(self):
        run=self.labeled_run();old=core.digest(run/'annotations.TextGrid');_,rows,_=core.load_run(run)
        rows[1]['valence']='-1';core.write_grid(run/'annotations.TextGrid',6,rows)
        with self.assertRaises(ValueError):core.save_annotations(run,rows,old)
        self.assertEqual(core.load_run(run)[1][1]['valence'],'-1')
    def test_sync_preserves_conflicts_as_unknown(self):
        run=self.labeled_run();grid=core.parselmouth.read(str(run/'annotations.TextGrid'))
        call(grid,'Insert boundary',2,1.)
        call(grid,'Set interval text',2,3,'-1')
        call(grid,'Save as text file',str(run/'annotations.TextGrid'))
        with self.assertRaises(ValueError):core.load_run(run)
        core.synchronize_tiers(run)
        self.assertEqual(core.load_run(run)[1][1]['valence'],'?')
    def test_crossing_neighbor_rejected(self):
        run=self.labeled_run()
        with self.assertRaises(ValueError):core.set_boundaries(run,1,0,2)
    def test_praat_script_selects_annotated_region(self):
        run=self.labeled_run();text=core.review_script(run,.5,2).read_text()
        self.assertIn('View & Edit',text);self.assertIn('Select: 0.500000000000, 2.000000000000',text)
        self.assertIn('ANVUREL_',text)
    def test_existing_praat_session_is_not_taken_over(self):
        run=self.labeled_run()
        with patch.object(core,'running_praat_pids',return_value=[1234]),patch.object(core.subprocess,'Popen') as launch:
            with self.assertRaises(ValueError):core.open_praat(self.source,run)
            launch.assert_not_called()
    def test_multiple_praat_instances_block_ambiguous_messages(self):
        with patch.object(core,'running_praat_pids',return_value=[1234,5678]):
            with self.assertRaises(ValueError):core.require_single_praat()

class BatchTests(Fixture):
    def test_scan_pair_group_and_output_exclusions(self):
        self.its(self.adult('FAN',1,2))
        generated=self.source.parent/'outputs';generated.mkdir();(generated/'fake.wav').write_bytes(b'bad')
        result=batch.scan(self.source.parent)
        self.assertEqual(len(result),1);self.assertEqual(result[0]['group'],'NH');self.assertTrue(result[0]['its'])
    def test_invalid_wav_is_reported(self):
        (self.source.parent/'broken.wav').write_bytes(b'bad')
        path=batch.create(self.source.parent,self.root/'batches')
        self.assertIn('blocked',[j['status'] for j in batch.load(path)['jobs']])
    def test_cancel_resume_never_replaces_completed_run(self):
        path=batch.create(self.source.parent,self.root/'batches',chunk=2,mode='all')
        cancelled=[False]
        def progress(i,n,j):
            if j['status']=='done':cancelled[0]=True
        first=batch.run(path,progress=progress,cancelled=lambda:cancelled[0])
        self.assertEqual([j['status'] for j in first['jobs']],['done','pending','pending'])
        old_run=first['jobs'][0]['run']
        grid=path/old_run/'annotations.TextGrid';old_hash=core.digest(grid)
        second=batch.run(path)
        self.assertEqual([j['status'] for j in second['jobs']],['done']*3)
        self.assertEqual(second['jobs'][0]['run'],old_run);self.assertEqual(core.digest(grid),old_hash)
    def test_source_changes_are_not_silently_reused(self):
        path=batch.create(self.source.parent,self.root/'batches')
        with self.source.open('ab') as f:f.write(b'changed')
        data=batch.run(path)
        self.assertEqual(data['jobs'][0]['status'],'failed');self.assertIn('changed',data['jobs'][0]['error'])
    def test_os_lock_blocks_second_worker(self):
        path=batch.create(self.source.parent,self.root/'batches')
        with batch.queue_lock(path):
            with self.assertRaises(ValueError):
                with batch.queue_lock(path):pass

if __name__=='__main__':unittest.main()

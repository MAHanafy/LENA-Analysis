"""Exercise native controls without modifying real annotations or opening Praat."""
import unittest
from unittest.mock import patch
import tkinter as tk

import app
import core
from test_automation import Fixture

class DesktopTests(Fixture):
    def setUp(self):
        super().setUp()
        self.run=self.make_run()
        self.tk=tk.Tk();self.tk.withdraw()
        self.application=app.Application(self.tk)
        self.errors=[]
        self.tk.report_callback_exception=lambda *e:self.errors.append(e)
        self.application.load_run(self.run);self.tk.update()
    def tearDown(self):
        try:
            self.application.dirty=False
            self.application.close()
        finally:
            try:self.tk.destroy()
            except tk.TclError:pass
            super().tearDown()
    def test_save_approve_next_and_filter(self):
        a=self.application
        a.vars['speaker'].set('FAN-CDS');a.vars['valence'].set('+1');a.vars['arousal'].set('-1');a.vars['reviewer'].set('test_rater')
        with patch.object(app.messagebox,'showerror',side_effect=AssertionError):a.approve_next()
        self.tk.update()
        _,rows,reviews=core.load_run(self.run)
        self.assertEqual(len(reviews),1)
        self.assertEqual(len(a.tree.get_children()),1)
        self.assertFalse(a.dirty);self.assertEqual(self.errors,[])
    def test_external_change_does_not_discard_form(self):
        a=self.application;a.vars['valence'].set('+1')
        _,rows,_=core.load_run(self.run);i=a.selected_index();rows[i]['arousal']='-1'
        core.write_grid(self.run/'annotations.TextGrid',a.meta['duration'],rows)
        a.watch();self.tk.update()
        self.assertEqual(a.vars['valence'].get(),'+1');self.assertTrue(a.dirty)
        self.assertIn('retained',a.status.get())
    def test_mouse_selection_retains_dirty_labels(self):
        a=self.application;old=a.selected_index();a.vars['valence'].set('-1')
        other=next(i for i in a.tree.get_children() if int(i)!=old)
        a.tree.selection_set(other);self.tk.update()
        self.assertEqual(a.selected_index(),old);self.assertEqual(a.vars['valence'].get(),'-1')
    def test_batch_table_handles_queued_jobs(self):
        a=self.application
        a.fill_batch([dict(source=str(self.source),group='NH',offset=0,length=300,status='pending',run=None,error='')])
        self.assertEqual(len(a.batch_tree.get_children()),1)
        self.assertEqual(self.errors,[])
    def test_boundary_apply_also_preserves_form_labels(self):
        a=self.application;idx=a.selected_index()
        a.vars['speaker'].set('FAN-CDS');a.vars['valence'].set('+1');a.vars['arousal'].set('-1')
        a.vars['start'].set(str(a.rows[idx]['start']+.01))
        with patch.object(app.messagebox,'showerror',side_effect=AssertionError):a.boundaries()
        self.tk.update()
        row=core.load_run(self.run)[1][idx]
        self.assertEqual(row['speaker_speech'],'FAN-CDS');self.assertEqual(row['valence'],'+1')
        self.assertFalse(a.dirty)

if __name__=='__main__':unittest.main()

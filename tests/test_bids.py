from pathlib import Path
import csv, importlib.util, os, subprocess, tempfile, unittest
REPO=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('demo',REPO/'examples/demo_bids.py');demo=importlib.util.module_from_spec(spec);spec.loader.exec_module(demo)
class OperationsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.base=Path(self.tmp.name);self.raw,self.nda,self.dest=demo.make_fixtures(self.base)
    def run_script(self,name,*args,**kwargs):
        return subprocess.run(['bash',str(REPO/'scripts'/name),*map(str,args)],capture_output=True,text=True,check=True,**kwargs)
    def test_counts_dwi_once_per_session(self):
        out=self.run_script('count_rawdata_scans.sh',self.raw).stdout
        self.assertIn('Subjects (sub-* directories): 2',out)
        self.assertIn('Expected eddy datasets (one per session with DWI): 3',out)
    def test_nda_preserves_session_and_reports_absence(self):
        out=self.base/'audit';self.run_script('compare_rawdata_nda.sh',self.raw,self.nda,out)
        with (out/'missing_sessions_from_nda_csv.csv').open() as f: rows=list(csv.DictReader(f))
        self.assertTrue(any(r['subject']=='sub-demo01' and r['session']=='ses-2' and r['status']=='not_listed' for r in rows))
if __name__=='__main__': unittest.main()

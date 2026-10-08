from pathlib import Path
import csv, importlib.util, subprocess, tempfile, unittest
REPO=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('demo',REPO/'examples/demo_qc.py');demo=importlib.util.module_from_spec(spec);spec.loader.exec_module(demo)
class QCTests(unittest.TestCase):
    def test_paired_metrics_preserve_subject_session_and_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);a,b=demo.make_fixtures(base);out=base/'report'
            subprocess.run(['python3',str(REPO/'scripts/compare_eddy_qc_methods.py'),'--with-root',str(a),'--without-root',str(b),'--output-dir',str(out)],check=True,capture_output=True)
            with (out/'eddy_qc_metrics_long.csv').open() as f: rows=list(csv.DictReader(f))
            self.assertEqual(len(rows),2);self.assertTrue(all(r['subject']=='sub-demo01' and r['session']=='ses-1' for r in rows))
            self.assertEqual(sorted(round(float(r['mean_abs_rms']),3) for r in rows),[.3,.5])
if __name__=='__main__':unittest.main()

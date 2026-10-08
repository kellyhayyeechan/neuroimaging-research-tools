from pathlib import Path
import csv, subprocess, tempfile, unittest
REPO=Path(__file__).resolve().parents[1]
class DesignTests(unittest.TestCase):
    def test_rows_groups_time_and_contrast_width(self):
        for interaction in [False,True]:
            with tempfile.TemporaryDirectory() as tmp:
                base=Path(tmp);out=base/'design'
                args=['python3',str(REPO/'scripts/build_swe_design.py'),'--covariates',str(REPO/'examples/covariates.csv'),'--scan-dir',str(base/'scans'),'--modality','FAt','FW','--out-dir',str(out)]
                if interaction:args.append('--include-sex-time-interaction')
                subprocess.run(args,check=True,capture_output=True)
                a=(out/'FAt/DesignMatrix.txt').read_text();b=(out/'FW/DesignMatrix.txt').read_text();self.assertEqual(a,b)
                rows=[list(map(float,l.split())) for l in a.splitlines()];self.assertEqual(len(rows),12);width=6 if interaction else 5
                self.assertTrue(all(len(r)==width for r in rows));self.assertAlmostEqual(rows[1][1],90/365.25)
                self.assertEqual((out/'FAt/Group.txt').read_text().splitlines()[:6],['1','1','1','2','2','2'])
                with (out/'FAt/Contrasts_reference.csv').open() as f:contrasts=list(csv.DictReader(f))
                self.assertTrue(all(len(r['vector'].split())==width for r in contrasts))
if __name__=='__main__':unittest.main()

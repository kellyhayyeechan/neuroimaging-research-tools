from pathlib import Path
import csv, importlib.util, json, tempfile, unittest
REPO=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('resolver',REPO/'scripts/resolve_dwi_readout.py');resolver=importlib.util.module_from_spec(spec);spec.loader.exec_module(resolver)
class ReadoutTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.base=Path(self.tmp.name);self.js=self.base/'sub-demo01_ses-1_dwi.json';self.csv=self.base/'metadata.csv';self.js.write_text('{"PhaseEncodingDirection":"j-"}')
    def rows(self,values):
        with self.csv.open('w',newline='') as f:
            w=csv.writer(f);w.writerow(['subject','session','file','sub_site','TotalReadoutTime','QC_exclusion']);w.writerows(values)
    def resolve(self): return resolver.resolve(self.csv,self.js,'sub-demo01','ses-1')
    def test_same_site_fallback_preserves_json(self):
        self.rows([['sub-demo01','ses-1',self.js.name,'siteA','',''],['sub-demo02','ses-1','other.json','siteA','0.045','']]);before=self.js.read_bytes()
        self.assertEqual(self.resolve()[:2],(0.045,'CSV_SUBSITE_INFERRED'));self.assertEqual(before,self.js.read_bytes())
    def test_json_precedes_scan_csv(self):
        self.js.write_text('{"PhaseEncodingDirection":"j-","TotalReadoutTime":0.06}')
        self.rows([['sub-demo01','ses-1',self.js.name,'siteA','0.06','']]);self.assertEqual(self.resolve()[:2],(0.06,'JSON'))
    def test_exact_scan_precedes_subsite(self):
        self.rows([['sub-demo01','ses-1',self.js.name,'siteA','0.05',''],['sub-demo02','ses-1','other.json','siteA','0.045','']]);self.assertEqual(self.resolve()[:2],(0.05,'CSV_EXACT_SCAN'))
    def test_conflicting_donors_fail(self):
        self.rows([['sub-demo01','ses-1',self.js.name,'siteA','',''],['sub-demo02','ses-1','other.json','siteA','0.045',''],['sub-demo03','ses-1','third.json','siteA','0.06','']])
        with self.assertRaisesRegex(ValueError,'Ambiguous readout'): self.resolve()
    def test_excluded_donors_do_not_supply_readout(self):
        self.rows([['sub-demo01','ses-1',self.js.name,'siteA','',''],['sub-demo02','ses-1','other.json','siteA','0.045','x']])
        with self.assertRaisesRegex(ValueError,'No valid donor'): self.resolve()
    def test_missing_direction_fails(self):
        self.js.write_text('{}');self.rows([])
        with self.assertRaisesRegex(ValueError,'PhaseEncodingDirection'):self.resolve()
if __name__=='__main__': unittest.main()

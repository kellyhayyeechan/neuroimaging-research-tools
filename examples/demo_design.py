"""Build a design from synthetic covariates and empty scan-path placeholders."""
from pathlib import Path
import csv, subprocess
BASE=Path(__file__).resolve().parent
REPO=BASE.parent
def make_scans(base):
    with (BASE/'covariates.csv').open() as f: subjects=[r['subject'] for r in csv.DictReader(f)]
    for ses in ['ses-1','ses-2','ses-3']:
        for metric in ['FAt','FW']:
            for sub in subjects:
                p=Path(base)/ses/metric/'skeleton'/f'{sub}_{metric}_to_target_skel.nii.gz';p.parent.mkdir(parents=True,exist_ok=True);p.touch()
def main():
    base=BASE/'generated';make_scans(base/'scans')
    subprocess.run(['python3',str(REPO/'scripts/build_swe_design.py'),'--covariates',str(BASE/'covariates.csv'),'--scan-dir',str(base/'scans'),'--modality','FAt','FW','--out-dir',str(base/'design')],check=True)
if __name__=='__main__':main()

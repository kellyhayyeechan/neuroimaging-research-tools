"""Create disposable synthetic fixtures and run the read-only audits.
The empty .nii.gz files are filename placeholders, not MRI data.
"""
from pathlib import Path
import csv, json, subprocess
BASE=Path(__file__).resolve().parent
REPO=BASE.parent
def make_fixtures(base):
    base=Path(base).resolve();raw=base/'rawdata'
    files=['sub-demo01/ses-1/anat/sub-demo01_ses-1_T1w.nii.gz','sub-demo01/ses-1/dwi/sub-demo01_ses-1_run-1_dwi.nii.gz','sub-demo01/ses-1/dwi/sub-demo01_ses-1_run-2_dwi.nii.gz','sub-demo01/ses-2/dwi/sub-demo01_ses-2_dwi.nii.gz','sub-demo02/ses-1/dwi/sub-demo02_ses-1_dwi.nii.gz']
    for name in files:
        p=raw/name;p.parent.mkdir(parents=True,exist_ok=True);p.touch()
    nda=base/'image03.csv'
    with nda.open('w',newline='') as f:
        w=csv.writer(f);w.writerow(['src_subject_id','image_file','scan_type','session_id','visit'])
        w.writerow(['sub-demo01',str(raw/files[1]),'diffusion','ses-1','Baseline'])
        w.writerow(['sub-demo02',str(raw/files[-1]),'diffusion','ses-1','Baseline'])
    source=base/'converted'/'synthetic-acquisition';source.mkdir(parents=True,exist_ok=True)
    for number,desc in [(12,'dMRI AP'),(24,'dMRI AP'),(30,'dMRI AP SBRef')]:
        (source/f'sub-example_dMRI_dir99_AP_{number}.json').write_text(json.dumps({'SeriesDescription':desc,'SeriesNumber':number}))
    dest=base/'Japan_1'/'IRCN'/'rawdata'/'sub-demo01'/'ses-1'/'dwi'/'sub-demo01_ses-1_acq-AP_dir-99_dwi.json'
    dest.parent.mkdir(parents=True,exist_ok=True)
    with (base/'missing.csv').open('w',newline='') as f:
        w=csv.writer(f);w.writerow(['BIDS_Root','Subject','Session','Expected_JSON_Full_Path']);w.writerow([str(dest.parents[3]),'sub-demo01','ses-1',str(dest)])
    with (base/'mapping.csv').open('w',newline='') as f:
        w=csv.writer(f);w.writerow(['CPID','session','folder']);w.writerow(['demo01','1','synthetic-acquisition'])
    return raw,nda,dest
def main():
    base=BASE/'generated';raw,nda,_=make_fixtures(base)
    subprocess.run(['bash',str(REPO/'scripts/count_rawdata_scans.sh'),str(raw)],check=True)
    subprocess.run(['bash',str(REPO/'scripts/compare_rawdata_nda.sh'),str(raw),str(nda),str(base/'nda_audit')],check=True)
    print('Synthetic audit output:',base)
if __name__=='__main__': main()

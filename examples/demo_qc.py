"""Generate synthetic Eddy motion tables and compare them; no imaging data."""
from pathlib import Path
import subprocess
BASE=Path(__file__).resolve().parent
REPO=BASE.parent
def make_fixtures(base):
    base=Path(base)
    for method,values in [('with',[(.2,.1),(.3,.1),(.4,.2)]),('without',[(.4,.2),(.5,.2),(.6,.3)])]:
        p=base/method/'sub-demo01'/'ses-1'/'dwi'/'sub-demo01_ses-1_dwi.eddy_movement_rms';p.parent.mkdir(parents=True,exist_ok=True);p.write_text('\n'.join(f'{a} {b}' for a,b in values)+'\n')
    return base/'with',base/'without'
def main():
    base=BASE/'generated';a,b=make_fixtures(base)
    subprocess.run(['python3',str(REPO/'scripts/compare_eddy_qc_methods.py'),'--with-root',str(a),'--without-root',str(b),'--output-dir',str(base/'report')],check=True)
    print('Synthetic output:',base/'report')
if __name__=='__main__':main()

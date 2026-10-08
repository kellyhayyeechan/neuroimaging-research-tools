# Neuroimaging Research Tools

**Kelly Chan · Python, R, and Bash · Imaging data quality, research automation, and longitudinal analysis**

I work in clinical psychiatry research and build practical tools for organizing neuroimaging data, reviewing quality-control outputs, and preparing longitudinal analyses. This repository presents a focused selection of workflows I have developed and iterated with AI-assisted coding support.

My current examples come primarily from structural and diffusion MRI research. The underlying skills—BIDS inventories, motion/QC review, metadata provenance, and repeated-measures analysis—are relevant to broader medical-imaging work. This collection documents those skills; it does not claim a completed functional MRI or machine-learning pipeline.

## Start with these examples

These demonstrations run with Python 3.10+ and Bash on GNU/Linux. They use invented records; generated empty NIfTI files test filename discovery only and are not MRI images.

```bash
python3 examples/demo_bids.py
python3 examples/demo_qc.py
python3 examples/demo_design.py
python3 -m unittest discover -s tests -v
```

| Tool | Problem it addresses | Evidence to inspect |
| --- | --- | --- |
| [BIDS scan inventory](scripts/count_rawdata_scans.sh) | Count T1w, T2w, DWI, EPI, and BOLD files, subjects, and sessions without double-counting diffusion runs as processing datasets | [Synthetic scan-count output](examples/sample-output/bids/demo-console.txt) |
| [BIDS/NDA audit](scripts/compare_rawdata_nda.sh) | Reconcile imaging availability with an image03 export while retaining session labels and identifying missing or uncertain records | [Session comparison](examples/sample-output/bids/comparison_by_session.csv) |
| [Eddy QC comparison](scripts/compare_eddy_qc_methods.py) | Pair alternative preprocessing outputs and summarize motion/outlier measurements and compatibility | [Paired QC metrics](examples/sample-output/qc/eddy_qc_metrics_long.csv) |
| [Readout metadata resolver](scripts/resolve_dwi_readout.py) | Recover a missing diffusion readout parameter from exact records or consistent subsite donors, with explicit provenance | [Provenance example](examples/sample-output/readout/demo-console.txt) |
| [Longitudinal design builder](scripts/build_swe_design.py) | Preserve scan order, actual follow-up intervals, subject grouping, and contrast dimensions | [Design matrix](examples/sample-output/design/DesignMatrix.txt) |
| [Reusable ROI mixed-model functions](scripts/roi_lmer_functions.R) | Separate specification, scaling, per-ROI fitting, contrasts, confidence intervals, and multiple-testing summaries from study notebooks | [Prepared synthetic R example](examples/demo_roi_models.R) |
| [FreeSurfer aggregation](scripts/fs_aggregate_data.sh) | Convert nested aparc/aseg statistics into measure-specific wide and long tables | [Usage and dependencies](docs/USAGE.md) |

## How the work evolved

These tools were revised in response to practical research problems: repeated diffusion runs needed session-level counting; metadata required explicit matching and donor checks; QC comparisons needed reliable subject/session pairing; and longitudinal models benefited from reusable definitions and documented design assumptions. [Selected milestones](docs/ITERATIONS.md) distinguish saved-source history from changes made while preparing this portfolio.

## Validation and scope

Ten automated behavioral checks passed during preparation, and the selected Python/Bash files passed syntax checks. The three demonstration workflows and the standalone readout example were executed on synthetic inputs. [Validation details](docs/VALIDATION.md) identify the specific checks and limits.

R model fitting and FreeSurfer processing require additional dependencies and were not executed in the preparation environment. QC method preferences are heuristics that require visual/scientific review. Design files are plain-text inputs/reference vectors, not automatically valid FSL VEST files. No participant data, clinical exports, container binaries, or credentials are included.

## About my contribution

I supplied workflow requirements and research context and used ChatGPT/Codex for iterative drafting, debugging, refactoring, and documentation. The code coordinates and summarizes outputs from established scientific tools; it does not implement their imaging algorithms from scratch. [Attribution](ATTRIBUTION.md) describes that distinction.

I am interested in translating my clinical research and imaging-workflow experience into medical-imaging technology, research software, and healthcare data roles.

# Usage and dependencies

Run the commands from the repository root. Synthetic demos write temporary outputs under `examples/generated/`, which Git ignores. Samples committed under `examples/sample-output/` are outputs from invented fixtures.

## BIDS inventory and submission audit

```bash
bash scripts/count_rawdata_scans.sh /path/to/rawdata
bash scripts/compare_rawdata_nda.sh /path/to/rawdata /path/to/image03.csv /path/to/audit-output
```

The inventory recognizes T1w, T2w, DWI, EPI references, and BOLD suffixes. DWI processing count is one per session containing DWI. The NDA audit reports CSV coverage; it does not verify that NDA accepted a submission. Both read source data; keep real audit outputs private.

## Paired QC comparison

```bash
python3 scripts/compare_eddy_qc_methods.py --with-root /path/to/with-slice-timing --without-root /path/to/without-slice-timing --output-dir /path/to/qc-comparison
```

Requires Python standard library only. Reads Eddy motion/outlier files and writes metrics/comparison/summary CSVs. Pairing uses subject/session labels. Its weighted preference is a review aid, not a validated claim that one preprocessing method is universally better.

## Metadata provenance

```bash
python3 scripts/resolve_dwi_readout.py --metadata examples/metadata.csv --json examples/sub-demo01_ses-1_dwi.json --subject sub-demo01 --session ses-1 --header
```

Priority: valid JSON readout, exact subject/session/JSON-basename CSV match, then consistent same-subsite donors. Required CSV columns: subject, session, file, sub_site, TotalReadoutTime. It requires valid phase encoding in JSON and a readable CSV even when JSON supplies the readout. Conflicting donor values fail; source JSON is unchanged.

## Longitudinal design

```bash
python3 scripts/build_swe_design.py --covariates examples/covariates.csv --scan-dir /path/to/scans --modality FAt FW --out-dir /path/to/design
```

Covariates: subject, age, sex, days_ses1_ses2, days_ses1_ses3. Files include scan order, column names, grouping and reference contrasts. The optional sex-by-time interaction has a sixth design column; reference-vector dimensions were corrected during portfolio preparation. Missing scan paths produce warnings; inspect them before processing.

## R mixed-model functions

Install packages listed in `dependencies.R`, then run:

```bash
Rscript examples/demo_roi_models.R
```

The example uses invented ROI values. It is prepared but has not been executed here. The definitions were extracted from the revised research notebook without including study analysis calls or results. Check model assumptions, missing-data behavior, scaling, confidence-interval methods, contrast direction, and correction families for each scientific question.

## FreeSurfer tables

```bash
bash scripts/fs_aggregate_data.sh --subjects-dir /path/to/freesurfer --outdir /path/to/tables --format both
```

Requires Bash 4+, Python 3, and configured FreeSurfer `aparcstats2table`/`asegstats2table`. Produces volume, surface-area, mean-curvature and thickness tables. The recovered source does not contain the subsequently discussed brainvol extension. It writes tables; no MRI processing was run during preparation.

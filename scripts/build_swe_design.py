#!/usr/bin/env python3
"""
build_swe_design.py

Standalone (no R, stdlib-only) script that builds the SwE (Sandwich
Estimator) inputs for a longitudinal TBSS analysis: baseline / 3mo / 12mo,
single group, no control arm.

It reads a small per-subject covariates CSV (produced once from data_prep.R
via export_swe_covariates(), or built by hand with the same columns):

    subject,age,sex,days_ses1_ses2,days_ses1_ses3

  - age             baseline age (years)
  - sex             "Male" / "Female"
  - days_ses1_ses2  actual elapsed days from the baseline scan to the 3mo scan
  - days_ses1_ses3  actual elapsed days from the baseline scan to the 12mo scan

and writes, into --out-dir/<modality>/ (one subfolder per --modality passed, so
each modality gets a complete, self-contained set ready to hand to SPM/SwE):

    ScanList.txt                 one scan path per row (subject x session)
    DesignMatrix.txt             numeric design matrix, tab-separated, no header
    DesignMatrix_ColumnNames.txt column order reference
    Group.txt                    subject-grouping vector for the sandwich covariance
    Contrasts_reference.csv      recommended t-contrast vectors

DesignMatrix.txt, DesignMatrix_ColumnNames.txt, Group.txt, and
Contrasts_reference.csv are identical across modalities (the statistical model
doesn't depend on which skeletonised metric is being analyzed) -- only
ScanList.txt differs. They're still written per-modality subfolder rather than
shared/deduplicated, so each modality's folder can be handed to SPM/SwE on its
own without cross-referencing another folder.

Design (dissociates the longitudinal effect of time from the cross-sectional
effect of baseline age, per SwE-toolbox forum guidance from T. Nichols,
citing Guillaume et al. 2014 and Sorensen et al. 2021; sex added the same way
baseline age is added -- as an ordinary column, not a per-subject dummy, which
is what makes it estimable alongside time in an SwE model):

    1. intercept
    2. time_from_baseline   actual elapsed years since that subject's own
                             baseline scan (0 / days_ses1_ses2/365.25 /
                             days_ses1_ses3/365.25), NOT nominal 0/0.25/1
    3. baseline_age_c       baseline age, mean-centered across the sample
    4. age_x_time           interaction: does rate of change depend on
                             baseline age (acceleration/deceleration)
    5. sex                  0 = Male, 1 = Female
    [6. sex_x_time]         optional, only with --include-sex-time-interaction

Row order (subject-major, chronological within subject) is identical across
ScanList.txt, DesignMatrix.txt, and Group.txt -- don't re-sort any of the
three independently afterward.

Scan paths follow the pnlpipe TBSS "Longitudinal_Ready" layout, where session
and modality live in the directory structure, not the filename:

    <scan_dir>/<session>/<modality>/skeleton/<subject>_<modality>_to_target_skel.nii.gz

e.g. .../Longitudinal_Ready/ses-1/FA/skeleton/BAR26_FA_to_target_skel.nii.gz

Usage (single modality):
    python3 build_swe_design.py \
        --covariates /example/swe_covariates.csv \
        --scan-dir /example/Longitudinal_Ready \
        --modality FA \
        --out-dir swe_inputs
    # -> swe_inputs/FA/{ScanList,DesignMatrix,...}.txt

Usage (multiple modalities in one run):
    python3 build_swe_design.py \
        --covariates /example/swe_covariates.csv \
        --scan-dir /example/Longitudinal_Ready \
        --modality FA FAt FW \
        --out-dir swe_inputs
    # -> swe_inputs/FA/..., swe_inputs/FAt/..., swe_inputs/FW/...

References:
    Guillaume, B., Hua, X., Thompson, P. M., Waldorp, L., Nichols, T. E., & ADNI
    (2014). Fast and accurate modelling of longitudinal and repeated measures
    neuroimaging data. NeuroImage, 94, 287-302.

    Sorensen, O., Walhovd, K. B., & Fjell, A. M. (2021). A recipe for accurate
    estimation of lifespan brain trajectories, distinguishing longitudinal and
    cohort effects. NeuroImage, 226, 117596.
"""

import argparse
import csv
import os
import sys

DAYS_PER_YEAR = 365.25
SEX_MAP = {"male": 0.0, "m": 0.0, "female": 1.0, "f": 1.0}
SESSIONS = ["ses-1", "ses-2", "ses-3"]


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Build SwE longitudinal TBSS design files.")
    p.add_argument("--covariates", required=True,
                    help="CSV with columns: subject,age,sex,days_ses1_ses2,days_ses1_ses3")
    p.add_argument("--scan-dir", required=True,
                    help="pnlpipe 'Longitudinal_Ready' directory (session/modality subfolders appended automatically)")
    p.add_argument("--modality", nargs="+", default=["FA"], choices=["FA", "MD", "RD", "AD", "FAt", "FW"],
                    help="One or more skeletonised metrics to build the design for (default: FA). "
                         "Pass multiple to build all of them in one run, e.g. --modality FA FAt FW")
    p.add_argument("--out-dir", required=True,
                    help="Directory to write into; each modality gets its own subfolder (out-dir/FA, out-dir/MD, ...)")
    p.add_argument("--include-sex-time-interaction", action="store_true",
                    help="Add a sex x time_from_baseline column (tests whether sex moderates the trajectory, not just its level)")
    return p.parse_args(argv)


def read_covariates(path):
    """Read subject,age,sex,days_ses1_ses2,days_ses1_ses3 -> list of dicts, order preserved."""
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        required = {"subject", "age", "sex", "days_ses1_ses2", "days_ses1_ses3"}
        missing_cols = required - set(reader.fieldnames or [])
        if missing_cols:
            sys.exit(f"ERROR: {path} is missing required column(s): {sorted(missing_cols)}")
        for row in reader:
            rows.append(row)
    if not rows:
        sys.exit(f"ERROR: {path} has no data rows.")
    return rows


def to_float_or_none(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def build_manifest(cov_rows):
    """One row per subject x session, chronologically ordered, with derived columns."""
    manifest = []
    incomplete_subjects = []
    unmapped_sex = []

    for row in cov_rows:
        subject = row["subject"].strip()
        age = to_float_or_none(row["age"])
        sex_raw = (row["sex"] or "").strip()
        sex = SEX_MAP.get(sex_raw.lower())
        d2 = to_float_or_none(row["days_ses1_ses2"])
        d3 = to_float_or_none(row["days_ses1_ses3"])

        if sex_raw and sex is None:
            unmapped_sex.append((subject, sex_raw))

        if age is None or sex is None or d2 is None or d3 is None:
            incomplete_subjects.append(subject)
            continue  # skip -- can't compute a design row without all four

        time_by_session = {"ses-1": 0.0, "ses-2": d2 / DAYS_PER_YEAR, "ses-3": d3 / DAYS_PER_YEAR}
        for session in SESSIONS:
            manifest.append({
                "subject": subject,
                "session": session,
                "age": age,
                "sex": sex,
                "time_from_baseline": time_by_session[session],
            })

    if unmapped_sex:
        print(f"WARNING: unmapped sex value(s), these subjects were dropped: {unmapped_sex}", file=sys.stderr)
    if incomplete_subjects:
        print(f"WARNING: {len(incomplete_subjects)} subject(s) skipped for missing age/sex/interval: "
              f"{incomplete_subjects}", file=sys.stderr)

    return manifest


def add_design_columns(manifest, include_sex_time_interaction):
    if not manifest:
        sys.exit("ERROR: no complete subject rows to build a design from.")
    mean_age = sum(r["age"] for r in manifest) / len(manifest)
    # mean_age above is computed over all ROWS (3x per subject) but since age
    # is constant within subject this equals the per-subject mean -- fine.
    for r in manifest:
        r["baseline_age_c"] = r["age"] - mean_age
        r["age_x_time"] = r["time_from_baseline"] * r["baseline_age_c"]
        if include_sex_time_interaction:
            r["sex_x_time"] = r["sex"] * r["time_from_baseline"]
    return mean_age


def design_matrix(manifest, include_sex_time_interaction):
    cols = ["intercept", "time_from_baseline", "baseline_age_c", "age_x_time", "sex"]
    if include_sex_time_interaction:
        cols.append("sex_x_time")
    rows = []
    for r in manifest:
        row = [1.0, r["time_from_baseline"], r["baseline_age_c"], r["age_x_time"], r["sex"]]
        if include_sex_time_interaction:
            row.append(r["sex_x_time"])
        rows.append(row)
    return cols, rows


def matrix_rank(rows, tol=1e-9):
    """Rank via Gaussian elimination with partial pivoting -- pure stdlib,
    no numpy dependency (design here is at most a few hundred rows x ~6 cols)."""
    if not rows:
        return 0
    m = [list(r) for r in rows]
    n_rows, n_cols = len(m), len(m[0])
    rank = 0
    for col in range(n_cols):
        pivot_row = None
        best = tol
        for r in range(rank, n_rows):
            if abs(m[r][col]) > best:
                best = abs(m[r][col])
                pivot_row = r
        if pivot_row is None:
            continue
        m[rank], m[pivot_row] = m[pivot_row], m[rank]
        pivot_val = m[rank][col]
        for r in range(n_rows):
            if r != rank:
                factor = m[r][col] / pivot_val
                for c in range(col, n_cols):
                    m[r][c] -= factor * m[rank][c]
        rank += 1
        if rank == n_rows:
            break
    return rank


def scan_path(scan_dir, session, modality, subject):
    return os.path.join(scan_dir, session, modality, "skeleton", f"{subject}_{modality}_to_target_skel.nii.gz")


def write_modality_outputs(modality, manifest, col_names, rows, subject_index, scan_dir,
                            out_dir, include_sex_time_interaction, mean_age):
    """Write one modality's complete, self-contained set of 5 SwE input files
    into out_dir/<modality>/. DesignMatrix.txt/DesignMatrix_ColumnNames.txt/
    Group.txt/Contrasts_reference.csv are identical across modalities -- only
    ScanList.txt (and its missing-file check) actually depends on `modality`."""
    modality_dir = os.path.join(out_dir, modality)
    os.makedirs(modality_dir, exist_ok=True)

    scan_paths = [scan_path(scan_dir, r["session"], modality, r["subject"]) for r in manifest]

    missing_scans = [p for p in scan_paths if not os.path.exists(p)]
    if missing_scans:
        print(f"WARNING [{modality}]: {len(missing_scans)} scan file(s) not found on disk, e.g.:", file=sys.stderr)
        for p in missing_scans[:10]:
            print(f"  {p}", file=sys.stderr)
        if len(missing_scans) > 10:
            print(f"  ... and {len(missing_scans) - 10} more", file=sys.stderr)

    with open(os.path.join(modality_dir, "ScanList.txt"), "w") as f:
        for p in scan_paths:
            f.write(p + "\n")

    with open(os.path.join(modality_dir, "DesignMatrix.txt"), "w") as f:
        for row in rows:
            f.write("\t".join(f"{v:.10g}" for v in row) + "\n")

    with open(os.path.join(modality_dir, "DesignMatrix_ColumnNames.txt"), "w") as f:
        for i, name in enumerate(col_names, start=1):
            f.write(f"{i}: {name}\n")

    with open(os.path.join(modality_dir, "Group.txt"), "w") as f:
        for r in manifest:
            f.write(str(subject_index[r["subject"]]) + "\n")

    contrasts = [
        ("Time (change over follow-up)", "0 1 0 0 0"),
        ("Baseline age (cross-sectional)", "0 0 1 0 0"),
        ("Age x Time (acceleration/deceleration)", "0 0 0 1 0"),
        ("Sex", "0 0 0 0 1"),
    ]
    if include_sex_time_interaction:
        contrasts = [(name, vector + " 0") for name, vector in contrasts]
        contrasts.append(("Sex x Time", "0 0 0 0 0 1"))
    with open(os.path.join(modality_dir, "Contrasts_reference.csv"), "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["contrast_name", "vector"])
        writer.writerows(contrasts)

    n_subjects = len({r["subject"] for r in manifest})
    n_missing = len(missing_scans)
    print(f"[{modality}] wrote ScanList.txt, DesignMatrix.txt, DesignMatrix_ColumnNames.txt, Group.txt, "
          f"Contrasts_reference.csv to {modality_dir} "
          f"(n = {n_subjects} subjects, {len(manifest)} rows, mean baseline age = {mean_age:.2f}"
          f"{f', {n_missing} scan file(s) missing' if n_missing else ''}).")


def main():
    args = parse_args()

    cov_rows = read_covariates(args.covariates)
    subject_order = [row["subject"].strip() for row in cov_rows]  # preserves CSV order for Group.txt indexing

    manifest = build_manifest(cov_rows)
    mean_age = add_design_columns(manifest, args.include_sex_time_interaction)
    col_names, rows = design_matrix(manifest, args.include_sex_time_interaction)

    rank = matrix_rank(rows)
    if rank < len(col_names):
        print(f"WARNING: design matrix is rank-deficient (rank {rank} of {len(col_names)} columns) "
              f"-- check for collinear regressors.", file=sys.stderr)

    subject_index = {s: i + 1 for i, s in enumerate(subject_order)}  # 1-based, stable order from the CSV

    # Modalities share the same manifest/design/group -- only scan paths differ --
    # so those are computed once above and reused for every --modality passed.
    for modality in args.modality:
        write_modality_outputs(
            modality=modality, manifest=manifest, col_names=col_names, rows=rows,
            subject_index=subject_index, scan_dir=args.scan_dir, out_dir=args.out_dir,
            include_sex_time_interaction=args.include_sex_time_interaction, mean_age=mean_age,
        )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compare Eddy QC outputs from DWI runs with and without slice timing.

The script recursively discovers *.eddy_movement_rms files, pairs scans by
sub-* and ses-*, summarizes motion/outlier metrics, verifies that the two runs
contain the same numbers of volumes/slices, and writes detailed comparison CSVs.
"""

import argparse
import csv
import math
import re
import statistics
import sys
from pathlib import Path

MOVEMENT_SUFFIX = ".eddy_movement_rms"
METHOD_WITH = "with_slice_timing"
METHOD_WITHOUT = "without_slice_timing"

# Larger weights indicate that the metric contributes more to the QC preference.
# All listed metrics are interpreted as lower-is-better.
SCORE_METRICS = {
    "outlier_slice_pct": 3.0,
    "outlier_volume_pct": 2.0,
    "mean_outlier_n_stdev": 2.0,
    "mean_rel_rms": 1.0,
    "mean_abs_rms": 1.0,
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare matched Eddy QC outputs with versus without slice timing."
    )
    parser.add_argument("--with-root", required=True, type=Path,
                        help="Derivatives root containing the with-slice-timing Eddy outputs")
    parser.add_argument("--without-root", required=True, type=Path,
                        help="Derivatives root containing the without-slice-timing Eddy outputs")
    parser.add_argument("--output-dir", required=True, type=Path,
                        help="Directory in which comparison CSVs and the report will be written")
    parser.add_argument("--tie-percent", type=float, default=1.0,
                        help="Relative difference treated as a tie for each metric; default: 1.0")
    parser.add_argument("--include-work", action="store_true",
                        help="Also search paths containing a directory named work")
    return parser.parse_args()


def finite(values):
    return [value for value in values if value is not None and math.isfinite(value)]


def safe_mean(values):
    values = finite(values)
    return statistics.fmean(values) if values else None


def safe_median(values):
    values = finite(values)
    return statistics.median(values) if values else None


def read_numeric_table(path):
    rows = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line_number, raw in enumerate(handle, 1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                tokens = [token for token in re.split(r"[\s,]+", line) if token]
                try:
                    rows.append([float(token) for token in tokens])
                except ValueError as exc:
                    return None, f"non-numeric value at line {line_number}: {exc}"
    except OSError as exc:
        return None, str(exc)
    if not rows:
        return None, "file is empty"
    widths = {len(row) for row in rows}
    if len(widths) != 1:
        return None, f"inconsistent row lengths: {sorted(widths)}"
    return rows, ""


def parse_entities(path):
    text = str(path)
    subject_match = re.search(r"(?:^|[/_])(sub-[^/_]+)", text)
    session_match = re.search(r"(?:^|[/_])(ses-[^/_]+)", text)
    subject = subject_match.group(1) if subject_match else ""
    session = session_match.group(1) if session_match else ""
    return subject, session


def candidate_rank(path):
    try:
        mtime = path.stat().st_mtime
    except OSError:
        mtime = 0.0
    return (path.parent.name == "dwi", mtime, -len(path.parts), str(path))


def discover(root, include_work=False):
    if not root.is_dir():
        raise FileNotFoundError(f"Root directory does not exist: {root}")
    grouped = {}
    for path in root.rglob(f"*{MOVEMENT_SUFFIX}"):
        if not path.is_file():
            continue
        if not include_work and "work" in path.parts:
            continue
        subject, session = parse_entities(path)
        if not subject:
            print(f"[WARN] Skipping path without a sub-* entity: {path}", file=sys.stderr)
            continue
        grouped.setdefault((subject, session), []).append(path)
    selected = {}
    for key, candidates in grouped.items():
        candidates = sorted(candidates, key=candidate_rank, reverse=True)
        selected[key] = (candidates[0], len(candidates))
        if len(candidates) > 1:
            print(f"[WARN] {root}: found {len(candidates)} Eddy outputs for {key[0]} {key[1] or '<no session>'}; using {candidates[0]}", file=sys.stderr)
    return selected


def companion(prefix, suffix):
    return Path(f"{prefix}{suffix}")


def orient_matrix_by_volumes(matrix, n_volumes):
    n_rows = len(matrix)
    n_cols = len(matrix[0])
    if n_rows == n_volumes:
        return matrix, n_cols, "rows_are_volumes"
    if n_cols == n_volumes:
        transposed = [[matrix[row][volume] for row in range(n_rows)] for volume in range(n_cols)]
        return transposed, n_rows, "columns_are_volumes"
    return None, None, f"matrix shape {n_rows}x{n_cols} does not match {n_volumes} volumes"


def parse_command(prefix):
    command_path = companion(prefix, ".eddy_command_txt")
    result = {
        "command_path": str(command_path) if command_path.is_file() else "",
        "command_has_mporder": "unknown",
        "command_has_s2v_niter": "unknown",
        "slice_timing_source": "unknown",
        "s2v_enabled": "unknown",
    }
    if not command_path.is_file():
        return result, "missing eddy_command_txt"
    try:
        command = command_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return result, f"could not read eddy_command_txt: {exc}"
    has_mporder = bool(re.search(r"(?:^|\s)--mporder(?:=|\s+)", command))
    has_s2v_niter = bool(re.search(r"(?:^|\s)--s2v_niter(?:=|\s+)", command))
    if re.search(r"(?:^|\s)--slspec(?:=|\s+)", command):
        timing_source = "slspec"
    elif re.search(r"(?:^|\s)--json(?:=|\s+)", command):
        timing_source = "json"
    else:
        timing_source = "none"
    result.update({
        "command_has_mporder": "yes" if has_mporder else "no",
        "command_has_s2v_niter": "yes" if has_s2v_niter else "no",
        "slice_timing_source": timing_source,
        "s2v_enabled": "yes" if has_mporder else "no",
    })
    return result, ""


def summarize_case(method, movement_path, duplicate_count):
    subject, session = parse_entities(movement_path)
    prefix = Path(str(movement_path)[:-len(MOVEMENT_SUFFIX)])
    row = {
        "subject": subject,
        "session": session,
        "method": method,
        "status": "OK",
        "duplicate_candidates": duplicate_count,
        "eddy_prefix": str(prefix),
        "movement_rms_path": str(movement_path),
        "outlier_map_path": "",
        "outlier_n_stdev_map_path": "",
        "restricted_movement_rms_path": "",
        "n_volumes": None,
        "n_slices": None,
        "mean_abs_rms": None,
        "median_abs_rms": None,
        "max_abs_rms": None,
        "mean_rel_rms": None,
        "median_rel_rms": None,
        "max_rel_rms": None,
        "mean_restricted_abs_rms": None,
        "mean_restricted_rel_rms": None,
        "total_outlier_slices": None,
        "outlier_slice_pct": None,
        "volumes_with_outliers": None,
        "outlier_volume_pct": None,
        "mean_outlier_slices_per_volume": None,
        "max_outlier_slices_per_volume": None,
        "mean_outlier_n_stdev": None,
        "max_outlier_n_stdev": None,
        "outlier_map_orientation": "",
    }
    problems = []

    movement, error = read_numeric_table(movement_path)
    if error:
        problems.append(f"movement RMS: {error}")
    elif len(movement[0]) < 2:
        problems.append(f"movement RMS has {len(movement[0])} column(s), expected at least 2")
    else:
        absolute = [values[0] for values in movement]
        relative = [values[1] for values in movement]
        row.update({
            "n_volumes": len(movement),
            "mean_abs_rms": safe_mean(absolute),
            "median_abs_rms": safe_median(absolute),
            "max_abs_rms": max(absolute),
            "mean_rel_rms": safe_mean(relative),
            "median_rel_rms": safe_median(relative),
            "max_rel_rms": max(relative),
        })

    restricted_path = companion(prefix, ".eddy_restricted_movement_rms")
    if restricted_path.is_file():
        row["restricted_movement_rms_path"] = str(restricted_path)
        restricted, error = read_numeric_table(restricted_path)
        if error:
            problems.append(f"restricted movement RMS: {error}")
        elif len(restricted[0]) >= 2:
            row["mean_restricted_abs_rms"] = safe_mean([values[0] for values in restricted])
            row["mean_restricted_rel_rms"] = safe_mean([values[1] for values in restricted])

    outlier_path = companion(prefix, ".eddy_outlier_map")
    if outlier_path.is_file():
        row["outlier_map_path"] = str(outlier_path)
        outlier, error = read_numeric_table(outlier_path)
        if error:
            problems.append(f"outlier map: {error}")
        elif row["n_volumes"] is None:
            problems.append("outlier map cannot be oriented because movement volume count is unavailable")
        else:
            volume_rows, n_slices, orientation = orient_matrix_by_volumes(outlier, row["n_volumes"])
            row["outlier_map_orientation"] = orientation
            if volume_rows is None:
                problems.append(f"outlier map: {orientation}")
            else:
                binary_rows = [[1 if value > 0.5 else 0 for value in values] for values in volume_rows]
                per_volume = [sum(values) for values in binary_rows]
                total = sum(per_volume)
                volumes_with = sum(value > 0 for value in per_volume)
                row.update({
                    "n_slices": n_slices,
                    "total_outlier_slices": total,
                    "outlier_slice_pct": 100.0 * total / (row["n_volumes"] * n_slices),
                    "volumes_with_outliers": volumes_with,
                    "outlier_volume_pct": 100.0 * volumes_with / row["n_volumes"],
                    "mean_outlier_slices_per_volume": safe_mean(per_volume),
                    "max_outlier_slices_per_volume": max(per_volume),
                })
    else:
        problems.append("missing eddy_outlier_map")

    n_stdev_path = companion(prefix, ".eddy_outlier_n_stdev_map")
    if n_stdev_path.is_file():
        row["outlier_n_stdev_map_path"] = str(n_stdev_path)
        n_stdev, error = read_numeric_table(n_stdev_path)
        if error:
            problems.append(f"outlier n-stdev map: {error}")
        else:
            positive = [value for values in n_stdev for value in values if math.isfinite(value) and value > 0]
            if positive:
                row["mean_outlier_n_stdev"] = safe_mean(positive)
                row["max_outlier_n_stdev"] = max(positive)
            else:
                row["mean_outlier_n_stdev"] = 0.0
                row["max_outlier_n_stdev"] = 0.0
    else:
        problems.append("missing eddy_outlier_n_stdev_map")

    command_values, command_error = parse_command(prefix)
    row.update(command_values)
    if command_error:
        problems.append(command_error)

    if problems:
        row["status"] = "WARNING: " + "; ".join(problems)
    return row


def compare_lower_is_better(with_value, without_value, tie_percent):
    if with_value is None or without_value is None:
        return "unavailable"
    scale = max(abs(with_value), abs(without_value), 1e-12)
    if abs(with_value - without_value) <= scale * tie_percent / 100.0:
        return "tie"
    return METHOD_WITH if with_value < without_value else METHOD_WITHOUT


def compare_pair(with_row, without_row, tie_percent):
    subject = with_row["subject"] if with_row else without_row["subject"]
    session = with_row["session"] if with_row else without_row["session"]
    result = {
        "subject": subject,
        "session": session,
        "with_output_found": "yes" if with_row else "no",
        "without_output_found": "yes" if without_row else "no",
        "input_size_match": "unknown",
        "configuration_check": "unknown",
        "with_s2v_enabled": with_row.get("s2v_enabled", "") if with_row else "",
        "without_s2v_enabled": without_row.get("s2v_enabled", "") if without_row else "",
        "with_slice_timing_source": with_row.get("slice_timing_source", "") if with_row else "",
        "without_slice_timing_source": without_row.get("slice_timing_source", "") if without_row else "",
        "with_score": 0.0,
        "without_score": 0.0,
        "available_score_weight": 0.0,
        "preferred_method": "",
        "interpretation": "",
        "with_eddy_prefix": with_row.get("eddy_prefix", "") if with_row else "",
        "without_eddy_prefix": without_row.get("eddy_prefix", "") if without_row else "",
    }
    if not with_row:
        result["preferred_method"] = "missing_with_slice_timing_output"
        result["interpretation"] = "No matched with-slice-timing Eddy output was found."
        return result
    if not without_row:
        result["preferred_method"] = "missing_without_slice_timing_output"
        result["interpretation"] = "No matched without-slice-timing Eddy output was found."
        return result

    volume_match = with_row.get("n_volumes") == without_row.get("n_volumes") if with_row.get("n_volumes") is not None and without_row.get("n_volumes") is not None else None
    slice_match = with_row.get("n_slices") == without_row.get("n_slices") if with_row.get("n_slices") is not None and without_row.get("n_slices") is not None else None
    if volume_match is False or slice_match is False:
        result["input_size_match"] = "no"
    elif volume_match is True and (slice_match is True or slice_match is None):
        result["input_size_match"] = "yes" if slice_match is True else "partial"
    else:
        result["input_size_match"] = "unknown"

    with_s2v = with_row.get("s2v_enabled")
    without_s2v = without_row.get("s2v_enabled")
    result["configuration_check"] = "PASS" if with_s2v == "yes" and without_s2v == "no" else "CHECK_COMMANDS"

    for metric, weight in SCORE_METRICS.items():
        with_value = with_row.get(metric)
        without_value = without_row.get(metric)
        winner = compare_lower_is_better(with_value, without_value, tie_percent)
        result[f"{metric}_with"] = with_value
        result[f"{metric}_without"] = without_value
        result[f"{metric}_delta_with_minus_without"] = with_value - without_value if with_value is not None and without_value is not None else None
        result[f"{metric}_winner"] = winner
        if winner != "unavailable":
            result["available_score_weight"] += weight
        if winner == METHOD_WITH:
            result["with_score"] += weight
        elif winner == METHOD_WITHOUT:
            result["without_score"] += weight

    for metric in ("max_abs_rms", "max_rel_rms", "total_outlier_slices", "volumes_with_outliers", "max_outlier_slices_per_volume", "max_outlier_n_stdev"):
        with_value = with_row.get(metric)
        without_value = without_row.get(metric)
        result[f"{metric}_with"] = with_value
        result[f"{metric}_without"] = without_value
        result[f"{metric}_delta_with_minus_without"] = with_value - without_value if with_value is not None and without_value is not None else None

    if result["input_size_match"] == "no":
        result["preferred_method"] = "invalid_input_size_mismatch"
        result["interpretation"] = "The runs do not contain the same number of volumes and/or slices, so the QC metrics are not directly comparable."
    elif result["available_score_weight"] == 0:
        result["preferred_method"] = "insufficient_metrics"
        result["interpretation"] = "No weighted QC metrics were available in both runs."
    elif result["with_score"] > result["without_score"]:
        result["preferred_method"] = METHOD_WITH
        result["interpretation"] = "Weighted Eddy QC metrics favor the slice-timing/slice-to-volume run. Confirm with visual QC."
    elif result["without_score"] > result["with_score"]:
        result["preferred_method"] = METHOD_WITHOUT
        result["interpretation"] = "Weighted Eddy QC metrics favor the volume-wise run without slice timing. Confirm with visual QC."
    else:
        result["preferred_method"] = "tie"
        result["interpretation"] = "The weighted Eddy QC comparison is tied within the selected tolerance."

    if result["configuration_check"] != "PASS":
        result["interpretation"] += " Eddy command options did not clearly confirm with=enabled and without=disabled; inspect eddy_command_txt."
    return result


def write_csv(path, rows):
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fieldnames = []
    seen = set()
    for row in rows:
        for key in row:
            if key not in seen:
                seen.add(key)
                fieldnames.append(key)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def write_summary(path, comparisons, metrics_rows):
    counts = {}
    for row in comparisons:
        value = row.get("preferred_method", "")
        counts[value] = counts.get(value, 0) + 1
    summary = [
        {"item": "matched_or_discovered_subject_sessions", "value": len(comparisons)},
        {"item": "with_slice_timing_metric_rows", "value": sum(row["method"] == METHOD_WITH for row in metrics_rows)},
        {"item": "without_slice_timing_metric_rows", "value": sum(row["method"] == METHOD_WITHOUT for row in metrics_rows)},
    ]
    for key in sorted(counts):
        summary.append({"item": f"preferred_method_count__{key}", "value": counts[key]})

    for metric in SCORE_METRICS:
        for method in (METHOD_WITH, METHOD_WITHOUT):
            values = [row.get(metric) for row in metrics_rows if row.get("method") == method]
            summary.append({"item": f"median__{metric}__{method}", "value": safe_median(values)})
        winner_counts = {METHOD_WITH: 0, METHOD_WITHOUT: 0, "tie": 0, "unavailable": 0}
        for row in comparisons:
            winner = row.get(f"{metric}_winner", "unavailable")
            winner_counts[winner] = winner_counts.get(winner, 0) + 1
        for winner, count in winner_counts.items():
            summary.append({"item": f"{metric}__winner_count__{winner}", "value": count})
    write_csv(path, summary)


def write_readme(path, args):
    text = f"""Eddy QC method comparison
===========================

With-slice-timing root:
{args.with_root}

Without-slice-timing root:
{args.without_root}

Tie tolerance: {args.tie_percent}%

Outputs
-------
eddy_qc_metrics_long.csv
    One row per subject/session/method with the raw summarized Eddy metrics.

eddy_qc_comparison_wide.csv
    One row per subject/session with both methods side-by-side, metric-specific
    winners, weighted scores, command checks, and a preferred_method field.

eddy_qc_summary.csv
    Overall counts and medians across all discovered scans.

Scoring
-------
Lower is better for every weighted metric:
- outlier_slice_pct: weight 3
- outlier_volume_pct: weight 2
- mean_outlier_n_stdev: weight 2
- mean_rel_rms: weight 1
- mean_abs_rms: weight 1

Differences within {args.tie_percent}% are treated as ties. The weighted preference is a
screening summary, not a replacement for eddy_quad HTML review, inspection of outlier
patterns, registration/alignment checks, and visual inspection of corrected DWIs.

Configuration check
-------------------
PASS means eddy_command_txt showed --mporder in the with-slice-timing run and did
not show --mporder in the without-slice-timing run. CHECK_COMMANDS means the method
labels were not clearly confirmed from the stored Eddy commands.
"""
    path.write_text(text, encoding="utf-8")


def main():
    args = parse_args()
    if args.tie_percent < 0:
        raise SystemExit("--tie-percent must be non-negative")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    try:
        with_found = discover(args.with_root, args.include_work)
        without_found = discover(args.without_root, args.include_work)
    except FileNotFoundError as exc:
        raise SystemExit(str(exc))

    if not with_found:
        print(f"[WARN] No *{MOVEMENT_SUFFIX} files found under {args.with_root}", file=sys.stderr)
    if not without_found:
        print(f"[WARN] No *{MOVEMENT_SUFFIX} files found under {args.without_root}", file=sys.stderr)

    metrics_rows = []
    with_rows = {}
    without_rows = {}
    for key, (path, duplicates) in sorted(with_found.items()):
        row = summarize_case(METHOD_WITH, path, duplicates)
        metrics_rows.append(row)
        with_rows[key] = row
    for key, (path, duplicates) in sorted(without_found.items()):
        row = summarize_case(METHOD_WITHOUT, path, duplicates)
        metrics_rows.append(row)
        without_rows[key] = row

    all_keys = sorted(set(with_rows) | set(without_rows))
    comparisons = [compare_pair(with_rows.get(key), without_rows.get(key), args.tie_percent) for key in all_keys]

    metrics_path = args.output_dir / "eddy_qc_metrics_long.csv"
    comparison_path = args.output_dir / "eddy_qc_comparison_wide.csv"
    summary_path = args.output_dir / "eddy_qc_summary.csv"
    readme_path = args.output_dir / "README_eddy_qc_comparison.txt"
    write_csv(metrics_path, metrics_rows)
    write_csv(comparison_path, comparisons)
    write_summary(summary_path, comparisons, metrics_rows)
    write_readme(readme_path, args)

    preference_counts = {}
    for row in comparisons:
        preference = row["preferred_method"]
        preference_counts[preference] = preference_counts.get(preference, 0) + 1

    print("=" * 72)
    print("Eddy QC comparison finished")
    print("=" * 72)
    print(f"With-slice-timing outputs    : {len(with_rows)}")
    print(f"Without-slice-timing outputs : {len(without_rows)}")
    print(f"Subject/session comparisons  : {len(comparisons)}")
    for preference, count in sorted(preference_counts.items()):
        print(f"{preference:<30}: {count}")
    print(f"Detailed metrics             : {metrics_path}")
    print(f"Pairwise comparison          : {comparison_path}")
    print(f"Overall summary              : {summary_path}")
    print(f"Method notes                 : {readme_path}")
    print("=" * 72)


if __name__ == "__main__":
    main()

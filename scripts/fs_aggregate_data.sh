#!/usr/bin/env bash
set -euo pipefail

trap 'echo "Script failed at line $LINENO" >&2' ERR

usage() {
  cat <<'EOF'
Usage:
  bash fs_aggregate_data.sh \
    --subjects-dir /path/to/SUBJECTS_DIR \
    --outdir /path/to/output \
    [--subject-list /path/to/subjects.txt] \
    [--parc aparc] \
    [--format wide|long|both]

Description:
  Aggregate FreeSurfer aseg/aparc stats into measure-specific folders.

Outputs:
  volume/
    lh_aparc_volume.csv
    rh_aparc_volume.csv
    aseg_volume.csv
    [optional *_long.csv files]

  surface_area/
    lh_aparc_surface_area.csv
    rh_aparc_surface_area.csv
    [optional *_long.csv files]

  meancurv/
    lh_aparc_meancurv.csv
    rh_aparc_meancurv.csv
    [optional *_long.csv files]

  thickness/
    lh_aparc_thickness.csv
    rh_aparc_thickness.csv
    [optional *_long.csv files]

Arguments:
  --subjects-dir   Root SUBJECTS_DIR for FreeSurfer subjects
  --outdir         Output directory
  --subject-list   Optional text file with one subject per line
                   If omitted, subjects are auto-discovered by finding */stats/aseg.stats
  --parc           Parcellation name for aparcstats2table (default: aparc)
  --format         wide, long, or both (default: both)

Examples:
  bash fs_aggregate_data.sh \
    --subjects-dir /example/pnlpipe \
    --outdir /example/fs8.1.0-stats \
    --format both

  bash fs_aggregate_data.sh \
    --subjects-dir /example/pnlpipe \
    --outdir /example/fs8.1.0-stats \
    --subject-list /example/subjects_nested.txt \
    --format long
EOF
}

SUBJECTS_DIR=""
OUTDIR=""
SUBJECT_LIST=""
PARC="aparc"
FORMAT="both"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subjects-dir)
      SUBJECTS_DIR="$2"
      shift 2
      ;;
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    --subject-list)
      SUBJECT_LIST="$2"
      shift 2
      ;;
    --parc)
      PARC="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$SUBJECTS_DIR" || -z "$OUTDIR" ]]; then
  echo "Error: --subjects-dir and --outdir are required." >&2
  usage
  exit 1
fi

if [[ ! -d "$SUBJECTS_DIR" ]]; then
  echo "Error: SUBJECTS_DIR does not exist: $SUBJECTS_DIR" >&2
  exit 1
fi

case "$FORMAT" in
  wide|long|both) ;;
  *)
    echo "Error: --format must be one of: wide, long, both" >&2
    exit 1
    ;;
esac

command -v aparcstats2table >/dev/null 2>&1 || {
  echo "Error: aparcstats2table not found in PATH." >&2
  exit 1
}
command -v asegstats2table >/dev/null 2>&1 || {
  echo "Error: asegstats2table not found in PATH." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "Error: python3 not found in PATH." >&2
  exit 1
}

export SUBJECTS_DIR

mkdir -p \
  "$OUTDIR/volume" \
  "$OUTDIR/surface_area" \
  "$OUTDIR/meancurv" \
  "$OUTDIR/thickness"

TMP_SUBJECTS=$(mktemp /tmp/fs_subjects.XXXXXX.txt)
trap 'rm -f "$TMP_SUBJECTS"' EXIT

discover_subjects() {
  find "$SUBJECTS_DIR" -type f -path "*/stats/aseg.stats" | \
    while IFS= read -r f; do
      rel="${f#$SUBJECTS_DIR/}"
      printf '%s\n' "${rel%/stats/aseg.stats}"
    done | sort -u
}

if [[ -n "$SUBJECT_LIST" ]]; then
  if [[ ! -f "$SUBJECT_LIST" ]]; then
    echo "Error: subject list not found: $SUBJECT_LIST" >&2
    exit 1
  fi
  awk 'NF {gsub(/\r/,""); print}' "$SUBJECT_LIST" | sort -u > "$TMP_SUBJECTS"
else
  discover_subjects > "$TMP_SUBJECTS"
fi

if [[ ! -s "$TMP_SUBJECTS" ]]; then
  echo "Error: no subjects found." >&2
  exit 1
fi

cp "$TMP_SUBJECTS" "$OUTDIR/subjects_used.txt"

run_aparc_table() {
  local hemi="$1"
  local fs_meas="$2"
  local out_csv="$3"

  aparcstats2table \
    --subjectsfile "$TMP_SUBJECTS" \
    --hemi "$hemi" \
    --parc "$PARC" \
    --meas "$fs_meas" \
    --skip \
    --delimiter comma \
    --tablefile "$out_csv"
}

run_aseg_table() {
  local out_csv="$1"

  asegstats2table \
    --subjectsfile "$TMP_SUBJECTS" \
    --meas volume \
    --skip \
    --delimiter comma \
    --tablefile "$out_csv"
}

wide_to_long() {
  local in_csv="$1"
  local out_csv="$2"
  local kind="$3"      # aparc or aseg
  local hemi="$4"      # lh, rh, or NA
  local measure="$5"   # volume, surface_area, meancurv, thickness

  python3 - "$in_csv" "$out_csv" "$kind" "$hemi" "$PARC" "$measure" <<'PY'
import csv
import sys

in_csv, out_csv, kind, hemi, parc, measure = sys.argv[1:]

with open(in_csv, newline='') as f:
    reader = csv.DictReader(f)
    fieldnames = reader.fieldnames or []

    if len(fieldnames) < 2:
        raise SystemExit(f"Not enough columns found in {in_csv}")

    subject_col = fieldnames[0]

    if kind == "aparc":
        out_fields = ["subject_id", "hemi", "parc", "measure", "region", "value"]
    else:
        out_fields = ["subject_id", "measure", "structure", "value"]

    with open(out_csv, "w", newline='') as g:
        writer = csv.DictWriter(g, fieldnames=out_fields)
        writer.writeheader()

        for row in reader:
            subject = row.get(subject_col, "")
            for col in fieldnames[1:]:
                value = row.get(col, "")
                if value in ("", None):
                    continue

                if kind == "aparc":
                    writer.writerow({
                        "subject_id": subject,
                        "hemi": hemi,
                        "parc": parc,
                        "measure": measure,
                        "region": col,
                        "value": value
                    })
                else:
                    writer.writerow({
                        "subject_id": subject,
                        "measure": measure,
                        "structure": col,
                        "value": value
                    })
PY
}

make_long_if_requested() {
  local wide_csv="$1"
  local kind="$2"
  local hemi="$3"
  local measure="$4"

  if [[ "$FORMAT" == "both" || "$FORMAT" == "long" ]]; then
    wide_to_long "$wide_csv" "${wide_csv%.csv}_long.csv" "$kind" "$hemi" "$measure"
  fi

  if [[ "$FORMAT" == "long" ]]; then
    rm -f "$wide_csv"
  fi
}

echo "Using SUBJECTS_DIR: $SUBJECTS_DIR"
echo "Writing output to: $OUTDIR"
echo "Parcellation: $PARC"
echo "Format: $FORMAT"
echo "Number of subjects: $(wc -l < "$TMP_SUBJECTS")"

# aparc measures
declare -A FS_MEAS_MAP=(
  [volume]="volume"
  [surface_area]="area"
  [meancurv]="meancurv"
  [thickness]="thickness"
)

for folder in volume surface_area meancurv thickness; do
  fs_meas="${FS_MEAS_MAP[$folder]}"

  for hemi in lh rh; do
    out_csv="$OUTDIR/$folder/${hemi}_${PARC}_${folder}.csv"
    run_aparc_table "$hemi" "$fs_meas" "$out_csv"
    make_long_if_requested "$out_csv" "aparc" "$hemi" "$folder"
  done
done

# aseg volume only
aseg_csv="$OUTDIR/volume/aseg_volume.csv"
run_aseg_table "$aseg_csv"
make_long_if_requested "$aseg_csv" "aseg" "NA" "volume"

echo "Done."

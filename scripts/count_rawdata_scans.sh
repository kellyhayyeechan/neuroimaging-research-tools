#!/usr/bin/env bash
# Count BIDS NIfTI files and count each modality once per subject/session.
# Usage: bash count_rawdata_scans.sh [rawdata_directory]
set -euo pipefail
shopt -s nullglob
if [[ ${1:-} == -h || ${1:-} == --help || $# -gt 1 ]]; then
    printf 'Usage: bash %s [rawdata_directory]\n' "${0##*/}"
    exit 0
fi
RAW="${1:-/example/rawdata}"
if [[ ! -d "$RAW" ]]; then printf 'Directory not found: %s\n' "$RAW" >&2; exit 1; fi

# Follow symlinks; count only .nii/.nii.gz files directly in modality folders.
count_images() {
    local suffix="$1" directory
    shift
    local -a directories=()
    for directory in "$@"; do
        if [[ -d "$directory" ]]; then directories+=("$directory"); fi
    done
    if (( ${#directories[@]} == 0 )); then printf '0\n'; return; fi
    find -L "${directories[@]}" -maxdepth 1 -type f \( -name "*_${suffix}.nii" -o -name "*_${suffix}.nii.gz" \) -printf '.' | wc -c
}

labels=('T1w' 'T2w' 'Diffusion (DWI)' 'EPI reference' 'Functional (BOLD)')
image_totals=(0 0 0 0 0)
session_totals=(0 0 0 0 0)
subject_totals=(0 0 0 0 0)
n_subjects=0
n_sessions=0
for subject_dir in "$RAW"/sub-*; do
    [[ -d "$subject_dir" ]] || continue
    n_subjects=$((n_subjects + 1))
    seen=(0 0 0 0 0)
    session_dirs=("$subject_dir"/ses-*)
    # Also support subjects whose modality folders are directly under sub-*.
    if [[ -d "$subject_dir/anat" || -d "$subject_dir/dwi" || -d "$subject_dir/fmap" || -d "$subject_dir/func" ]]; then
        session_dirs=("$subject_dir" "${session_dirs[@]}")
    fi
    for session_dir in "${session_dirs[@]}"; do
        [[ -d "$session_dir" ]] || continue
        n_sessions=$((n_sessions + 1))
        t1=$(count_images T1w "$session_dir/anat")
        t2=$(count_images T2w "$session_dir/anat")
        dwi=$(count_images dwi "$session_dir/dwi")
        epi=$(count_images epi "$session_dir/fmap" "$session_dir/dwi")
        bold=$(count_images bold "$session_dir/func")
        counts=("$t1" "$t2" "$dwi" "$epi" "$bold")
        for i in "${!counts[@]}"; do
            image_totals[i]=$((image_totals[i] + counts[i]))
            if (( counts[i] > 0 )); then
                session_totals[i]=$((session_totals[i] + 1))
                seen[i]=1
            fi
        done
    done
    for i in "${!seen[@]}"; do subject_totals[i]=$((subject_totals[i] + seen[i])); done
done

printf '\nRawdata: %s\nSubjects (sub-* directories): %d\nSubject/session datasets: %d\n\n' "$RAW" "$n_subjects" "$n_sessions"
printf '%-20s %12s %12s %12s\n' 'Modality' 'NIfTI files' 'Sessions' 'Subjects'
for i in "${!labels[@]}"; do
    printf '%-20s %12d %12d %12d\n' "${labels[i]}" "${image_totals[i]}" "${session_totals[i]}" "${subject_totals[i]}"
done
printf '\nExpected eddy datasets (one per session with DWI): %d\n' "${session_totals[2]}"
printf 'Sessions counts each modality once, regardless of AP/PA directions or runs.\n'
printf 'Functional = *_bold; EPI reference = *_epi in fmap/ or dwi/.\n'

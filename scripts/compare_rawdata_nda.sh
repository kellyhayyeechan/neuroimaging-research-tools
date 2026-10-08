#!/usr/bin/env bash
# Usage: bash compare_rawdata_nda.sh [rawdata_dir] [image03_csv] [output_dir]
# Requires Python 3; uses only its standard library. Does not change imaging data.
set -euo pipefail
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    printf 'Usage: bash %s [rawdata_dir] [image03_csv] [output_dir]\n' "${0##*/}"
    exit 0
fi
if (( $# > 3 )); then printf 'Expected at most three arguments.\n' >&2; exit 1; fi
RAW="${1:-/example/rawdata}"
NDA="${2:-/example/image03_template_10.15.25.csv}"
OUT="${3:-./nda_scan_audit_$(date +%Y%m%d_%H%M%S)}"
python3 - "$RAW" "$NDA" "$OUT" <<'PY'
import csv, re, sys
from collections import Counter, defaultdict
from pathlib import Path
from urllib.parse import unquote

raw_root, nda_csv, out = [Path(p).expanduser().absolute() for p in sys.argv[1:]]
if not raw_root.is_dir(): sys.exit(f'Rawdata directory not found: {raw_root}')
if not nda_csv.is_file(): sys.exit(f'NDA CSV not found: {nda_csv}')
mods = ('T1w', 'T2w', 'DWI', 'EPI', 'BOLD')
rules = {'T1w': ('T1w', ('anat',)), 'T2w': ('T2w', ('anat',)), 'DWI': ('dwi', ('dwi',)), 'EPI': ('epi', ('fmap', 'dwi')), 'BOLD': ('bold', ('func',))}
raw_files, raw_pairs, raw_subjects = defaultdict(list), set(), set()
def natural(value): return tuple((1, int(p)) if p.isdigit() else (0, p.lower()) for p in re.split(r'(\d+)', str(value)))
def sorted_pairs(pairs): return sorted(pairs, key=lambda p: (natural(p[0]), natural(p[1])))

for subject in sorted(raw_root.iterdir(), key=lambda p: natural(p.name)):
    if not subject.name.startswith('sub-') or not subject.is_dir(): continue
    raw_subjects.add(subject.name)
    sessions = [p for p in subject.iterdir() if p.name.startswith('ses-') and p.is_dir()]
    if any((subject / d).is_dir() for d in ('anat', 'dwi', 'fmap', 'func')): sessions.append(subject)
    for session in sessions:
        pair = (subject.name, session.name if session != subject else 'no_session')
        raw_pairs.add(pair)
        for mod, (suffix, folders) in rules.items():
            for folder in folders:
                directory = session / folder
                if not directory.is_dir(): continue
                for image in sorted(directory.iterdir(), key=lambda p: natural(p.name)):
                    if image.name.endswith((f'_{suffix}.nii', f'_{suffix}.nii.gz')) and image.is_file():
                        raw_files[pair + (mod,)].append(str(image))

def tags(values, prefix):
    pattern = rf'(?<![A-Za-z0-9-]){prefix}-([A-Za-z0-9]+)(?![A-Za-z0-9-])'
    return {prefix + '-' + label for value in values for label in re.findall(pattern, unquote(value), re.I)}
def unique(values): return next(iter(values)) if len(values) == 1 else ''
def get(row, name): return row.get(name, '').strip()
def functional_entities(filename):
    entities = dict(re.findall(r'(?<![A-Za-z0-9-])(task|acq|dir|run|echo)-([A-Za-z0-9]+)(?![A-Za-z0-9-])', Path(unquote(filename)).name))
    for field in ('run', 'echo'):
        if entities.get(field, '').isdigit(): entities[field] = str(int(entities[field]))
    return entities
def modality(row):
    filename, scan_type = get(row, 'image_file').lower(), get(row, 'scan_type').lower()
    if re.search(r'(?:^|[_/])sbref(?:[_.]|$)', filename): return 'OTHER'
    file_mods = {mod for mod, (suffix, _) in rules.items() if re.search(rf'(?:^|[_/]){suffix.lower()}(?:[_.]|$)', filename)}
    typed_dwi = bool(re.search(r'\b(diffusion|dmri|dwi|dti)\b', scan_type))
    if file_mods == {'EPI'} and typed_dwi: return 'DWI'
    if len(file_mods) == 1: return unique(file_mods)
    if len(file_mods) > 1: return 'UNKNOWN'
    typed = set()
    if typed_dwi: typed.add('DWI')
    if re.search(r'\b(fmri|bold)\b', scan_type): typed.add('BOLD')
    if re.search(r'\bt1w?\b|\b(?:mp|mp2|mpn)rage\b', scan_type): typed.add('T1w')
    if re.search(r'\bt2w?\b(?!\s*(?:\*|star))', scan_type): typed.add('T2w')
    if len(typed) == 1: return unique(typed)
    if re.search(r'\b(pet|eeg|meg|asl|localizer|microscopy|fnirs)\b', scan_type): return 'OTHER'
    return 'UNKNOWN'

nda_counts, nda_pairs, nda_src_ids = Counter(), set(), set()
mapping_rows, unresolved, uncertain = [], [], []
nda_bold = defaultdict(list)
original_counts, original_subjects = Counter(), defaultdict(set)
map_fields = ['csv_line', 'src_subject_id', 'subjectkey', 'visit', 'session_id', 'timepoint_label', 'visnum', 'interview_date', 'image_file', 'manifest', 'scan_type', 'subject', 'session', 'modality', 'match_basis', 'mapping_status']
with nda_csv.open(newline='', encoding='utf-8-sig') as handle:
    reader = csv.reader(handle)
    header = None
    for values in reader:
        names = [value.strip().lower() for value in values]
        if 'src_subject_id' in names and ('image_file' in names or 'manifest' in names): header = names; break
        if reader.line_num >= 20: break
    if header is None: sys.exit('Could not find the image03 header in the first 20 lines. Expected src_subject_id and image_file or manifest.')
    for values in reader:
        if not any(value.strip() for value in values): continue
        if len(values) > len(header) and any(value.strip() for value in values[len(header):]):
            sys.exit(f'CSV line {reader.line_num} has more fields than the header. Check CSV quoting before comparing.')
        row = dict(zip(header, values + [''] * max(0, len(header) - len(values))))
        source = get(row, 'src_subject_id')
        if source: nda_src_ids.add(source)
        paths = [get(row, field) for field in ('image_file', 'manifest', 'bvecfile', 'bvalfile')]
        file_subjects, file_sessions = tags(paths, 'sub'), tags(paths, 'ses')
        source_subjects = tags([source], 'sub')
        if not source_subjects and 'sub-' + source in raw_subjects: source_subjects = {'sub-' + source}
        all_subjects = file_subjects | source_subjects
        subject = unique(all_subjects)
        explicit_sessions = tags([get(row, field) for field in ('session_id', 'session', 'session_label', 'timepoint_label', 'visit')], 'ses')
        session = unique(file_sessions | explicit_sessions)
        basis = 'BIDS tags in file paths' if file_subjects and file_sessions else 'BIDS tags and source-ID/session fields'
        # Bare session_id/session values match literal raw labels only; visit numbering is never shifted.
        if not file_sessions and not explicit_sessions and subject:
            literal = {get(row, field) for field in ('session_id', 'session', 'session_label') if get(row, field)}
            candidates = {'ses-' + label for label in literal if (subject, 'ses-' + label) in raw_pairs}
            if len(candidates) == 1: session, basis = unique(candidates), 'literal session field matched to rawdata label'
        mod = modality(row)
        reasons = []
        if len(all_subjects) > 1: reasons.append('conflicting subject IDs')
        elif not subject: reasons.append('no identifiable original subject ID')
        if len(file_sessions | explicit_sessions) > 1: reasons.append('conflicting session IDs')
        elif not session: reasons.append('no identifiable original session label')
        if mod == 'UNKNOWN': reasons.append('unrecognized or ambiguous scan type')
        status = '; '.join(reasons) if reasons else ('excluded non-target scan type' if mod == 'OTHER' else 'resolved')
        record = {field: get(row, field) for field in map_fields}
        record.update(csv_line=reader.line_num, subject=subject, session=session, modality=mod, match_basis=basis, mapping_status=status)
        mapping_rows.append(record)
        if subject and session:
            nda_pairs.add((subject, session))
            if mod in mods: nda_counts[(subject, session, mod)] += 1
            if mod == 'BOLD': nda_bold[(subject, session)].append(functional_entities(get(row, 'image_file')))
        if reasons:
            unresolved.append(record)
            if mod != 'OTHER': uncertain.append((subject or None, session or None, mod if mod in mods else None))
        original = tuple(get(row, field) for field in ('visit', 'session_id', 'timepoint_label', 'visnum')) + (unique(file_sessions),)
        original_counts[original] += 1
        if source: original_subjects[original].add(source)

def needs_review(pair, mod=None):
    return any((s is None or s == pair[0]) and (v is None or v == pair[1]) and (mod is None or m is None or m == mod) for s, v, m in uncertain)
def write_csv(name, fields, rows):
    with (out / name).open('w', newline='', encoding='utf-8') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader(); writer.writerows(rows)

missing_mods, missing_sessions, comparison = [], [], []
for pair in sorted_pairs(raw_pairs | nda_pairs):
    base = dict(subject=pair[0], session=pair[1])
    missing = [m for m in mods if raw_files.get(pair + (m,)) and not nda_counts[pair + (m,)]]
    record = dict(base, in_rawdata=int(pair in raw_pairs), any_nda_row=int(pair in nda_pairs), missing_modalities=';'.join(missing))
    for mod in mods:
        key = pair + (mod,)
        record[f'raw_{mod}_files'], record[f'nda_{mod}_rows'] = len(raw_files.get(key, [])), nda_counts[key]
        if mod in missing:
            missing_mods.append(dict(base, modality=mod, raw_file_count=len(raw_files[key]), status='needs_review' if needs_review(pair, mod) else 'not_listed', raw_files=' | '.join(raw_files[key])))
    comparison.append(record)
    if pair in raw_pairs and pair not in nda_pairs and any(raw_files.get(pair + (m,)) for m in mods):
        missing_sessions.append(dict(base, status='needs_review' if needs_review(pair) else 'not_listed', raw_modalities=';'.join(m for m in mods if raw_files.get(pair + (m,)))))

by_session = []
for session in sorted({p[1] for p in raw_pairs | nda_pairs}, key=natural):
    for mod in mods:
        raw_keys = {k for k, files in raw_files.items() if k[1] == session and k[2] == mod and files}
        nda_keys = {k for k in nda_counts if k[1] == session and k[2] == mod and nda_counts[k]}
        by_session.append(dict(session=session, modality=mod, raw_files=sum(len(raw_files[k]) for k in raw_keys), raw_subject_sessions=len(raw_keys), nda_csv_rows=sum(nda_counts[k] for k in nda_keys), nda_identified_subject_sessions=len(nda_keys), matched_subject_sessions=len(raw_keys & nda_keys), raw_subject_sessions_not_matched=len(raw_keys - nda_keys)))
original_rows = [dict(zip(['visit', 'session_id', 'timepoint_label', 'visnum', 'file_session'], key), nda_csv_rows=original_counts[key], source_subject_ids=len(original_subjects[key])) for key in sorted(original_counts)]
functional_rows = []
for key, files in sorted(raw_files.items(), key=lambda item: tuple(natural(v) for v in item[0])):
    if key[2] != 'BOLD': continue
    pair = key[:2]
    for filename in files:
        entities = functional_entities(filename)
        possible = [e for e in nda_bold[pair] if not any(k in e and e[k] != v for k, v in entities.items())]
        listed = 'task' in entities and any(all(e.get(k) == v for k, v in entities.items()) for e in possible)
        status = 'listed' if listed else ('needs_review' if possible or needs_review(pair, 'BOLD') else 'not_listed')
        functional_rows.append(dict(subject=pair[0], session=pair[1], raw_file=filename, status=status, **{k: entities.get(k, '') for k in ('task', 'acq', 'dir', 'run', 'echo')}))

report_names = ['comparison_by_session.csv', 'missing_sessions_from_nda_csv.csv', 'missing_modalities_from_nda_csv.csv', 'nda_row_mapping.csv', 'unresolved_nda_rows.csv', 'counts_by_session.csv', 'nda_original_session_counts.csv', 'functional_run_comparison.csv', 'summary.txt']
if out.exists() and not out.is_dir(): sys.exit(f'Output path is not a directory: {out}')
if any((out / name).exists() for name in report_names): sys.exit(f'Reports already exist in {out}. Choose a new output directory.')
out.mkdir(parents=True, exist_ok=True)
write_csv('comparison_by_session.csv', ['subject', 'session', 'in_rawdata', 'any_nda_row'] + [field for mod in mods for field in (f'raw_{mod}_files', f'nda_{mod}_rows')] + ['missing_modalities'], comparison)
write_csv('missing_sessions_from_nda_csv.csv', ['subject', 'session', 'status', 'raw_modalities'], missing_sessions)
write_csv('missing_modalities_from_nda_csv.csv', ['subject', 'session', 'modality', 'raw_file_count', 'status', 'raw_files'], missing_mods)
write_csv('nda_row_mapping.csv', map_fields, mapping_rows)
write_csv('unresolved_nda_rows.csv', map_fields, unresolved)
write_csv('counts_by_session.csv', ['session', 'modality', 'raw_files', 'raw_subject_sessions', 'nda_csv_rows', 'nda_identified_subject_sessions', 'matched_subject_sessions', 'raw_subject_sessions_not_matched'], by_session)
write_csv('nda_original_session_counts.csv', ['visit', 'session_id', 'timepoint_label', 'visnum', 'file_session', 'nda_csv_rows', 'source_subject_ids'], original_rows)
write_csv('functional_run_comparison.csv', ['subject', 'session', 'task', 'acq', 'dir', 'run', 'echo', 'raw_file', 'status'], functional_rows)

lines = [f'Rawdata: {raw_root}', f'NDA CSV: {nda_csv}', f'Reports: {out}', '', f'Original rawdata subjects (sub-* directories): {len(raw_subjects)}', f'Original rawdata subject/session directories: {len(raw_pairs)}', f'Distinct src_subject_id values in NDA CSV: {len(nda_src_ids)}', f'Total NDA CSV data rows: {len(mapping_rows)}', f'NDA subjects with identifiable original IDs and sessions: {len({p[0] for p in nda_pairs})}', f'NDA identifiable subject/session pairs: {len(nda_pairs)}', f'NDA subject/session pairs not in current rawdata: {len(nda_pairs - raw_pairs)}', f'CSV rows requiring review: {len(unresolved)}', '', f'{"Modality":<12} {"Raw files":>10} {"Raw sessions":>13} {"CSV rows":>10} {"CSV sessions":>13} {"Not matched":>12}']
for mod in mods:
    rk = {k for k, files in raw_files.items() if k[2] == mod and files}
    nk = {k for k in nda_counts if k[2] == mod and nda_counts[k]}
    csv_mod_rows = sum(r['modality'] == mod for r in mapping_rows)
    lines.append(f'{mod:<12} {sum(len(raw_files[k]) for k in rk):>10} {len(rk):>13} {csv_mod_rows:>10} {len(nk):>13} {len(rk - nk):>12}')
lines += ['', 'Original rawdata session labels:', f'{"Session":<16} {"Raw subjects":>13} {"CSV subjects":>13} {"Not matched":>12}']
for session in sorted({p[1] for p in raw_pairs | nda_pairs}, key=natural):
    rp, np = {p for p in raw_pairs if p[1] == session}, {p for p in nda_pairs if p[1] == session}
    lines.append(f'{session:<16} {len(rp):>13} {len(np):>13} {len(rp - np):>12}')
eddy = sum(bool(files) for key, files in raw_files.items() if key[2] == 'DWI')
lines += ['', f'Expected eddy datasets (one per rawdata DWI session): {eddy}', f'Whole imaging sessions not listed in CSV: {sum(r["status"] == "not_listed" for r in missing_sessions)}', f'Whole imaging sessions needing mapping review: {sum(r["status"] == "needs_review" for r in missing_sessions)}', f'Modality/session datasets not listed in CSV: {sum(r["status"] == "not_listed" for r in missing_mods)}', f'Modality/session datasets needing mapping review: {sum(r["status"] == "needs_review" for r in missing_mods)}', f'Functional image files matched to CSV run labels: {sum(r["status"] == "listed" for r in functional_rows)}', f'Functional image files not listed in CSV: {sum(r["status"] == "not_listed" for r in functional_rows)}', f'Functional image files needing run-label review: {sum(r["status"] == "needs_review" for r in functional_rows)}', '', 'Coverage is checked by original subject, session, and modality; each DWI session counts once.', 'CSV rows are records, not necessarily individual raw images or functional runs.', 'Functional runs are compared using task/acq/dir/run/echo labels; absent labels are flagged for review.', 'The comparison checks CSV contents; NDA submission acceptance is not verified.', 'Review unresolved_nda_rows.csv before treating unconfirmed matches as missing.', 'Visit values such as Baseline or 0 are preserved; they are not assumed to mean ses-1.']
summary = '\n'.join(lines) + '\n'
(out / 'summary.txt').write_text(summary, encoding='utf-8')
print(summary)
PY

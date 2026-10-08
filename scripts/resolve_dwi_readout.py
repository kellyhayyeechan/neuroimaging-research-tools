#!/usr/bin/env python3
"""Resolve BIDS DWI TotalReadoutTime without modifying source JSON.

Priority: valid JSON sidecar > exact CSV scan > same-sub_site donors.
The sub_site fallback excludes EXCLUDED/blank groups, excluded donor rows,
and ambiguous (nonmatching) nonzero values. No global guessed fallback.
"""
import argparse
import csv
import json
import math
import os
import pathlib
import statistics
import sys
from collections import defaultdict

ALLOWED_DIFF = 1e-6


def valid(v):
    try:
        n = float(str(v).strip())
    except (TypeError, ValueError):
        return None
    return n if math.isfinite(n) and 0 < n < 2 else None


def normal(v):
    return str(v or '').strip()


def format_value(x):
    return format(x, '.12g')


def resolve(metadata_path, json_path, subject, session):
    with open(json_path, encoding='utf-8') as f:
        js = json.load(f)
    if not isinstance(js, dict):
        raise ValueError(f'Not a JSON object: {json_path}')
    json_trt = valid(js.get('TotalReadoutTime'))
    ped = normal(js.get('PhaseEncodingDirection'))
    if ped not in {'i','i-','j','j-','k','k-'}:
        raise ValueError(f'Missing/invalid PhaseEncodingDirection in {json_path}: {ped!r}')
    basename = pathlib.Path(json_path).name
    with open(metadata_path, newline='', encoding='utf-8-sig') as f:
        rr = csv.DictReader(f)
        required = {'subject','session','file','sub_site','TotalReadoutTime'}
        if not required.issubset(rr.fieldnames or []):
            raise ValueError(f'CSV missing columns: {sorted(required-set(rr.fieldnames or []))}')
        records = list(rr)
    subject_records = [r for r in records if normal(r['subject']) == subject and normal(r['session']) == session]
    file_records = [r for r in subject_records if pathlib.Path(normal(r['file'])).name == basename]

    # Never use the value from another run in the same subject as an exact match.
    direct = [valid(r['TotalReadoutTime']) for r in file_records]
    direct = [v for v in direct if v is not None]
    if len(direct) > 1 and max(direct)-min(direct) > ALLOWED_DIFF:
        raise ValueError(f'Conflicting CSV scan readout times for {subject} {session} {basename}: {direct}')
    scan_value = statistics.median(direct) if direct else None

    sites = {normal(r['sub_site']) for r in (file_records or subject_records) if normal(r['sub_site'])}
    if len(sites) > 1:
        raise ValueError(f'Ambiguous sub_site for {subject} {session}: {sorted(sites)}')
    subsite = next(iter(sites), '')

    if json_trt is not None:
        if scan_value is not None and abs(json_trt-scan_value) > ALLOWED_DIFF:
            print(f'[READOUT WARNING] JSON={format_value(json_trt)} differs from exact CSV scan={format_value(scan_value)} for {subject} {session} {basename}; using JSON', file=sys.stderr)
        return json_trt, 'JSON', subsite or 'UNKNOWN', 0, ped
    if scan_value is not None:
        return scan_value, 'CSV_EXACT_SCAN', subsite or 'UNKNOWN', len(direct), ped

    if not subsite or subsite.casefold() in {'excluded','unknown','nan','none','n/a','na'}:
        raise ValueError(f'No measured readout for {subject} {session} {basename} and no usable sub_site (found {subsite!r})')

    donors = []
    for row in records:
        if normal(row.get('sub_site')) != subsite:
            continue
        # Excluded rows are not donor observations (they may use other protocols).
        if normal(row.get('EXCLUDED (X)')).casefold() in {'x','1','yes','true'}:
            continue
        if normal(row.get('QC_exclusion')).casefold() in {'x','1','yes','true'}:
            continue
        v = valid(row.get('TotalReadoutTime'))
        if v is not None:
            donors.append(v)
    if not donors:
        raise ValueError(f'No valid donor readout values in sub_site={subsite} for {subject} {session} {basename}')
    if max(donors)-min(donors) > ALLOWED_DIFF:
        unique = sorted(set(round(n, 9) for n in donors))
        raise ValueError(f'Ambiguous readout times in sub_site={subsite}: {unique}. Refusing to guess.')
    return statistics.median(donors), 'CSV_SUBSITE_INFERRED', subsite, len(donors), ped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', default=os.environ.get('DWI_METADATA_CSV', '/example/combined_dwi_subsite_metadata.csv'))
    parser.add_argument('--json', required=True)
    parser.add_argument('--subject', required=True)
    parser.add_argument('--session', required=True)
    parser.add_argument('--header', action='store_true')
    args = parser.parse_args()
    try:
        result = resolve(args.metadata, args.json, args.subject, args.session)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f'[READOUT ERROR] {e}', file=sys.stderr)
        return 2
    if args.header:
        print('readout_seconds\tsource\tsub_site\tdonor_count\tphase_encoding_direction')
    print('\t'.join([format_value(result[0]), result[1], result[2], str(result[3]), result[4]]))
    return 0

if __name__ == '__main__':
    sys.exit(main())

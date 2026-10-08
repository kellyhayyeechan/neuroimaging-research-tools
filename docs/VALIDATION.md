# Validation

Ten behavioral checks passed during preparation: BIDS session counting; NDA missing-session detection; six readout-priority/ambiguity/exclusion/source-preservation checks; paired QC metrics; and longitudinal scan/group/time/contrast-width consistency for both five- and six-column designs. Python and Bash source syntax checks passed.

Three synthetic workflows and a standalone readout example were executed in the earlier preparation, and their actual sample outputs are included. R fitting and FreeSurfer processing remain unexecuted here. GitHub-hosted checks have not run until this repository is uploaded.

The synthetic demos use invented IDs and data. Empty NIfTI placeholders establish discovery behavior only. No processing-performance, statistical-validity, or clinical-accuracy claim is made from these checks.

## Behavioral test output

```text
test_counts_dwi_once_per_session (test_bids.OperationsTests.test_counts_dwi_once_per_session) ... ok
test_nda_preserves_session_and_reports_absence (test_bids.OperationsTests.test_nda_preserves_session_and_reports_absence) ... ok
test_rows_groups_time_and_contrast_width (test_design.DesignTests.test_rows_groups_time_and_contrast_width) ... ok
test_paired_metrics_preserve_subject_session_and_values (test_qc.QCTests.test_paired_metrics_preserve_subject_session_and_values) ... ok
test_conflicting_donors_fail (test_readout.ReadoutTests.test_conflicting_donors_fail) ... ok
test_exact_scan_precedes_subsite (test_readout.ReadoutTests.test_exact_scan_precedes_subsite) ... ok
test_excluded_donors_do_not_supply_readout (test_readout.ReadoutTests.test_excluded_donors_do_not_supply_readout) ... ok
test_json_precedes_scan_csv (test_readout.ReadoutTests.test_json_precedes_scan_csv) ... ok
test_missing_direction_fails (test_readout.ReadoutTests.test_missing_direction_fails) ... ok
test_same_site_fallback_preserves_json (test_readout.ReadoutTests.test_same_site_fallback_preserves_json) ... ok

----------------------------------------------------------------------
Ran 10 tests in 0.149s

OK
```

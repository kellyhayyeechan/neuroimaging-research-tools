# Synthetic demonstration. Run from the repository root after installing dependencies.
# This script is prepared but was not executed during portfolio preparation.
source("dependencies.R")
source("scripts/roi_lmer_functions.R")
set.seed(42)
subjects <- sprintf("demo%02d", 1:30)
df <- tidyr::expand_grid(subject = subjects, ses = c("ses-1", "ses-2", "ses-3"), StructName = c("ROI_A", "ROI_B"))
subject_effect <- setNames(rnorm(30, 0, 2), subjects)
df <- dplyr::mutate(df, age = 25 + match(subject, subjects), sex = factor(ifelse(match(subject, subjects) %% 2, "F", "M")), Volume_mm3 = 100 + 2 * match(ses, c("ses-1", "ses-2", "ses-3")) + subject_effect[subject] + rnorm(nrow(df)))
fit <- run_roi_lmer_pipeline(df, outcome_col = "Volume_mm3", x_col = "ses", covars = c("age", "sex"), x_levels = c("ses-1", "ses-2", "ses-3"), filter_sig = FALSE)
print(fit$summary)
stopifnot(length(fit$fit$models) == 2)

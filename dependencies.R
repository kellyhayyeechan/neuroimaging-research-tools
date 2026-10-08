pkgs <- c("dplyr", "tidyr", "readr", "stringr", "purrr", "tibble", "broom", "broom.mixed", "lme4", "lmerTest", "emmeans", "readxl", "lubridate")
missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Install packages first: ", paste(missing, collapse = ", "))
invisible(lapply(pkgs, library, character.only = TRUE))

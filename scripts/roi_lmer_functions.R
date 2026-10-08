# Extracted reusable definitions from the 2026-09-16 revised R Markdown.
# Load dependencies.R before use. No cohort data or analysis calls are included.
`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || all(is.na(x))) y else x
}

fmt_name <- function(x) {
  ok <- grepl("^[A-Za-z.][A-Za-z0-9._]*$", x)
  ifelse(ok, x, paste0("`", x, "`"))
}

make_lmer_spec <- function(
  covars = c("age", "sex"),
  fixed_rhs = "{x} + {covars}",
  random_rhs = "(1|{subject})"
) {
  list(
    covars = unique(covars),
    fixed_rhs = fixed_rhs,
    random_rhs = random_rhs
  )
}

resolve_model_terms <- function(spec, x_model_col, subject_col, covars_model) {
  covar_term <- if (length(covars_model)) {
    paste(fmt_name(covars_model), collapse = " + ")
  } else {
    "1"
  }

  fixed_rhs  <- spec$fixed_rhs  %||% "{x} + {covars}"
  random_rhs <- spec$random_rhs %||% "(1|{subject})"

  fixed_rhs  <- gsub("\\{x\\}",       fmt_name(x_model_col),   fixed_rhs)
  fixed_rhs  <- gsub("\\{subject\\}", fmt_name(subject_col),   fixed_rhs)
  fixed_rhs  <- gsub("\\{covars\\}",  covar_term,              fixed_rhs)

  random_rhs <- gsub("\\{x\\}",       fmt_name(x_model_col),   random_rhs)
  random_rhs <- gsub("\\{subject\\}", fmt_name(subject_col),   random_rhs)
  random_rhs <- gsub("\\{covars\\}",  covar_term,              random_rhs)

  list(
    fixed_rhs = fixed_rhs,
    random_rhs = random_rhs
  )
}

compute_scale_map <- function(df, vars, index_cols, scale_suffix = "_z") {
  vars <- unique(vars)
  if (!length(vars)) return(list())

  base_idx <- !duplicated(df[index_cols])
  base_df  <- df[base_idx, unique(c(index_cols, vars)), drop = FALSE]

  out <- list()

  for (v in vars) {
    x <- base_df[[v]]

    if (!(is.numeric(x) || is.integer(x))) next

    x_nonmiss <- x[!is.na(x)]
    n_uniq <- length(unique(x_nonmiss))
    if (n_uniq <= 2L) next

    mu  <- mean(x_nonmiss)
    sdv <- stats::sd(x_nonmiss)

    if (is.finite(mu) && is.finite(sdv) && sdv > 0) {
      out[[v]] <- list(
        mu  = mu,
        sd  = sdv,
        new = paste0(v, scale_suffix)
      )
    }
  }

  out
}

add_scaled_vars <- function(df, scale_map) {
  if (!length(scale_map)) return(df)

  for (nm in names(scale_map)) {
    df[[scale_map[[nm]]$new]] <- (df[[nm]] - scale_map[[nm]]$mu) / scale_map[[nm]]$sd
  }

  df
}

nonfinite_mask <- function(x) {
  if (is.numeric(x) || is.integer(x)) {
    !is.finite(x)
  } else {
    rep(FALSE, length(x))
  }
}

run_roi_lmers_fast <- function(
  df,
  outcome_col,
  x_col,
  roi_col = "StructName",
  subject_col = "subject",
  roi_vec = NULL,
  model_spec = NULL,
  x_levels = NULL,
  x_labels = NULL,
  scale_covars = TRUE,
  scale_vars = NULL,
  scale_x = FALSE,
  scale_suffix = "_z",
  scale_outcome = TRUE,
  outcome_scale_suffix = "_z",
  min_rows = 5,
  REML = FALSE,
  verbose = TRUE
) {
  stopifnot(is.data.frame(df))
  stopifnot(requireNamespace("lmerTest", quietly = TRUE))
  stopifnot(requireNamespace("broom.mixed", quietly = TRUE))

  required_cols <- c(roi_col, subject_col, x_col, outcome_col)
  missing_required <- setdiff(required_cols, names(df))
  if (length(missing_required)) {
    stop("Missing required columns in df: ", paste(missing_required, collapse = ", "))
  }

  if (!is.null(x_levels) || !is.null(x_labels)) {
    if (is.null(x_levels) || is.null(x_labels)) {
      stop("If relabeling x, both x_levels and x_labels must be supplied.")
    }
    if (length(x_levels) != length(x_labels)) {
      stop("x_levels and x_labels must have the same length.")
    }
  }

  if (is.null(model_spec)) {
    model_spec <- make_lmer_spec(
      covars = c("age", "sex"),
      fixed_rhs = "{x} + {covars}",
      random_rhs = "(1|{subject})"
    )
  }

  covars_use <- unique(model_spec$covars %||% character())
  missing_covars <- setdiff(covars_use, names(df))
  if (length(missing_covars)) {
    stop("These covariates are not in df: ", paste(missing_covars, collapse = ", "))
  }

  df_work <- df

  if (!is.null(x_levels)) {
    df_work[[x_col]] <- factor(df_work[[x_col]], levels = x_levels, labels = x_labels)
  }

  covars_model <- covars_use
  scaled_map_covars <- list()
  scaled_map_x <- list()
  x_model_col <- x_col

  vars_to_scale <- character(0)
  if (isTRUE(scale_covars)) {
    if (is.null(scale_vars)) {
      vars_to_scale <- covars_use
    } else {
      vars_to_scale <- unique(scale_vars)
      bad_scale_vars <- setdiff(vars_to_scale, covars_use)
      if (length(bad_scale_vars)) {
        stop(
          "scale_vars must be a subset of model_spec$covars. Problem variables: ",
          paste(bad_scale_vars, collapse = ", ")
        )
      }
    }
  }

  if (length(vars_to_scale)) {
    scaled_map_covars <- compute_scale_map(
      df = df_work,
      vars = vars_to_scale,
      index_cols = c(subject_col, x_col),
      scale_suffix = scale_suffix
    )

    df_work <- add_scaled_vars(df_work, scaled_map_covars)

    for (nm in names(scaled_map_covars)) {
      covars_model[covars_model == nm] <- scaled_map_covars[[nm]]$new
    }
  }

  if (isTRUE(scale_x)) {
    scaled_map_x <- compute_scale_map(
      df = df_work,
      vars = x_col,
      index_cols = c(subject_col, x_col),
      scale_suffix = scale_suffix
    )

    if (length(scaled_map_x) && x_col %in% names(scaled_map_x)) {
      df_work <- add_scaled_vars(df_work, scaled_map_x)
      x_model_col <- scaled_map_x[[x_col]]$new
    } else if (verbose) {
      message("x_col was not scaled. It may be non-numeric or have insufficient variance.")
    }
  }

  outcome_model_nm <- if (scale_outcome) paste0(outcome_col, outcome_scale_suffix) else outcome_col

  resolved <- resolve_model_terms(
    spec = model_spec,
    x_model_col = x_model_col,
    subject_col = subject_col,
    covars_model = covars_model
  )

  form_str <- paste(fmt_name(outcome_model_nm), "~", resolved$fixed_rhs, "+", resolved$random_rhs)
  form     <- stats::as.formula(form_str)

  predictor_vars <- unique(
    all.vars(stats::as.formula(paste("~", resolved$fixed_rhs, "+", resolved$random_rhs)))
  )

  missing_model_vars <- setdiff(predictor_vars, names(df_work))
  if (length(missing_model_vars)) {
    stop(
      "These variables are referenced by the final model but are not in df: ",
      paste(missing_model_vars, collapse = ", ")
    )
  }

  roi_ids <- roi_vec %||% unique(df_work[[roi_col]])
  roi_ids <- as.character(roi_ids)
  idx_by_roi <- split(seq_len(nrow(df_work)), as.character(df_work[[roi_col]]))

  fit_one_roi <- function(r) {
    idx <- idx_by_roi[[r]]
    if (is.null(idx)) return(NULL)

    dat <- df_work[idx, , drop = FALSE]

    needed <- unique(c(subject_col, x_model_col, outcome_col, predictor_vars))
    needed <- needed[needed %in% names(dat)]

    keep <- stats::complete.cases(dat[, needed, drop = FALSE])

    for (nm in needed) {
      keep <- keep & !nonfinite_mask(dat[[nm]])
    }

    dat <- dat[keep, , drop = FALSE]

    if (nrow(dat) < min_rows) {
      if (verbose) message("Skipping ROI=", r, " (n=", nrow(dat), " < ", min_rows, ")")
      return(NULL)
    }

    y_mu <- NA_real_
    y_sd <- NA_real_
    y_scaled_ok <- FALSE

    if (scale_outcome) {
      y <- dat[[outcome_col]]

      if ((is.numeric(y) || is.integer(y)) && length(unique(y[!is.na(y)])) > 2L) {
        y_mu <- mean(y, na.rm = TRUE)
        y_sd <- stats::sd(y, na.rm = TRUE)

        if (is.finite(y_mu) && is.finite(y_sd) && y_sd > 0) {
          dat[[outcome_model_nm]] <- (y - y_mu) / y_sd
          y_scaled_ok <- TRUE
        } else {
          dat[[outcome_model_nm]] <- y
        }
      } else {
        dat[[outcome_model_nm]] <- y
      }
    } else {
      dat[[outcome_model_nm]] <- dat[[outcome_col]]
    }

    keep_y <- !is.na(dat[[outcome_model_nm]])
    if (is.numeric(dat[[outcome_model_nm]]) || is.integer(dat[[outcome_model_nm]])) {
      keep_y <- keep_y & is.finite(dat[[outcome_model_nm]])
    }

    dat <- dat[keep_y, , drop = FALSE]

    if (nrow(dat) < min_rows) {
      if (verbose) message("Skipping ROI=", r, " after outcome filtering (n=", nrow(dat), ")")
      return(NULL)
    }

    n_subj <- dplyr::n_distinct(dat[[subject_col]])

    if (verbose) {
      message("------------------------------------------------------------")
      message("ROI: ", r)
      message("Formula: ", form_str)
      message("n = ", nrow(dat), "; n_subject = ", n_subj)
    }

    model <- lmerTest::lmer(form, data = dat, REML = REML)

    tidy_fix <- broom.mixed::tidy(model, effects = "fixed")
    tidy_fix$StructName <- r

    info <- data.frame(
      StructName       = r,
      n                = nrow(dat),
      n_subject        = n_subj,
      x_in_model       = x_model_col,
      outcome_in_model = outcome_model_nm,
      outcome_scaled   = scale_outcome && y_scaled_ok,
      outcome_mu       = y_mu,
      outcome_sd       = y_sd,
      AIC              = stats::AIC(model),
      BIC              = stats::BIC(model),
      logLik           = as.numeric(stats::logLik(model)),
      stringsAsFactors = FALSE
    )

    list(
      model = model,
      tidy  = tidy_fix,
      info  = info
    )
  }

  fits <- lapply(roi_ids, fit_one_roi)
  names(fits) <- roi_ids
  fits <- Filter(Negate(is.null), fits)

  if (!length(fits)) {
    return(list(
      formula = form,
      formula_str = form_str,
      model_spec = model_spec,
      resolved_model = resolved,
      scaled_covars = scaled_map_covars,
      scaled_x = scaled_map_x,
      outcome_scaled = scale_outcome,
      results = data.frame(),
      info = data.frame(),
      models = list()
    ))
  }

  tidy_all <- dplyr::bind_rows(lapply(fits, `[[`, "tidy"))
  info_all <- dplyr::bind_rows(lapply(fits, `[[`, "info"))

  model_list <- lapply(fits, `[[`, "model")
  names(model_list) <- names(fits)

  list(
    formula = form,
    formula_str = form_str,
    model_spec = model_spec,
    resolved_model = resolved,
    scaled_covars = scaled_map_covars,
    scaled_x = scaled_map_x,
    outcome_scaled = scale_outcome,
    results = tidy_all,
    info = info_all,
    models = model_list
  )
}

summarize_roi_lmers <- function(
  models,
  alpha = 0.05,
  adjust_method = "fdr",
  adjust_by = c("term", "all"),
  effect_size = c("partial_r", "std_beta", "none"),
  drop_intercept = TRUE,
  x_var = NULL,
  add_x_contrasts = TRUE,
  x_contrast_adjust = "tukey",
  emmeans_df = c("satterthwaite", "kenward-roger", "asymptotic"),
  across_correction = c("roi_fdr", "global_fdr_x_contrasts", "global_fdr_all_tests"),
  global_fdr_p_source = c("p_raw", "p_within"),
  conf_level = 0.95,
  fixed_ci_method = c("profile", "wald", "none"),
  x_contrast_ci = c("wald", "none"),
  profile_fallback = c("wald", "none"),
  profile_oldNames = FALSE,
  profile_quiet = TRUE
) {
  stopifnot(requireNamespace("dplyr", quietly = TRUE))
  stopifnot(requireNamespace("broom.mixed", quietly = TRUE))
  stopifnot(requireNamespace("lme4", quietly = TRUE))
  if (isTRUE(add_x_contrasts)) stopifnot(requireNamespace("emmeans", quietly = TRUE))

  adjust_by           <- match.arg(adjust_by)
  effect_size         <- match.arg(effect_size)
  emmeans_df          <- match.arg(emmeans_df)
  across_correction   <- match.arg(across_correction)
  global_fdr_p_source <- match.arg(global_fdr_p_source)
  fixed_ci_method     <- match.arg(fixed_ci_method)
  x_contrast_ci       <- match.arg(x_contrast_ci)
  profile_fallback    <- match.arg(profile_fallback)

  get_grouping <- function(m) {
    fl <- tryCatch(lme4::getME(m, "flist"), error = function(e) NULL)
    if (!is.null(fl) && length(fl) >= 1) return(names(fl)[1])
    "subject"
  }

  get_fixed_ci_tbl <- function(m, level, method = "profile",
                               fallback = "wald",
                               oldNames = FALSE,
                               quiet = TRUE) {
    if (method == "none") return(NULL)

    do_confint <- function(method_name) {
      expr <- quote(
        suppressMessages(
          suppressWarnings(
            as.data.frame(stats::confint(
              object = m,
              parm = "beta_",
              level = level,
              method = method_name,
              oldNames = oldNames
            ))
          )
        )
      )

      if (!quiet) {
        expr <- quote(
          as.data.frame(stats::confint(
            object = m,
            parm = "beta_",
            level = level,
            method = method_name,
            oldNames = oldNames
          ))
        )
      }

      eval(expr)
    }

    ci_df <- tryCatch(do_confint(method), error = function(e) NULL)
    ci_method_used <- method

    if (is.null(ci_df) && method == "profile" && fallback == "wald") {
      ci_df <- tryCatch(do_confint("Wald"), error = function(e) NULL)
      ci_method_used <- "wald_fallback"
    }

    if (is.null(ci_df)) return(NULL)

    ci_df$term <- rownames(ci_df)
    rownames(ci_df) <- NULL
    names(ci_df)[1:2] <- c("conf.low", "conf.high")
    ci_df$ci_method <- ci_method_used
    ci_df
  }

  add_effect_cols <- function(td, y_sd = NA_real_, x_sds = NULL) {
    td %>%
      dplyr::mutate(
        beta = .data$estimate,
        partial_r = dplyr::if_else(
          is.finite(.data$statistic) & is.finite(.data$df),
          sign(.data$statistic) * sqrt((.data$statistic^2) / (.data$statistic^2 + .data$df)),
          NA_real_
        ),
        beta_std = dplyr::case_when(
          .data$component == "fixed" &
            is.finite(y_sd) & y_sd > 0 &
            !is.null(x_sds) & .data$term %in% names(x_sds) &
            .data$term != "(Intercept)" ~
              .data$estimate * unname(x_sds[.data$term]) / y_sd,

          .data$component == "x_contrast" &
            is.finite(y_sd) & y_sd > 0 ~
              .data$estimate / y_sd,

          TRUE ~ NA_real_
        ),
        beta_std_type = dplyr::case_when(
          .data$component == "fixed" & !is.na(.data$beta_std) ~ "beta*SD(x)/SD(y)",
          .data$component == "x_contrast" & !is.na(.data$beta_std) ~ "delta/SD(y)",
          TRUE ~ NA_character_
        ),
        effect = dplyr::case_when(
          effect_size == "partial_r" ~ .data$partial_r,
          effect_size == "std_beta"  ~ .data$beta_std,
          TRUE ~ NA_real_
        ),
        effect_type = dplyr::case_when(
          effect_size == "partial_r" ~ "partial_r",
          effect_size == "std_beta"  ~ "std_beta",
          TRUE ~ "none"
        )
      )
  }

  res <- dplyr::bind_rows(lapply(seq_along(models), function(i) {
    m <- models[[i]]
    if (is.null(m)) return(NULL)

    roi_nm <- names(models)[i] %||% paste0("ROI_", i)
    mf <- tryCatch(stats::model.frame(m), error = function(e) NULL)

    grp <- get_grouping(m)
    n_subj <- NA_integer_
    if (!is.null(mf) && grp %in% names(mf)) n_subj <- dplyr::n_distinct(mf[[grp]])

    y_sd <- NA_real_
    if (!is.null(mf)) {
      y <- tryCatch(stats::model.response(mf), error = function(e) NULL)
      if (!is.null(y)) y_sd <- stats::sd(y, na.rm = TRUE)
    }

    x_sds <- tryCatch({
      X <- lme4::getME(m, "X")
      stats::setNames(apply(X, 2, stats::sd), colnames(X))
    }, error = function(e) NULL)

    fixed_td <- broom.mixed::tidy(m, effects = "fixed") %>%
      dplyr::mutate(
        StructName = roi_nm,
        n = stats::nobs(m),
        n_subject = n_subj,
        component = "fixed",
        contrast = NA_character_,
        p_raw = .data$p.value,
        p_within = .data$p.value,
        within_method = "none",
        ci_level = conf_level
      )

    fixed_ci <- get_fixed_ci_tbl(
      m = m,
      level = conf_level,
      method = fixed_ci_method,
      fallback = profile_fallback,
      oldNames = profile_oldNames,
      quiet = profile_quiet
    )

    if (!is.null(fixed_ci)) {
      fixed_td <- fixed_td %>%
        dplyr::left_join(
          fixed_ci[, c("term", "conf.low", "conf.high", "ci_method")],
          by = "term"
        )
    } else {
      fixed_td <- fixed_td %>%
        dplyr::mutate(
          conf.low = NA_real_,
          conf.high = NA_real_,
          ci_method = NA_character_
        )
    }

    fixed_td <- fixed_td %>% add_effect_cols(y_sd = y_sd, x_sds = x_sds)

    contr_td <- NULL

    if (isTRUE(add_x_contrasts) && !is.null(x_var) && !is.null(mf) && x_var %in% names(mf)) {
      x_is_categorical <- is.factor(mf[[x_var]]) || is.character(mf[[x_var]])

      if (x_is_categorical) {
        contr_td <- tryCatch({
          emm <- emmeans::emmeans(
            m,
            specs = stats::as.formula(paste0("~", fmt_name(x_var))),
            lmer.df = emmeans_df
          )

          pw_raw <- as.data.frame(
            summary(
              emmeans::contrast(emm, method = "revpairwise", adjust = "none"),
              infer = c(TRUE, TRUE),
              level = conf_level
            )
          ) %>%
            dplyr::transmute(
              contrast = .data$contrast,
              p_raw = .data$p.value
            )

          pw_adj <- as.data.frame(
            summary(
              emmeans::contrast(emm, method = "revpairwise", adjust = x_contrast_adjust),
              infer = c(TRUE, TRUE),
              level = conf_level
            )
          )

          out <- pw_adj %>%
            dplyr::left_join(pw_raw, by = "contrast") %>%
            dplyr::transmute(
              term = paste0(x_var, "_", gsub(" - ", "_vs_", .data$contrast)),
              StructName = roi_nm,
              contrast = .data$contrast,
              estimate = .data$estimate,
              std.error = .data$SE,
              df = .data$df,
              statistic = .data$t.ratio,
              p.value = .data$p.value,
              p_raw = .data$p_raw,
              p_within = .data$p.value,
              within_method = x_contrast_adjust,
              n = stats::nobs(m),
              n_subject = n_subj,
              component = "x_contrast",
              conf.low = if ("lower.CL" %in% names(.)) .data$lower.CL else NA_real_,
              conf.high = if ("upper.CL" %in% names(.)) .data$upper.CL else NA_real_,
              ci_method = if (x_contrast_ci == "wald") "wald_emmeans" else NA_character_,
              ci_level = conf_level
            )

          if (x_contrast_ci == "none") {
            out$conf.low <- NA_real_
            out$conf.high <- NA_real_
            out$ci_method <- NA_character_
          }

          out %>% add_effect_cols(y_sd = y_sd, x_sds = x_sds)
        }, error = function(e) NULL)
      }
    }

    dplyr::bind_rows(fixed_td, contr_td)
  }))

  if (drop_intercept) {
    res <- res %>% dplyr::filter(.data$term != "(Intercept)")
  }

  res <- res %>%
    dplyr::mutate(
      sig_within = !is.na(.data$p_within) & (.data$p_within < alpha),
      p_adj = NA_real_,
      sig_adj = FALSE
    )

  apply_adj_subset <- function(df, idx, pvec) {
    out <- df
    out$p_adj[idx] <- stats::p.adjust(pvec, method = adjust_method)
    out$sig_adj[idx] <- !is.na(out$p_adj[idx]) & (out$p_adj[idx] < alpha)
    out
  }

  if (across_correction == "roi_fdr") {
    if (adjust_by == "term") {
      res <- res %>%
        dplyr::group_by(.data$term) %>%
        dplyr::mutate(
          p_adj = stats::p.adjust(.data$p_within, method = adjust_method),
          sig_adj = !is.na(.data$p_adj) & (.data$p_adj < alpha)
        ) %>%
        dplyr::ungroup()
    } else {
      res <- res %>%
        dplyr::mutate(
          p_adj = stats::p.adjust(.data$p_within, method = adjust_method),
          sig_adj = !is.na(.data$p_adj) & (.data$p_adj < alpha)
        )
    }

  } else if (across_correction == "global_fdr_x_contrasts") {
    fixed_idx <- which(res$component == "fixed" & !is.na(res$p_within))

    if (length(fixed_idx)) {
      if (adjust_by == "term") {
        res <- res %>%
          dplyr::group_by(.data$term) %>%
          dplyr::mutate(
            p_adj = dplyr::if_else(
              .data$component == "fixed",
              stats::p.adjust(.data$p_within, method = adjust_method),
              .data$p_adj
            ),
            sig_adj = dplyr::if_else(
              .data$component == "fixed",
              !is.na(.data$p_adj) & (.data$p_adj < alpha),
              .data$sig_adj
            )
          ) %>%
          dplyr::ungroup()
      } else {
        res <- apply_adj_subset(res, fixed_idx, res$p_within[fixed_idx])
      }
    }

    xc_idx <- which(res$component == "x_contrast")
    if (length(xc_idx)) {
      p_src <- if (global_fdr_p_source == "p_raw") res$p_raw else res$p_within
      ok <- xc_idx[!is.na(p_src[xc_idx])]
      if (length(ok)) res <- apply_adj_subset(res, ok, p_src[ok])
    }

  } else if (across_correction == "global_fdr_all_tests") {
    p_src <- if (global_fdr_p_source == "p_raw") res$p_raw else res$p_within
    idx <- which(!is.na(p_src))
    if (length(idx)) res <- apply_adj_subset(res, idx, p_src[idx])
  }

  front <- c(
    "StructName",
    "term",
    "component",
    "contrast",
    "within_method",
    "ci_method",
    "ci_level",
    "sig_within",
    "sig_adj",
    "p_within",
    "p_adj",
    "p_raw"
  )

  stats_cols <- c(
    "estimate", "beta", "beta_std", "beta_std_type",
    "partial_r", "effect", "effect_type",
    "std.error", "df", "statistic", "p.value",
    "conf.low", "conf.high",
    "n", "n_subject"
  )

  res %>%
    dplyr::select(dplyr::any_of(c(front, stats_cols)), dplyr::everything())
}

run_roi_lmer_pipeline <- function(
  df,
  outcome_col = "Volume_mm3",
  x_col = "ses",
  roi_col = "StructName",
  subject_col = "subject",
  roi_vec = NULL,

  covars = c("age", "sex", "eTIV", "BMI_baseline"),
  fixed_rhs = "{x} + {covars}",
  random_rhs = "(1|{subject})",

  x_levels = c("ses-1", "ses-2", "ses-3"),
  x_labels = c("1", "2", "3"),

  scale_covars = TRUE,
  scale_vars = c("age", "eTIV", "BMI_baseline"),
  scale_x = FALSE,
  scale_outcome = TRUE,

  min_rows = 5,
  REML = FALSE,
  verbose = TRUE,

  alpha = 0.05,
  add_x_contrasts = TRUE,
  x_contrast_adjust = "tukey",
  fixed_ci_method = "profile",
  profile_fallback = "wald",
  effect_size = "partial_r",
  adjust_method = "fdr",
  adjust_by = "term",

  filter_component = "x_contrast",
  filter_sig = TRUE
) {
  stopifnot(is.data.frame(df))

  spec <- make_lmer_spec(
    covars = covars,
    fixed_rhs = fixed_rhs,
    random_rhs = random_rhs
  )

  fit_out <- run_roi_lmers_fast(
    df = df,
    outcome_col = outcome_col,
    x_col = x_col,
    roi_col = roi_col,
    subject_col = subject_col,
    roi_vec = roi_vec,
    model_spec = spec,
    x_levels = x_levels,
    x_labels = x_labels,
    scale_covars = scale_covars,
    scale_vars = scale_vars,
    scale_x = scale_x,
    scale_outcome = scale_outcome,
    min_rows = min_rows,
    REML = REML,
    verbose = verbose
  )

  sum_out <- summarize_roi_lmers(
    models = fit_out$models,
    alpha = alpha,
    x_var = x_col,
    add_x_contrasts = add_x_contrasts,
    x_contrast_adjust = x_contrast_adjust,
    fixed_ci_method = fixed_ci_method,
    profile_fallback = profile_fallback,
    effect_size = effect_size,
    adjust_method = adjust_method,
    adjust_by = adjust_by
  )

  filtered_results <- sum_out

  if (!is.null(filter_component)) {
    filtered_results <- filtered_results %>%
      dplyr::filter(.data$component == filter_component)
  }

  if (isTRUE(filter_sig)) {
    filtered_results <- filtered_results %>%
      dplyr::filter(.data$sig_adj)
  }

  list(
    spec = spec,
    fit = fit_out,
    summary = sum_out,
    results = filtered_results
  )
}

# =====================================================================================
# EC4333 group project -- Are US REITs bond proxies?
# Replication and extension of Giliberto & Shulman (rev. 8.17.2016),
# "On the Interest Rate Sensitivity of REITs: Evidence from Twenty Years of Daily Data".
#
# HOW TO RUN (RStudio): edit the SETTINGS block, then Source the whole file.
# From a terminal:  Rscript replicate_gs.R --data=4333_DATA.xlsx --out=results
#                     --reit_sheet="MSCI US REIT TR" --baa_sheet=DBAA
#
# What it does
#   1. Loads daily series: MSCI US REIT total-return index (paper's "RMS"), S&P 500 price
#      index, 10Y Treasury CMT yield (FRED DGS10), Moody's Baa yield (FRED DBAA);
#      optionally the MSCI US REIT price-only index.  Nothing is filled or imputed.
#   2. Builds the paper's imputed bond returns (Section III): par bond priced at 100 with
#      coupon = previous day's yield, re-priced at today's yield with exactly 10 years left,
#      semi-annual coupons.  Same for Baa.  Excess credit return = Baa - Treasury return.
#   3. Replicates Exhibits 4-8 on the overlap with the paper (ends 30 Mar 2016), compares
#      with the paper's published numbers, then extends to the end of the data.
#   4. Robustness: HC3 and Newey-West SEs, lagged dependent variable (paper fn 11), price vs
#      total return (fn 6), alternative alignment of return intervals (fn 9), weekly data,
#      and Fed-policy sub-periods for the extension.
#   5. Investor implications: % return per +100bp in the 10Y yield, by period.
#   6. Writes CSVs, three PNG charts and one Excel workbook.
#
# UNITS (as in the paper): returns are DECIMALS (0.01 = 1%); yield changes are in
# PERCENTAGE POINTS (0.01 = 1bp).  A coefficient of -0.081 on dYield = -8.1% per +100bp.
# Intercepts in the sub-period tables are reported x1000, as in the paper.
#
# Packages: readxl, openxlsx, ggplot2, sandwich, jsonlite
#   install.packages(c("readxl", "openxlsx", "ggplot2", "sandwich", "jsonlite"))
# =====================================================================================

suppressPackageStartupMessages({
  library(readxl); library(openxlsx); library(ggplot2); library(sandwich); library(jsonlite)
})
invisible(Sys.setlocale("LC_TIME", "C"))   # English month names in labels

# ------------------------------- SETTINGS --------------------------------------------
SETTINGS <- list(
  data             = "data/4333_DATA.xlsx",   # workbook with one sheet per series (path relative to the project folder)
  out              = "results",          # output folder
  reit_sheet       = "MSCI US REIT",  reit_col = NULL,   # MSCI US REIT Index, gross total return (RMS); NULL = auto-detect
  reit_price_sheet = NULL,  reit_price_col = NULL,   # optional price-only REIT index
  spx_sheet        = NULL,  spx_col        = NULL,
  y10_sheet        = NULL,  y10_col        = NULL,
  baa_sheet        = "DBAA",  baa_col        = NULL,
  method           = "paper",            # "paper" or "aligned" (see build_daily)
  tp_threshold     = 0.20,               # swing size for REIT-index turning points
  label            = "",
  note             = ""                  # footnote added to charts
)
# command-line overrides: --name=value
for (a in commandArgs(trailingOnly = TRUE)) {
  if (grepl("^--[a-z_]+=", a)) {
    k <- sub("^--([a-z_]+)=.*$", "\\1", a); v <- sub("^--[a-z_]+=", "", a)
    SETTINGS[[k]] <- if (k == "tp_threshold") as.numeric(v) else v
  }
}

# ------------------------------- PAPER CONSTANTS -------------------------------------
PAPER_START <- as.Date("1995-01-03"); PAPER_END <- as.Date("2016-03-30")
PAPER_SUBPERIODS <- list(  # Exhibit 3
  list("Mid 90s REIT Bull Market", "1995-01-03", "1997-10-06"),
  list("Late 90s REIT Bear Market", "1997-10-07", "1999-12-15"),
  list("2000s Bull Market", "1999-12-16", "2007-02-07"),
  list("Crash", "2007-02-08", "2009-03-06"),
  list("Surge", "2009-03-07", "2013-05-21"),
  list("Taper Tantrum and Beyond", "2013-05-22", "2016-03-30"))
PAPER_N <- c("Mid 90s REIT Bull Market" = 694, "Late 90s REIT Bear Market" = 547, "2000s Bull Market" = 1781,
             "Crash" = 519, "Surge" = 1051, "Taper Tantrum and Beyond" = 713, "Full Period" = 5305)
LEHMAN <- as.Date(c("2008-09-15", "2009-09-14"))   # Exhibit 8: 250 obs = 118 Crash + 132 Surge
# Fed-policy regimes for the extension (liftoff 16 Mar 2022, last hike 26 Jul 2023, first cut 18 Sep 2024)
FED_REGIMES <- list(
  list("Pre-COVID", "2016-03-31", "2020-02-19"),
  list("COVID & zero rates", "2020-02-20", "2022-03-15"),
  list("Hiking cycle", "2022-03-16", "2023-07-26"),
  list("Hold at peak", "2023-07-27", "2024-09-17"),
  list("Since first cut", "2024-09-18", "2100-01-01"))

# Exhibit 4: (mean %, sd %) and N
PAPER_EX4 <- list(
  "Crash" = list(tsy = c(0.0328, 0.6399), baa = c(-0.0240, 0.4878), exc = c(-0.0568, 0.3830),
                 reit = c(-0.1872, 3.8562), spx = c(-0.1392, 1.9889), N = 519),
  "Surge" = list(tsy = c(0.0075, 0.5480), baa = c(0.0241, 0.4603), exc = c(0.0165, 0.2618),
                 reit = c(0.1586, 2.2371), spx = c(0.0871, 1.2074), N = 1051),
  "Taper Tantrum and Beyond" = list(tsy = c(0.0010, 0.4315), baa = c(-0.0021, 0.3643), exc = c(-0.0032, 0.1980),
                                    reit = c(0.0309, 1.0074), spx = c(0.0353, 0.8559), N = 713),
  "2000s Bull Market" = list(tsy = c(0.0062, 0.4572), baa = c(0.0082, 0.3272), exc = c(0.0020, 0.2331),
                             reit = c(0.0947, 0.8945), spx = c(0.0083, 1.1236), N = 1781))
# Exhibit 7: c(coefficient, t).  A: REIT ~ Tsy + Exc; B: S&P ~ Tsy + Exc; C: REIT ~ Tsy + Exc + S&P
PAPER_EX7 <- list(
  A = list("Mid 90s REIT Bull Market" = list(b1 = c(0.418, 1.875), b2 = c(0.159, 0.295)),
           "Late 90s REIT Bear Market" = list(b1 = c(0.182, 0.672), b2 = c(0.687, 1.398)),
           "2000s Bull Market" = list(b1 = c(0.224, 1.805), b2 = c(0.820, 3.361)),
           "Crash" = list(b1 = c(-1.838, -12.488), b2 = c(0.687, 2.794)),
           "Surge" = list(b1 = c(-1.328, -12.105), b2 = c(-0.526, -2.291)),
           "Taper Tantrum and Beyond" = list(b1 = c(0.255, 1.515), b2 = c(-0.005, -0.014))),
  B = list("Mid 90s REIT Bull Market" = list(b1 = c(0.995, 6.618), b2 = c(0.173, 0.477)),
           "Late 90s REIT Bear Market" = list(b1 = c(0.463, 2.539), b2 = c(1.418, 4.279)),
           "2000s Bull Market" = list(b1 = c(-0.211, -2.514), b2 = c(1.233, 7.506)),
           "Crash" = list(b1 = c(-1.058, -10.672), b2 = c(0.946, 5.707)),
           "Surge" = list(b1 = c(-1.147, -15.519), b2 = c(-0.538, -3.481)),
           "Taper Tantrum and Beyond" = list(b1 = c(-0.606, -5.366), b2 = c(0.070, 0.282))),
  C = list("Mid 90s REIT Bull Market" = list(b1 = c(0.237, 1.506), b2 = c(0.127, 0.365), b3 = c(0.182, 2.882)),
           "Late 90s REIT Bear Market" = list(b1 = c(0.058, 0.329), b2 = c(0.307, 0.954), b3 = c(0.268, 7.408)),
           "2000s Bull Market" = list(b1 = c(0.305, 3.796), b2 = c(0.345, 2.153), b3 = c(0.385, 16.396)),
           "Crash" = list(b1 = c(-0.066, -0.671), b2 = c(-0.896, -5.572), b3 = c(1.674, 63.160)),
           "Surge" = list(b1 = c(0.493, 6.247), b2 = c(0.329, 2.205), b3 = c(1.588, 52.169)),
           "Taper Tantrum and Beyond" = list(b1 = c(0.806, 7.148), b2 = c(-0.069, -0.290), b3 = c(0.909, 18.711))))
PAPER_EX8 <- list(
  "Entire post-Lehman year" = list(b1 = c(-0.223, -0.715), b2 = c(-0.778, -1.657), b3 = c(1.879, 23.779), N = 250),
  "Portion in Crash" = list(b1 = c(-0.140, -0.342), b2 = c(-0.933, -1.633), b3 = c(1.761, 19.141), N = 118),
  "Portion in Surge" = list(b1 = c(0.083, 0.169), b2 = c(0.586, 0.678), b3 = c(2.447, 14.861), N = 132))
# Full-sample 1995-2016 results: comparable only if the data start in Jan 1995
PAPER_EX5 <- list("10Y Treasury" = c(-0.081, -1076.872), "Baa (yield only)" = c(-0.054, -122.729),
                  "Baa" = c(-0.072, -1270.571), "S&P 500" = c(0.045, 14.875), "Equity REIT" = c(0.046, 10.302))
PAPER_EX6 <- list(A = list(b1 = c(-0.516, -8.177), b2 = c(0.326, 2.635)),
                  B = list(b1 = c(-0.032, -0.651), b2 = c(-0.149, -1.568), b3 = c(0.948, 61.627)))
NW_LAGS <- 5
TERM <- c(b1 = "tsy", b2 = "exc", b3 = "spx")

# ------------------------------- 1. LOADING ------------------------------------------
find_sheet <- function(sheets, explicit, patterns) {
  if (!is.null(explicit) && nzchar(explicit)) {
    if (!explicit %in% sheets) stop(sprintf("Sheet '%s' not found. Sheets: %s", explicit, paste(sheets, collapse = ", ")))
    return(explicit)
  }
  for (p in patterns) for (s in sheets) if (grepl(p, s, ignore.case = TRUE)) return(s)
  NULL
}

load_series <- function(path, sheet, col = NULL, name = "x") {
  df <- as.data.frame(read_excel(path, sheet = sheet))
  if (is.null(col) || !nzchar(col)) {
    cand <- which(tolower(trimws(names(df)[-1])) %in% c("price", "close", "adj close", "px_last", "value"))
    col <- if (length(cand)) names(df)[-1][cand[1]] else names(df)[2]
  }
  dt <- df[[1]]
  dt <- if (inherits(dt, c("POSIXct", "Date"))) as.Date(dt) else as.Date(suppressWarnings(as.numeric(dt)), origin = "1899-12-30")
  if (all(is.na(dt))) dt <- as.Date(df[[1]])
  v <- suppressWarnings(as.numeric(gsub(",", "", trimws(as.character(df[[col]])))))
  s <- data.frame(date = dt, value = v)
  raw_n <- nrow(s)
  s <- s[!is.na(s$date), ]; s <- s[order(s$date), ]
  dups <- sum(duplicated(s$date))
  s <- s[!duplicated(s$date, fromLast = TRUE), ]
  missing <- sum(is.na(s$value))
  s <- s[!is.na(s$value), ]
  names(s)[2] <- name
  list(s = s, audit = data.frame(series = name, sheet = sheet, column = col, raw_rows = raw_n,
                                 duplicate_dates = dups, blank_or_nonnumeric = missing, usable = nrow(s),
                                 first = as.character(min(s$date)), last = as.character(max(s$date))))
}

par_bond_return <- function(y_prev, y_now, years = 10, freq = 2) {
  c <- y_prev / 100 / freq; r <- y_now / 100 / freq; n <- years * freq
  annuity <- ifelse(abs(r) > 1e-12, (1 - (1 + r)^-n) / ifelse(r == 0, 1, r), n)
  price <- 100 * c * annuity + 100 * (1 + r)^-n
  (price - 100) / 100
}
pct <- function(v) c(NA, v[-1] / v[-length(v)] - 1)
lagdiff <- function(v) c(NA, diff(v))
merge_all <- function(lst) Reduce(function(a, b) merge(a, b, by = "date"), lst)
# row-bind data frames whose columns differ (missing columns become NA)
rbind_fill <- function(lst) {
  lst <- Filter(Negate(is.null), lst); if (!length(lst)) return(NULL)
  cols <- unique(unlist(lapply(lst, names)))
  do.call(rbind, lapply(lst, function(x) { for (c in setdiff(cols, names(x))) x[[c]] <- NA; x[cols] }))
}

build_daily <- function(S, method = "paper") {
  # 'paper'  : each return / yield change is computed on its OWN market's calendar, then dates
  #            where every series has a value are kept (paper fn 9: 51 obs where stock and
  #            bond returns span different intervals).
  # 'aligned': keep common dates FIRST, then difference, so every variable spans the same interval.
  lv <- merge_all(S[names(S)])
  if (method == "paper") {
    eq <- data.frame(date = S$reit_tr$date, reit = pct(S$reit_tr$reit_tr))
    sp <- data.frame(date = S$spx$date, spx = pct(S$spx$spx), prev_eq = c(NA, head(S$spx$date, -1)))
    yl <- merge(S$y10, S$baa, by = "date")
    b <- data.frame(date = yl$date, y10 = yl$y10, baa = yl$baa,
                    dy10 = lagdiff(yl$y10), dspread = lagdiff(yl$baa - yl$y10),
                    tsy = c(NA, par_bond_return(head(yl$y10, -1), yl$y10[-1])),
                    baa_ret = c(NA, par_bond_return(head(yl$baa, -1), yl$baa[-1])),
                    prev_bd = c(NA, head(yl$date, -1)))
    b$exc <- b$baa_ret - b$tsy
    d <- merge(merge(eq, sp, by = "date"), b, by = "date")
    if (!is.null(S$reit_pr)) d <- merge(d, data.frame(date = S$reit_pr$date, reit_pr = pct(S$reit_pr$reit_pr)), by = "date", all.x = TRUE)
    d <- d[complete.cases(d[, c("reit", "spx", "tsy", "exc")]), ]
    d$interval_mismatch <- as.integer(d$prev_eq != d$prev_bd)
    d$prev_eq <- NULL; d$prev_bd <- NULL
  } else {
    d <- data.frame(date = lv$date, reit = pct(lv$reit_tr), spx = pct(lv$spx), y10 = lv$y10, baa = lv$baa,
                    dy10 = lagdiff(lv$y10), dspread = lagdiff(lv$baa - lv$y10),
                    tsy = c(NA, par_bond_return(head(lv$y10, -1), lv$y10[-1])),
                    baa_ret = c(NA, par_bond_return(head(lv$baa, -1), lv$baa[-1])))
    d$exc <- d$baa_ret - d$tsy
    if (!is.null(lv$reit_pr)) d$reit_pr <- pct(lv$reit_pr)
    d$interval_mismatch <- 0L
    d <- d[-1, ]
  }
  d <- d[order(d$date), ]
  d$gap_days <- c(NA, as.numeric(diff(d$date)))
  rownames(d) <- NULL
  list(d = d, lv = lv)
}

# ------------------------------- 2. ESTIMATION HELPERS -------------------------------
vcov_of <- function(m, cov) switch(cov,
  nonrobust = vcov(m),
  HC3 = sandwich::vcovHC(m, type = "HC3"),
  HAC = sandwich::NeweyWest(m, lag = NW_LAGS, prewhite = FALSE, adjust = FALSE))

dw_stat <- function(e) sum(diff(e)^2) / sum(e^2)

# OLS with an intercept. Ordinary SEs use the t distribution; robust SEs use the normal.
fit_ols <- function(df, y, xs, cov = "nonrobust") {
  f <- as.formula(paste(y, "~", paste(xs, collapse = " + ")))
  m <- lm(f, data = df, na.action = na.omit)
  V <- vcov_of(m, cov); b <- coef(m); se <- sqrt(diag(V)); t <- b / se
  dfres <- df.residual(m)
  if (cov == "nonrobust") { p <- 2 * pt(-abs(t), dfres); crit <- qt(0.975, dfres) }
  else { p <- 2 * pnorm(-abs(t)); crit <- qnorm(0.975) }
  names(b) <- sub("\\(Intercept\\)", "const", names(b))
  s <- summary(m)
  list(m = m, b = b, se = setNames(se, names(b)), t = setNames(t, names(b)), p = setNames(p, names(b)),
       lo = setNames(b - crit * se, names(b)), hi = setNames(b + crit * se, names(b)), V = V, cov = cov,
       r2 = s$r.squared, adj_r2 = s$adj.r.squared, dw = dw_stat(resid(m)), n = nobs(m), dfres = dfres)
}

tidy <- function(r, label, extra = list()) {
  out <- data.frame(model = label, term = names(r$b), coef = unname(r$b), se = unname(r$se), t = unname(r$t),
                    p = unname(r$p), ci_low = unname(r$lo), ci_high = unname(r$hi), adj_r2 = r$adj_r2,
                    r2 = r$r2, DW = r$dw, N = r$n, se_type = r$cov, stringsAsFactors = FALSE)
  for (k in names(extra)) out[[k]] <- extra[[k]]
  out
}

win <- function(d, a, b) d[d$date >= as.Date(a) & d$date <= as.Date(b), ]

# clip (name,start,end) periods to [lo,hi] and the data; flag partial periods
periods_in <- function(d, periods, lo, hi, min_obs = 30) {
  out <- list()
  for (p in periods) {
    a <- as.Date(p[[2]]); b <- as.Date(p[[3]])
    sub <- win(d, max(a, as.Date(lo)), min(b, as.Date(hi)))
    if (nrow(sub) < min_obs) next
    s0 <- min(sub$date); s1 <- max(sub$date)
    partial <- as.numeric(s0 - a) > 7 || as.numeric(b - s1) > 7
    nm <- if (partial && b < as.Date("2100-01-01")) paste0(p[[1]], " (partial)") else p[[1]]
    out[[length(out) + 1]] <- list(name = nm, start = s0, end = s1, partial = partial)
  }
  out
}

# Paper's 'system': one regression with period dummies interacted with every regressor
# (including the intercept), so periods are estimated jointly and compared with Wald tests.
fit_system <- function(d, periods, y, xs, cov = "nonrobust") {
  keep <- rep(FALSE, nrow(d)); X <- NULL; cn <- c()
  for (p in periods) {
    D <- as.numeric(d$date >= p$start & d$date <= p$end); keep <- keep | D == 1
    X <- cbind(X, D); cn <- c(cn, paste0("a|", p$name))
    for (x in xs) { X <- cbind(X, D * d[[x]]); cn <- c(cn, paste0(x, "|", p$name)) }
  }
  X <- X[keep, , drop = FALSE]; colnames(X) <- cn; yy <- d[[y]][keep]
  m <- lm(yy ~ 0 + X)
  V <- vcov_of(m, cov); b <- coef(m); names(b) <- cn; dimnames(V) <- list(cn, cn)
  se <- sqrt(diag(V)); t <- b / se; dfres <- df.residual(m)
  if (cov == "nonrobust") { p <- 2 * pt(-abs(t), dfres); crit <- qt(0.975, dfres) }
  else { p <- 2 * pnorm(-abs(t)); crit <- qnorm(0.975) }
  e <- resid(m); n <- length(yy)
  r2 <- 1 - sum(e^2) / sum((yy - mean(yy))^2)          # centred: the dummies span a constant
  list(b = b, se = se, t = t, p = p, lo = b - crit * se, hi = b + crit * se, V = V, cov = cov, dfres = dfres,
       X = X, adj_r2 = 1 - (n - 1) / dfres * (1 - r2), dw = dw_stat(e))
}

system_table <- function(res, periods, xs, label) {
  rows <- list()
  for (p in periods) {
    n <- sum(res$X[, paste0("a|", p$name)] > 0)
    for (x in c("a", xs)) {
      k <- paste0(x, "|", p$name); sc <- if (x == "a") 1000 else 1
      rows[[length(rows) + 1]] <- data.frame(model = label, period = p$name, start = as.character(p$start),
        end = as.character(p$end), N = n, term = x, coef = res$b[[k]] * sc, t = res$t[[k]], p = res$p[[k]],
        ci_low = res$lo[[k]] * sc, ci_high = res$hi[[k]] * sc, stringsAsFactors = FALSE)
    }
  }
  out <- rbind_fill(rows); out$system_adj_r2 <- res$adj_r2; out$system_DW <- res$dw; out
}

wald_one <- function(res, R) {
  Rb <- R %*% res$b; W <- as.numeric(t(Rb) %*% solve(R %*% res$V %*% t(R)) %*% Rb); q <- nrow(R)
  if (res$cov == "nonrobust") list(stat = W / q, dist = "F", p = pf(W / q, q, res$dfres, lower.tail = FALSE))
  else list(stat = W, dist = "chi2", p = pchisq(W, q, lower.tail = FALSE))
}

wald_equal <- function(res, periods, x, label) {
  nm <- names(res$b); keys <- paste0(x, "|", sapply(periods, `[[`, "name")); rows <- list()
  if (length(keys) < 2) return(NULL)
  R <- matrix(0, length(keys) - 1, length(nm))
  for (i in 2:length(keys)) { R[i - 1, match(keys[1], nm)] <- 1; R[i - 1, match(keys[i], nm)] <- -1 }
  w <- wald_one(res, R)
  rows[[1]] <- data.frame(model = label, coef = x, test = "all periods equal", stat = w$stat, dist = w$dist,
                          df = nrow(R), p = w$p)
  for (i in 1:(length(keys) - 1)) for (j in (i + 1):length(keys)) {
    R <- matrix(0, 1, length(nm)); R[1, match(keys[i], nm)] <- 1; R[1, match(keys[j], nm)] <- -1
    w <- wald_one(res, R)
    rows[[length(rows) + 1]] <- data.frame(model = label, coef = x,
      test = paste(periods[[i]]$name, "=", periods[[j]]$name), stat = w$stat, dist = w$dist, df = 1, p = w$p)
  }
  rbind_fill(rows)
}

# ------------------------------- 3. TURNING POINTS -----------------------------------
# Alternating peaks/troughs of the REIT index: a pivot is confirmed once the index has moved
# `threshold` away from the running extreme (the paper's "low tech" sub-period method).
turning_points <- function(s, threshold = 0.20) {
  dts <- s$date; v <- s[[2]]
  piv <- data.frame(date = dts[1], kind = "start")
  trend <- 0; ext_i <- 1; hi_i <- 1; lo_i <- 1
  for (i in seq_along(v)) {
    if (trend == 0) {
      if (v[i] > v[hi_i]) hi_i <- i
      if (v[i] < v[lo_i]) lo_i <- i
      if (v[i] >= v[lo_i] * (1 + threshold)) { trend <- 1; ext_i <- i; piv <- rbind(piv, data.frame(date = dts[lo_i], kind = "trough")) }
      else if (v[i] <= v[hi_i] * (1 - threshold)) { trend <- -1; ext_i <- i; piv <- rbind(piv, data.frame(date = dts[hi_i], kind = "peak")) }
    } else if (trend == 1) {
      if (v[i] > v[ext_i]) ext_i <- i
      else if (v[i] <= v[ext_i] * (1 - threshold)) { piv <- rbind(piv, data.frame(date = dts[ext_i], kind = "peak")); trend <- -1; ext_i <- i }
    } else {
      if (v[i] < v[ext_i]) ext_i <- i
      else if (v[i] >= v[ext_i] * (1 + threshold)) { piv <- rbind(piv, data.frame(date = dts[ext_i], kind = "trough")); trend <- 1; ext_i <- i }
    }
  }
  if (tail(piv$date, 1) != tail(dts, 1)) piv <- rbind(piv, data.frame(date = tail(dts, 1), kind = "end"))
  piv[c(TRUE, piv$date[-1] != head(piv$date, -1)), ]
}

legs_from_pivots <- function(piv, s) {
  lvl <- setNames(s[[2]], as.character(s$date)); legs <- list()
  for (i in seq_len(nrow(piv) - 1)) {
    a <- piv$date[i]; b <- piv$date[i + 1]
    chg <- lvl[[as.character(b)]] / lvl[[as.character(a)]] - 1
    start <- if (i == 1) a else s$date[match(a, s$date) + 1]   # legs do not overlap
    legs[[i]] <- list(sprintf("%s %s-%s (%+.0f%%)", if (chg > 0) "REIT up" else "REIT down",
                              format(a, "%b %Y"), format(b, "%b %Y"), 100 * chg),
                      as.character(start), as.character(b))
  }
  legs
}

# ------------------------------- 4. MAIN ANALYSIS ------------------------------------
run_analysis <- function(cfg) {
  dir.create(cfg$out, showWarnings = FALSE, recursive = TRUE)
  sh <- excel_sheets(cfg$data)
  spec <- list(
    reit_tr = list(find_sheet(sh, cfg$reit_sheet, c("reit.*(total|tr|gross)", "rms", "reit")), cfg$reit_col),
    spx = list(find_sheet(sh, cfg$spx_sheet, c("s&p|spx|sp500|s.p 500")), cfg$spx_col),
    y10 = list(find_sheet(sh, cfg$y10_sheet, c("dgs10", "10.?y")), cfg$y10_col),
    baa = list(find_sheet(sh, cfg$baa_sheet, c("dbaa|baa")), cfg$baa_col))
  if (!is.null(cfg$reit_price_sheet) && nzchar(cfg$reit_price_sheet))
    spec$reit_pr <- list(find_sheet(sh, cfg$reit_price_sheet, character()), cfg$reit_price_col)
  miss <- names(spec)[sapply(spec, function(z) is.null(z[[1]]))]
  if (length(miss)) stop("Could not find sheets for: ", paste(miss, collapse = ", "), ". Sheets: ", paste(sh, collapse = ", "))

  S <- list(); audit <- list()
  for (k in names(spec)) { L <- load_series(cfg$data, spec[[k]][[1]], spec[[k]][[2]], k); S[[k]] <- L$s; audit[[k]] <- L$audit }
  B <- build_daily(S, cfg$method); d <- B$d; lv <- B$lv
  d_alt <- build_daily(S, if (cfg$method == "paper") "aligned" else "paper")$d
  audit_df <- rbind_fill(audit)
  audit_df <- rbind(audit_df, data.frame(series = "COMMON (all required series present)", sheet = NA, column = NA,
                     raw_rows = NA, duplicate_dates = NA, blank_or_nonnumeric = NA, usable = nrow(lv),
                     first = as.character(min(lv$date)), last = as.character(max(lv$date))))
  notes <- c(sprintf("Daily observations used: %d (%s to %s).", nrow(d), min(d$date), max(d$date)),
             sprintf("Observations spanning >4 calendar days (holiday gaps or a series missing that day): %d.", sum(d$gap_days > 4, na.rm = TRUE)),
             sprintf("Alignment method: %s. Observations where stock and bond returns span different intervals: %d (paper fn 9 reports 51 over 1995-2016).",
                     cfg$method, sum(d$interval_mismatch)),
             "No values were filled or imputed; dates missing from any series are dropped.")

  data_start <- min(d$date); data_end <- max(d$date)
  rep_lo <- max(data_start, PAPER_START); rep_hi <- PAPER_END
  full_replication <- data_start <= as.Date("1995-01-10")
  R <- list()

  # ---- Exhibit 4: descriptive statistics ----
  rep_periods <- periods_in(d, PAPER_SUBPERIODS, rep_lo, rep_hi)
  cols <- c(tsy = "10Y Treasury price return", baa_ret = "Baa price return", exc = "Baa excess return",
            reit = "REIT total return", spx = "S&P 500 price return")
  describe <- function(sub, label) rbind_fill(lapply(names(cols), function(c) {
    x <- sub[[c]] * 100
    data.frame(period = label, series = cols[[c]], mean_pct = mean(x), median_pct = median(x), max_pct = max(x),
               min_pct = min(x), sd_pct = sd(x), N = length(x))
  }))
  R$Ex4_DescStats <- rbind(describe(win(d, rep_lo, rep_hi), "Replication window"),
                           rbind_fill(lapply(rep_periods, function(p) describe(win(d, p$start, p$end), p$name))))

  # ---- Exhibit 2: correlations ----
  cm <- cor(win(d, rep_lo, rep_hi)[, names(cols)]); dimnames(cm) <- list(cols, cols)
  R$Ex2_Correlations <- data.frame(series = rownames(cm), cm, check.names = FALSE, row.names = NULL)

  # ---- Exhibit 5 (yield changes) and Exhibit 6 (bond returns) ----
  ex5 <- function(sub, tag) rbind_fill(list(
    tidy(fit_ols(sub, "tsy", "dy10"), "10Y Treasury", list(sample = tag)),
    tidy(fit_ols(sub, "baa_ret", "dy10"), "Baa (yield only)", list(sample = tag)),
    tidy(fit_ols(sub, "baa_ret", c("dy10", "dspread")), "Baa", list(sample = tag)),
    tidy(fit_ols(sub, "spx", c("dy10", "dspread")), "S&P 500", list(sample = tag)),
    tidy(fit_ols(sub, "reit", c("dy10", "dspread")), "Equity REIT", list(sample = tag))))
  ex6 <- function(sub, tag, cov = "nonrobust") {
    A <- tidy(fit_ols(sub, "reit", c("tsy", "exc"), cov), "A: REIT ~ Tsy + Excess", list(sample = tag))
    rB <- fit_ols(sub, "reit", c("tsy", "exc", "spx"), cov)
    Bt <- tidy(rB, "B: REIT ~ Tsy + Excess + S&P", list(sample = tag))
    tt <- (rB$b[["spx"]] - 1) / rB$se[["spx"]]                 # paper fn 12: equity beta = 1?
    A$test_equity_beta_eq_1_p <- NA
    Bt$test_equity_beta_eq_1_p <- if (cov == "nonrobust") 2 * pt(-abs(tt), rB$dfres) else 2 * pnorm(-abs(tt))
    rbind(A, Bt)
  }
  rep <- win(d, rep_lo, rep_hi); ext <- d[d$date > PAPER_END, ]; full <- d
  fmt <- function(x) format(x, "%d %b %Y")
  tag_rep <- sprintf("Replication %s-%s", fmt(min(rep$date)), fmt(max(rep$date)))
  tag_ext <- if (nrow(ext)) sprintf("Extension %s-%s", fmt(min(ext$date)), fmt(max(ext$date))) else NA
  tag_full <- sprintf("Full %s-%s", fmt(min(full$date)), fmt(max(full$date)))
  samples <- list(list(tag_rep, rep)); if (nrow(ext)) samples[[2]] <- list(tag_ext, ext); samples[[length(samples) + 1]] <- list(tag_full, full)
  R$Ex5_YieldRegs <- rbind_fill(lapply(samples, function(s) ex5(s[[2]], s[[1]])))
  R$Ex6_BondRegs <- rbind_fill(lapply(samples, function(s) ex6(s[[2]], s[[1]])))

  # ---- Exhibit 7: sub-period system ----
  ex7 <- list(); wald <- list()
  run_system <- function(per, tag) {
    for (pan in list(list("A", "reit", c("tsy", "exc")), list("B", "spx", c("tsy", "exc")),
                     list("C", "reit", c("tsy", "exc", "spx")))) {
      res <- fit_system(d, per, pan[[2]], pan[[3]])
      tb <- system_table(res, per, pan[[3]], paste0(tag, " | Panel ", pan[[1]])); tb$panel <- pan[[1]]; tb$sample <- tag
      ex7[[length(ex7) + 1]] <<- tb
      for (x in pan[[3]]) { w <- wald_equal(res, per, x, paste0(tag, " | Panel ", pan[[1]]))
        if (!is.null(w)) { w$se_type <- "OLS"; wald[[length(wald) + 1]] <<- w } }
      if (pan[[1]] == "C") {
        rr <- fit_system(d, per, pan[[2]], pan[[3]], "HAC")
        for (x in pan[[3]]) { w <- wald_equal(rr, per, x, paste0(tag, " | Panel C"))
          if (!is.null(w)) { w$se_type <- sprintf("Newey-West(%d)", NW_LAGS); wald[[length(wald) + 1]] <<- w } }
      }
    }
  }
  run_system(rep_periods, "Replication sub-periods")
  ext_tp_periods <- list(); ext_fed_periods <- list()
  if (nrow(ext) > 250) {
    lvl <- S$reit_tr[S$reit_tr$date >= min(ext$date), ]
    piv <- turning_points(lvl, cfg$tp_threshold)
    R$Ext_TurningPoints <- data.frame(date = as.character(piv$date), kind = piv$kind,
                                      index_level = lvl$reit_tr[match(piv$date, lvl$date)])
    ext_tp_periods <- periods_in(d, legs_from_pivots(piv, lvl), min(ext$date), data_end, min_obs = 20)
    run_system(ext_tp_periods, "Extension: REIT turning points")
    ext_fed_periods <- periods_in(d, FED_REGIMES, min(ext$date), data_end)
    run_system(ext_fed_periods, "Extension: Fed regimes")
  }
  R$Ex7_SubPeriods <- rbind_fill(ex7)

  # ---- Exhibit 8: post-Lehman year ----
  lw <- win(d, LEHMAN[1], LEHMAN[2]); crash_end <- as.Date("2009-03-06")
  if (nrow(lw) > 200) {
    # Panel A: one regression on the whole year.  Panels B and C: the paper estimates the two
    # portions jointly (a dummy system with a pooled residual variance), which reproduces its t-stats.
    whole <- tidy(fit_ols(lw, "reit", c("tsy", "exc", "spx")), "Entire post-Lehman year")
    per <- list(list(name = "Crash part", start = min(lw$date), end = crash_end),
                list(name = "Surge part", start = min(lw$date[lw$date > crash_end]), end = max(lw$date)))
    res <- fit_system(d, per, "reit", c("tsy", "exc", "spx"))
    st <- system_table(res, per, c("tsy", "exc", "spx"), "post-Lehman system")
    parts <- lapply(list(c("Crash part", "Portion in Crash"), c("Surge part", "Portion in Surge")), function(z) {
      o <- st[st$period == z[1], ]
      data.frame(model = z[2], term = sub("^a$", "const", o$term), coef = ifelse(o$term == "a", o$coef / 1000, o$coef),
                 se = NA, t = o$t, p = o$p, ci_low = ifelse(o$term == "a", o$ci_low / 1000, o$ci_low),
                 ci_high = ifelse(o$term == "a", o$ci_high / 1000, o$ci_high), adj_r2 = o$system_adj_r2, r2 = NA,
                 DW = o$system_DW, N = o$N, se_type = "nonrobust (system)")
    })
    parts <- lapply(parts, function(x) { x$se <- x$coef / x$t; x })
    R$Ex8_PostLehman <- rbind_fill(c(list(whole), parts))
    for (x in c("tsy", "exc", "spx")) { w <- wald_equal(res, per, x, "Post-Lehman year"); w$se_type <- "OLS"; wald[[length(wald) + 1]] <- w }
  }
  R$Wald_Tests <- rbind_fill(wald)

  # ---- Replication vs paper ----
  cmp <- list()
  addc <- function(...) cmp[[length(cmp) + 1]] <<- data.frame(..., stringsAsFactors = FALSE)
  e7r <- R$Ex7_SubPeriods[R$Ex7_SubPeriods$sample == "Replication sub-periods", ]
  for (pan in names(PAPER_EX7)) for (per in names(PAPER_EX7[[pan]])) {
    o <- e7r[e7r$panel == pan & e7r$period == per, ]; if (!nrow(o)) next
    for (b in names(PAPER_EX7[[pan]][[per]])) {
      pc <- PAPER_EX7[[pan]][[per]][[b]]; r <- o[o$term == TERM[[b]], ]
      addc(exhibit = "Exhibit 7", panel = pan, period = per, coef = sprintf("%s (%s)", b, TERM[[b]]), paper = pc[1],
           ours = r$coef, diff = r$coef - pc[1], paper_t = pc[2], our_t = r$t, paper_N = unname(PAPER_N[per]), our_N = r$N,
           same_sign = sign(pc[1]) == sign(r$coef), same_signif_5pct = (abs(pc[2]) > 1.96) == (abs(r$t) > 1.96))
    }
  }
  if (!is.null(R$Ex8_PostLehman)) for (nm in names(PAPER_EX8)) for (b in c("b1", "b2", "b3")) {
    r <- R$Ex8_PostLehman[R$Ex8_PostLehman$model == nm & R$Ex8_PostLehman$term == TERM[[b]], ]; pc <- PAPER_EX8[[nm]][[b]]
    addc(exhibit = "Exhibit 8", panel = "", period = nm, coef = sprintf("%s (%s)", b, TERM[[b]]), paper = pc[1], ours = r$coef,
         diff = r$coef - pc[1], paper_t = pc[2], our_t = r$t, paper_N = PAPER_EX8[[nm]]$N, our_N = r$N,
         same_sign = sign(pc[1]) == sign(r$coef), same_signif_5pct = (abs(pc[2]) > 1.96) == (abs(r$t) > 1.96))
  }
  keymap <- c(tsy = "10Y Treasury price return", baa = "Baa price return", exc = "Baa excess return",
              reit = "REIT total return", spx = "S&P 500 price return")
  for (per in names(PAPER_EX4)) {
    sub <- R$Ex4_DescStats[R$Ex4_DescStats$period == per, ]; if (!nrow(sub)) next
    for (k in names(keymap)) { r <- sub[sub$series == keymap[[k]], ]
      for (st in c("mean_pct", "sd_pct")) { pv <- PAPER_EX4[[per]][[k]][if (st == "mean_pct") 1 else 2]
        addc(exhibit = "Exhibit 4", panel = "", period = per, coef = paste0(keymap[[k]], ": ", st), paper = pv,
             ours = r[[st]], diff = r[[st]] - pv, paper_t = NA, our_t = NA, paper_N = PAPER_EX4[[per]]$N, our_N = r$N,
             same_sign = NA, same_signif_5pct = NA) } }
  }
  if (full_replication) {
    e5 <- R$Ex5_YieldRegs[R$Ex5_YieldRegs$sample == tag_rep, ]
    for (nm in names(PAPER_EX5)) { r <- e5[e5$model == nm & e5$term == "dy10", ]; pc <- PAPER_EX5[[nm]]
      addc(exhibit = "Exhibit 5", panel = "", period = "Full", coef = paste0(nm, ": dYield10"), paper = pc[1], ours = r$coef,
           diff = r$coef - pc[1], paper_t = pc[2], our_t = r$t, paper_N = 5305, our_N = r$N, same_sign = NA, same_signif_5pct = NA) }
    e6 <- R$Ex6_BondRegs[R$Ex6_BondRegs$sample == tag_rep, ]
    for (pan in names(PAPER_EX6)) for (b in names(PAPER_EX6[[pan]])) {
      r <- e6[startsWith(e6$model, pan) & e6$term == TERM[[b]], ]; pc <- PAPER_EX6[[pan]][[b]]
      addc(exhibit = "Exhibit 6", panel = pan, period = "Full", coef = sprintf("%s (%s)", b, TERM[[b]]), paper = pc[1],
           ours = r$coef, diff = r$coef - pc[1], paper_t = pc[2], our_t = r$t, paper_N = 5305, our_N = r$N,
           same_sign = NA, same_signif_5pct = NA) }
  }
  R$Replication_vs_Paper <- rbind_fill(cmp)

  # ---- Robustness ----
  rob <- list(); addr <- function(t, check) { t$check <- check; rob[[length(rob) + 1]] <<- t }
  for (s in samples) for (cov in c("nonrobust", "HC3", "HAC")) addr(ex6(s[[2]], s[[1]], cov), "SE choice")
  rx <- Filter(function(s) !grepl("^Full", s[[1]]), samples)
  for (s in rx) {                                  # lagged dependent variable (paper fn 11)
    s2 <- s[[2]]; s2$reit_lag <- c(NA, head(s2$reit, -1)); s2 <- s2[!is.na(s2$reit_lag), ]
    addr(tidy(fit_ols(s2, "reit", c("tsy", "exc", "spx", "reit_lag"), "HAC"), "B + lagged REIT return", list(sample = s[[1]])), "Lagged dependent variable")
  }
  if ("reit_pr" %in% names(d)) for (s in rx) {     # price-only REIT return (paper fn 6)
    s2 <- s[[2]][!is.na(s[[2]]$reit_pr), ]
    addr(tidy(fit_ols(s2, "reit_pr", c("tsy", "exc", "spx"), "HAC"), "B with REIT PRICE return", list(sample = s[[1]])), "Price vs total return")
  }
  alt <- if (cfg$method == "paper") "aligned" else "paper"
  for (s in rx) {                                  # the other way of lining up return intervals
    sub <- d_alt[d_alt$date >= min(s[[2]]$date) & d_alt$date <= max(s[[2]]$date), ]
    addr(tidy(fit_ols(sub, "reit", c("tsy", "exc", "spx"), "HAC"), sprintf("B with %s intervals", alt), list(sample = s[[1]])), "Interval alignment")
  }
  # weekly (Wednesday-to-Wednesday) data -- reduces the bond/stock close-time mismatch
  wkend <- lv$date + ((3 - as.integer(format(lv$date, "%u"))) %% 7)
  wk <- lv[!duplicated(wkend, fromLast = TRUE), ]; wk$date <- wkend[!duplicated(wkend, fromLast = TRUE)]
  w <- data.frame(date = wk$date, reit = pct(wk$reit_tr), spx = pct(wk$spx),
                  tsy = c(NA, par_bond_return(head(wk$y10, -1), wk$y10[-1])))
  w$exc <- c(NA, par_bond_return(head(wk$baa, -1), wk$baa[-1])) - w$tsy
  w <- w[complete.cases(w), ]
  for (s in rx) {
    sub <- w[w$date >= min(s[[2]]$date) & w$date <= (if (grepl("^Replication", s[[1]])) rep_hi else data_end), ]
    addr(tidy(fit_ols(sub, "reit", c("tsy", "exc", "spx"), "HAC"), "B at weekly frequency", list(sample = s[[1]])), "Weekly frequency")
  }
  R$Robustness <- rbind_fill(rob)

  # ---- Investor implications: % return per +100bp in the 10Y yield ----
  per100 <- function(sub, label) {
    out <- data.frame(period = label, N = nrow(sub), avg_10y_yield = mean(sub$y10))
    for (z in list(c("REIT_total", "reit", "dy10"), c("SP500_total", "spx", "dy10"), c("Treasury10Y", "tsy", "dy10"),
                   c("REIT_marginal", "reit", "dy10,spx"))) {
      r <- fit_ols(sub, z[2], strsplit(z[3], ",")[[1]], "HAC")
      out[[paste0(z[1], "_pct_per_100bp")]] <- 100 * r$b[["dy10"]]
      out[[paste0(z[1], "_ci_low")]] <- 100 * r$lo[["dy10"]]; out[[paste0(z[1], "_ci_high")]] <- 100 * r$hi[["dy10"]]
    }
    eq <- fit_ols(sub, "reit", "spx", "HAC")
    out$REIT_equity_beta <- eq$b[["spx"]]; out$REIT_rate_R2 <- fit_ols(sub, "reit", "dy10")$r2; out$REIT_equity_R2 <- eq$r2
    out
  }
  imp <- list(per100(rep, tag_rep))
  for (p in rep_periods) imp[[length(imp) + 1]] <- per100(win(d, p$start, p$end), p$name)
  if (nrow(ext)) { imp[[length(imp) + 1]] <- per100(ext, tag_ext)
    for (p in ext_fed_periods) imp[[length(imp) + 1]] <- per100(win(d, p$start, p$end), p$name) }
  imp[[length(imp) + 1]] <- per100(full, tag_full)
  R$Implications_per100bp <- rbind_fill(imp)

  # ---- Rolling one-year (250-day) betas, every 5th day ----
  X <- cbind(1, d$tsy, d$exc, d$spx); y <- d$reit; Wn <- 250; idx <- seq(Wn, nrow(d), by = 5)
  R$Rolling_250d <- rbind_fill(lapply(idx, function(i) {
    r <- (i - Wn + 1):i; b <- qr.solve(X[r, ], y[r])
    data.frame(date = as.character(d$date[i]), bond_beta_marginal = b[2], equity_beta = b[4],
               reit_pct_per_100bp_total = 100 * cov(d$dy10[r], y[r]) / var(d$dy10[r]))
  }))
  R$Data_Audit <- audit_df

  dd <- d; dd$date <- as.character(dd$date)
  write.csv(dd, file.path(cfg$out, "daily_dataset.csv"), row.names = FALSE)
  for (k in names(R)) write.csv(R[[k]], file.path(cfg$out, paste0(k, ".csv")), row.names = FALSE)
  P <- function(l) lapply(l, function(p) list(p$name, as.character(p$start), as.character(p$end)))
  meta <- list(label = cfg$label, notes = notes, full_replication = full_replication, tag_rep = tag_rep, tag_ext = tag_ext,
               tag_full = tag_full, rep_periods = P(rep_periods), ext_tp_periods = P(ext_tp_periods), ext_fed_periods = P(ext_fed_periods))
  write_json(meta, file.path(cfg$out, "run_meta.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(notes, sep = "\n"); cat("Tables written to", cfg$out, ":", paste(names(R), collapse = ", "), "\n")
  list(R = R, meta = meta, d = d)
}

# ------------------------------- 5. CHARTS -------------------------------------------
BLUE <- "#2a78d6"; ORANGE <- "#eb6834"; AQUA <- "#1baf7a"; INK <- "#0b0b0b"; INK2 <- "#52514e"; GRID <- "#e4e3df"; SURF <- "#fcfcfb"
theme_gs <- function() theme_minimal(base_size = 10) + theme(
  plot.background = element_rect(fill = SURF, colour = NA), panel.background = element_rect(fill = SURF, colour = NA),
  panel.grid.minor = element_blank(), panel.grid.major = element_line(colour = GRID, linewidth = 0.3),
  plot.title = element_text(face = "bold", colour = INK), plot.title.position = "plot",
  strip.text = element_text(face = "bold", colour = INK, hjust = 0, size = 10),
  axis.text = element_text(colour = INK2), axis.title = element_text(colour = INK2, size = 9),
  plot.caption = element_text(colour = INK2, hjust = 0, size = 7.5), plot.caption.position = "plot",
  legend.position = "top", legend.justification = "left", legend.title = element_blank())

make_charts <- function(out, meta, note) {
  files <- c()
  # 1. rolling sensitivities
  r <- read.csv(file.path(out, "Rolling_250d.csv")); r$date <- as.Date(r$date)
  lab <- c(reit_pct_per_100bp_total = "Total rate sensitivity: REIT return (%) per +100bp in the 10Y yield",
           bond_beta_marginal = "Marginal rate sensitivity: Treasury bond beta holding the S&P 500 fixed (paper's b1)",
           equity_beta = "Equity beta on the S&P 500 (paper's b3)")
  long <- rbind_fill(lapply(names(lab), function(k) data.frame(date = r$date, value = r[[k]], panel = lab[[k]])))
  long$panel <- factor(long$panel, levels = lab)
  ref <- data.frame(panel = factor(lab, levels = lab), y = c(0, 0, 1))
  bounds <- c(as.Date(sapply(meta$rep_periods[-1], `[[`, 2)), as.Date("2016-03-31"))
  g <- ggplot(long, aes(date, value)) + geom_vline(xintercept = bounds, colour = GRID, linewidth = 0.5) +
    geom_hline(data = ref, aes(yintercept = y), colour = INK2, linewidth = 0.4, linetype = "dashed") +
    geom_line(colour = BLUE, linewidth = 0.8) + facet_wrap(~panel, ncol = 1, scales = "free_y") +
    geom_text(data = data.frame(panel = factor(lab[[1]], levels = lab), date = as.Date("2016-06-30"), value = Inf),
              label = "<- paper's sample ends", hjust = 0, vjust = 1.5, size = 2.8, colour = INK2) +
    labs(title = "Rolling one-year (250-day) estimates for the MSCI US REIT Index", x = NULL, y = NULL,
         caption = paste("Vertical lines: paper's sub-period breaks and the end of its sample (30 Mar 2016). Dashed: 0 (or 1 for equity beta).", note)) +
    theme_gs()
  f <- file.path(out, "chart1_rolling_sensitivity.png"); ggsave(f, g, width = 10, height = 8.2, dpi = 180); files <- c(files, f)

  # 2. replication check (Exhibit 7C and Exhibit 8)
  cmp <- read.csv(file.path(out, "Replication_vs_Paper.csv"))
  cmp <- cmp[(cmp$exhibit == "Exhibit 7" & cmp$panel == "C") | (cmp$exhibit == "Exhibit 8" & cmp$period == "Entire post-Lehman year"), ]
  cmp <- cmp[cmp$coef %in% c("b1 (tsy)", "b3 (spx)"), ]
  if (nrow(cmp)) {
    e7 <- read.csv(file.path(out, "Ex7_SubPeriods.csv")); e8f <- file.path(out, "Ex8_PostLehman.csv")
    e8 <- if (file.exists(e8f)) read.csv(e8f) else NULL
    cmp$term <- sub("^b[0-9] \\((.*)\\)$", "\\1", cmp$coef)
    ci <- t(sapply(seq_len(nrow(cmp)), function(i) {
      if (cmp$exhibit[i] == "Exhibit 7") { o <- e7[e7$sample == "Replication sub-periods" & e7$panel == "C" & e7$period == cmp$period[i] & e7$term == cmp$term[i], ] }
      else o <- e8[e8$model == cmp$period[i] & e8$term == cmp$term[i], ]
      c(o$ci_low, o$ci_high) }))
    cmp$lo <- ci[, 1]; cmp$hi <- ci[, 2]
    cmp$label <- sub("Entire post-Lehman year", "Post-Lehman yr", sub("Taper Tantrum and Beyond", "Taper Tantrum+", cmp$period))
    cmp$label <- factor(cmp$label, levels = rev(unique(cmp$label)))
    cmp$facet <- ifelse(cmp$term == "tsy", "Marginal Treasury bond beta (b1)", "Equity beta (b3)")
    cmp$facet <- factor(cmp$facet, levels = c("Marginal Treasury bond beta (b1)", "Equity beta (b3)"))
    pts <- rbind(data.frame(label = cmp$label, facet = cmp$facet, value = cmp$ours, who = "Our estimate (95% CI)"),
                 data.frame(label = cmp$label, facet = cmp$facet, value = cmp$paper, who = "Paper"))
    g <- ggplot() + geom_vline(xintercept = 0, colour = INK2, linetype = "dashed", linewidth = 0.4) +
      geom_segment(data = cmp, aes(x = lo, xend = hi, y = label, yend = label), colour = BLUE, alpha = 0.5, linewidth = 1.2) +
      geom_point(data = pts, aes(value, label, colour = who, shape = who), size = 3, stroke = 0.8, fill = NA) +
      scale_colour_manual(values = c("Our estimate (95% CI)" = BLUE, "Paper" = ORANGE)) +
      scale_shape_manual(values = c("Our estimate (95% CI)" = 16, "Paper" = 5)) +
      facet_wrap(~facet, scales = "free_x") +
      labs(title = "Replication check: REIT ~ Treasury return + Baa excess return + S&P 500 (Exhibits 7C and 8)",
           x = NULL, y = NULL, caption = note) + theme_gs()
    f <- file.path(out, "chart2_replication_check.png"); ggsave(f, g, width = 10, height = 4.4, dpi = 180); files <- c(files, f)
  }

  # 3. benchmark placement per +100bp
  im <- read.csv(file.path(out, "Implications_per100bp.csv"))
  keep <- c(sapply(meta$rep_periods, `[[`, 1), sapply(meta$ext_fed_periods, `[[`, 1)); keep <- unlist(keep)
  im <- im[im$period %in% keep, ]
  im$plabel <- factor(sub(" \\(partial\\)", "*", im$period), levels = rev(sub(" \\(partial\\)", "*", keep)))
  ser <- list(c("Treasury10Y", "10Y Treasury"), c("SP500_total", "S&P 500"), c("REIT_total", "US REITs"))
  bars <- rbind_fill(lapply(ser, function(s) data.frame(plabel = im$plabel, series = s[2], v = im[[paste0(s[1], "_pct_per_100bp")]],
                    lo = if (s[1] == "Treasury10Y") NA else im[[paste0(s[1], "_ci_low")]],
                    hi = if (s[1] == "Treasury10Y") NA else im[[paste0(s[1], "_ci_high")]])))
  bars$series <- factor(bars$series, levels = c("US REITs", "S&P 500", "10Y Treasury"))
  n_rep <- length(meta$rep_periods)
  g <- ggplot(bars, aes(v, plabel, fill = series)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.72) +
    geom_errorbarh(aes(xmin = lo, xmax = hi), position = position_dodge(width = 0.8), height = 0, colour = INK2, linewidth = 0.4, na.rm = TRUE) +
    geom_vline(xintercept = 0, colour = INK2, linewidth = 0.4) +
    { if (nrow(im) > n_rep) geom_hline(yintercept = nrow(im) - n_rep + 0.5, colour = GRID, linewidth = 0.8) } +
    scale_fill_manual(values = c("10Y Treasury" = AQUA, "S&P 500" = ORANGE, "US REITs" = BLUE),
                      breaks = c("10Y Treasury", "S&P 500", "US REITs")) +
    labs(title = "Benchmark placement: do REITs react to rates like the bond or like stocks?", y = NULL,
         x = "Average same-day return per +100bp rise in the 10Y yield (%), with 95% CI (Newey-West)",
         caption = paste("* partial sub-period. Rows below the line: extension, Fed-policy regimes.", note)) + theme_gs()
  f <- file.path(out, "chart3_benchmark_per100bp.png"); ggsave(f, g, width = 10, height = 0.55 * nrow(im) + 1.8, dpi = 180); files <- c(files, f)
  files
}

# ------------------------------- 6. EXCEL WORKBOOK -----------------------------------
README <- data.frame(Item = c("What this is", "Units", "Bond returns", "Standard errors", "Sub-periods", "Interpretation caution"),
  Detail = c("Replication and extension of Giliberto & Shulman (rev. 8.17.2016), 'On the Interest Rate Sensitivity of REITs'.",
    "Returns are decimals (0.01 = 1%); yield changes in percentage points. A coefficient of -0.081 on dYield = -8.1% per +100bp. Intercepts in sub-period tables are x1000, as in the paper.",
    "Paper's method: par bond priced at 100 with coupon = previous day's yield, re-priced at today's yield, 10 years to maturity, semi-annual coupons. Same for Moody's Baa. Excess credit return = Baa return - Treasury return.",
    "Main tables use ordinary OLS t-stats, as the paper does (so they can be compared). The Robustness sheet repeats with HC3 and Newey-West (5 lags); robust p-values use the normal distribution.",
    "Replication uses the paper's Exhibit 3 dates. Extension uses (i) turning points of the MSCI REIT total-return index (paper's method, 20% swing rule) and (ii) Fed-policy regimes as a robustness check.",
    "Coefficients are associations, not causal effects: yields, growth news and risk appetite move together. Sub-periods defined from the REIT index's own turning points are chosen after the fact."))

make_workbook <- function(out, meta, charts, file = "REIT_RateSensitivity_Results.xlsx") {
  wb <- createWorkbook(); hs <- createStyle(textDecoration = "bold", fontColour = "#FFFFFF", fgFill = "#2A78D6", wrapText = TRUE, valign = "top")
  addWorksheet(wb, "README")
  rd <- rbind(README, data.frame(Item = c("Run", rep("Note", length(meta$notes))), Detail = c(meta$label, unlist(meta$notes))))
  writeData(wb, "README", rd, headerStyle = hs); setColWidths(wb, "README", 1:2, c(22, 120))
  addStyle(wb, "README", createStyle(wrapText = TRUE, valign = "top"), rows = 2:(nrow(rd) + 1), cols = 2)
  order <- c("Data_Audit", "Replication_vs_Paper", "Ex4_DescStats", "Ex2_Correlations", "Ex5_YieldRegs", "Ex6_BondRegs",
             "Ex7_SubPeriods", "Wald_Tests", "Ex8_PostLehman", "Ext_TurningPoints", "Robustness", "Implications_per100bp", "Rolling_250d")
  for (k in order) {
    f <- file.path(out, paste0(k, ".csv")); if (!file.exists(f)) next
    df <- read.csv(f, check.names = FALSE); addWorksheet(wb, k)
    writeData(wb, k, df, headerStyle = hs); freezePane(wb, k, firstRow = TRUE)
    num <- which(sapply(df, is.double))
    if (length(num)) addStyle(wb, k, createStyle(numFmt = "0.0000"), rows = 2:(nrow(df) + 1), cols = num, gridExpand = TRUE)
    setColWidths(wb, k, seq_along(df), pmin(60, pmax(10, nchar(names(df)) + 2, sapply(df, function(x) max(nchar(as.character(head(x, 200))), na.rm = TRUE)) + 2)))
  }
  addWorksheet(wb, "Charts"); row <- 1
  for (f in charts) { insertImage(wb, "Charts", f, startRow = row, startCol = 1, width = 10, height = 6, units = "in"); row <- row + 32 }
  saveWorkbook(wb, file.path(out, file), overwrite = TRUE)
  file.path(out, file)
}

# ------------------------------- RUN -------------------------------------------------
res <- run_analysis(SETTINGS)
note <- if (nzchar(SETTINGS$note)) SETTINGS$note else "Source: MSCI US REIT Index (total return), S&P 500, FRED DGS10 and DBAA."
charts <- make_charts(SETTINGS$out, res$meta, note)
wbfile <- make_workbook(SETTINGS$out, res$meta, charts)
cat("Wrote", paste(basename(charts), collapse = ", "), "and", basename(wbfile), "\n")

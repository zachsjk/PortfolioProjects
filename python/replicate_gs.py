"""
EC4333 group project -- Are US REITs bond proxies?
Replication and extension of Giliberto & Shulman (rev. 8.17.2016),
"On the Interest Rate Sensitivity of REITs: Evidence from Twenty Years of Daily Data".

What this script does
---------------------
1. Loads daily series: MSCI US REIT total-return index (paper's "RMS"), S&P 500 price
   index, 10-year Treasury CMT yield (FRED DGS10) and Moody's Baa yield (FRED DBAA).
   Optional: MSCI US REIT price-only index (robustness) and DGS2 (not used in the paper).
2. Keeps only dates on which ALL required series have a value, THEN computes returns
   and yield changes over consecutive common dates.  No values are filled or imputed;
   dropped dates are counted in the Data_Audit sheet.
3. Builds the paper's imputed bond returns (Section III): a par bond (price 100,
   coupon = previous day's yield, semi-annual coupons, 10 years to maturity) re-priced
   at today's yield.  Same for Baa.  Excess credit return = Baa return - Treasury return.
4. Replicates Exhibits 4-8 on the overlap with the paper's window (ends 30 Mar 2016),
   compares with the paper's published numbers, then extends to the end of the data.
5. Robustness: robust standard errors (HC3, Newey-West), lagged dependent variable
   (paper fn 11), price vs total return (paper fn 6), weekly frequency, and an
   alternative (Fed-policy) sub-period definition for the extension.
6. Investor implications: % return per +100bp move in the 10Y yield, by period.

Units (as in the paper): returns are DECIMALS (0.01 = 1%), yield changes are in
PERCENTAGE POINTS (0.01 = 1bp).  So a coefficient of -0.081 on dYield means
-8.1% per +100bp.  Intercepts are reported x1000, as in the paper.

Usage
-----
python replicate_gs.py --data DATA.xlsx --out results_dir
  [--reit-sheet ... --spx-sheet ... --y10-sheet ... --baa-sheet ... --reit-price-sheet ...]
Each sheet: first column = date, value column chosen by --*-col or auto-detected.
"""
import argparse, os, re, json, warnings
import numpy as np, pandas as pd
import statsmodels.api as sm

warnings.filterwarnings("ignore", category=FutureWarning)

# ----------------------------------------------------------------------------------
# Paper constants (transcribed from the paper; page numbers refer to the PDF)
# ----------------------------------------------------------------------------------
PAPER_START, PAPER_END = "1995-01-03", "2016-03-30"
PAPER_SUBPERIODS = [  # Exhibit 3 (p.24)
    ("Mid 90s REIT Bull Market", "1995-01-03", "1997-10-06"),
    ("Late 90s REIT Bear Market", "1997-10-07", "1999-12-15"),
    ("2000s Bull Market", "1999-12-16", "2007-02-07"),
    ("Crash", "2007-02-08", "2009-03-06"),
    ("Surge", "2009-03-07", "2013-05-21"),
    ("Taper Tantrum and Beyond", "2013-05-22", "2016-03-30"),
]
PAPER_N = {"Mid 90s REIT Bull Market": 694, "Late 90s REIT Bear Market": 547, "2000s Bull Market": 1781,
           "Crash": 519, "Surge": 1051, "Taper Tantrum and Beyond": 713, "Full Period": 5305}
# Post-Lehman year (Exhibit 8, p.32): 250 obs = 118 in Crash + 132 in Surge.
LEHMAN = ("2008-09-15", "2009-09-14")

# Fed-policy regimes for the extension (robustness to the sub-period definition).
# FOMC dates: liftoff from zero 16 Mar 2022, last hike 26 Jul 2023, first cut 18 Sep 2024.
FED_REGIMES = [
    ("Pre-COVID", "2016-03-31", "2020-02-19"),
    ("COVID & zero rates", "2020-02-20", "2022-03-15"),
    ("Hiking cycle", "2022-03-16", "2023-07-26"),
    ("Hold at peak", "2023-07-27", "2024-09-17"),
    ("Since first cut", "2024-09-18", "2100-01-01"),
]

# Exhibit 4 descriptive stats (% daily): (mean, std) for each series, and N
PAPER_EX4 = {
    "Crash": dict(tsy=(0.0328, 0.6399), baa=(-0.0240, 0.4878), exc=(-0.0568, 0.3830),
                  reit=(-0.1872, 3.8562), spx=(-0.1392, 1.9889), N=519),
    "Surge": dict(tsy=(0.0075, 0.5480), baa=(0.0241, 0.4603), exc=(0.0165, 0.2618),
                  reit=(0.1586, 2.2371), spx=(0.0871, 1.2074), N=1051),
    "Taper Tantrum and Beyond": dict(tsy=(0.0010, 0.4315), baa=(-0.0021, 0.3643), exc=(-0.0032, 0.1980),
                                     reit=(0.0309, 1.0074), spx=(0.0353, 0.8559), N=713),
    "2000s Bull Market": dict(tsy=(0.0062, 0.4572), baa=(0.0082, 0.3272), exc=(0.0020, 0.2331),
                              reit=(0.0947, 0.8945), spx=(0.0083, 1.1236), N=1781),
}
# Exhibit 7 (pp.29-31): coefficient, t-stat.  Panel A: REIT on Tsy + Excess.
# Panel B: S&P on Tsy + Excess.  Panel C: REIT on Tsy + Excess + S&P.
PAPER_EX7 = {
    "A": {"Mid 90s REIT Bull Market": dict(b1=(0.418, 1.875), b2=(0.159, 0.295)),
          "Late 90s REIT Bear Market": dict(b1=(0.182, 0.672), b2=(0.687, 1.398)),
          "2000s Bull Market": dict(b1=(0.224, 1.805), b2=(0.820, 3.361)),
          "Crash": dict(b1=(-1.838, -12.488), b2=(0.687, 2.794)),
          "Surge": dict(b1=(-1.328, -12.105), b2=(-0.526, -2.291)),
          "Taper Tantrum and Beyond": dict(b1=(0.255, 1.515), b2=(-0.005, -0.014))},
    "B": {"Mid 90s REIT Bull Market": dict(b1=(0.995, 6.618), b2=(0.173, 0.477)),
          "Late 90s REIT Bear Market": dict(b1=(0.463, 2.539), b2=(1.418, 4.279)),
          "2000s Bull Market": dict(b1=(-0.211, -2.514), b2=(1.233, 7.506)),
          "Crash": dict(b1=(-1.058, -10.672), b2=(0.946, 5.707)),
          "Surge": dict(b1=(-1.147, -15.519), b2=(-0.538, -3.481)),
          "Taper Tantrum and Beyond": dict(b1=(-0.606, -5.366), b2=(0.070, 0.282))},
    "C": {"Mid 90s REIT Bull Market": dict(b1=(0.237, 1.506), b2=(0.127, 0.365), b3=(0.182, 2.882)),
          "Late 90s REIT Bear Market": dict(b1=(0.058, 0.329), b2=(0.307, 0.954), b3=(0.268, 7.408)),
          "2000s Bull Market": dict(b1=(0.305, 3.796), b2=(0.345, 2.153), b3=(0.385, 16.396)),
          "Crash": dict(b1=(-0.066, -0.671), b2=(-0.896, -5.572), b3=(1.674, 63.160)),
          "Surge": dict(b1=(0.493, 6.247), b2=(0.329, 2.205), b3=(1.588, 52.169)),
          "Taper Tantrum and Beyond": dict(b1=(0.806, 7.148), b2=(-0.069, -0.290), b3=(0.909, 18.711))},
}
PAPER_EX8 = {  # coefficient, t ; N ; adj R2
    "Entire post-Lehman year": dict(b1=(-0.223, -0.715), b2=(-0.778, -1.657), b3=(1.879, 23.779), N=250, r2=0.718),
    "Portion in Crash": dict(b1=(-0.140, -0.342), b2=(-0.933, -1.633), b3=(1.761, 19.141), N=118, r2=0.715),
    "Portion in Surge": dict(b1=(0.083, 0.169), b2=(0.586, 0.678), b3=(2.447, 14.861), N=132, r2=0.762),
}
# Full-sample (1995-2016) results -- comparable only if the data start in Jan 1995.
PAPER_EX5 = {  # dependent: (b1, t1, b2, t2, adjR2)
    "10Y Treasury": (-0.081, -1076.872, None, None, 0.995),
    "Baa (yield only)": (-0.054, -122.729, None, None, 0.739),
    "Baa": (-0.072, -1270.571, -0.072, -643.136, 0.997),
    "S&P 500": (0.045, 14.875, -0.028, -4.680, 0.071),
    "Equity REIT": (0.046, 10.302, -0.010, -1.178, 0.028),
}
PAPER_EX6 = {"A": dict(b1=(-0.516, -8.177), b2=(0.326, 2.635), r2=0.032),
             "B": dict(b1=(-0.032, -0.651), b2=(-0.149, -1.568), b3=(0.948, 61.627), r2=0.436)}

NW_LAGS = 5  # Newey-West lags for daily data (one trading week)

# ----------------------------------------------------------------------------------
# 1. Loading
# ----------------------------------------------------------------------------------
def _find_sheet(sheets, explicit, patterns):
    if explicit:
        if explicit not in sheets:
            raise SystemExit(f"Sheet '{explicit}' not found. Sheets: {list(sheets)}")
        return explicit
    for p in patterns:
        for s in sheets:
            if re.search(p, s, re.I):
                return s
    return None


def load_series(xl, sheet, col=None, name="x"):
    """First column = dates; value column = `col`, else 'Price'/'Close', else column 2."""
    df = xl.parse(sheet)
    dcol = df.columns[0]
    if col is None:
        for c in df.columns[1:]:
            if str(c).strip().lower() in ("price", "close", "adj close", "px_last", "value"):
                col = c; break
        else:
            col = df.columns[1]
    s = df[[dcol, col]].copy()
    s.columns = ["date", name]
    s["date"] = pd.to_datetime(s["date"], errors="coerce")
    s[name] = pd.to_numeric(s[name].astype(str).str.replace(",", "").str.strip(), errors="coerce")
    raw_n = len(s)
    s = s.dropna(subset=["date"]).sort_values("date")
    dups = int(s["date"].duplicated().sum())
    s = s.drop_duplicates("date", keep="last").set_index("date")[name]
    missing = int(s.isna().sum())
    s = s.dropna()
    audit = dict(series=name, sheet=sheet, column=str(col), raw_rows=raw_n, duplicate_dates=dups,
                 blank_or_nonnumeric=missing, usable=len(s),
                 first=s.index.min().date(), last=s.index.max().date())
    return s, audit


def par_bond_return(y_prev, y_now, years=10, freq=2):
    """Paper Section III: price 100, coupon = prior yield; re-price at today's yield with
    exactly `years` remaining.  Returns a DECIMAL price return.  Vectorised."""
    c = np.asarray(y_prev) / 100 / freq
    r = np.asarray(y_now) / 100 / freq
    n = years * freq
    annuity = np.where(np.abs(r) > 1e-12, (1 - (1 + r) ** -n) / np.where(r == 0, 1, r), n)
    price = 100 * c * annuity + 100 * (1 + r) ** -n
    return (price - 100) / 100


def build_daily(series, method="paper"):
    """Two ways to line up daily returns (nothing is filled or imputed in either):
    'paper'   -- as in the paper: each return/yield change is computed on its OWN market's
                 calendar, then dates where every series has a value are kept.  On a day
                 after a bond-market holiday (e.g. Columbus Day) the stock return is one day
                 but the bond return spans two days (paper fn 9: 51 such obs).
    'aligned' -- keep common dates FIRST, then difference, so every variable spans the same
                 interval (stock returns across a bond holiday are then two-day returns)."""
    lv = pd.concat(series, axis=1, join="inner").sort_index()
    if method == "paper":
        eq = {k: series[k] for k in series if k in ("reit_tr", "reit_pr", "spx")}
        yl = pd.concat([series["y10"], series["baa"]], axis=1, join="inner").sort_index()
        d = pd.DataFrame({"reit": eq["reit_tr"].pct_change(), "spx": eq["spx"].pct_change()})
        if "reit_pr" in eq:
            d["reit_pr"] = eq["reit_pr"].pct_change()
        b = pd.DataFrame(index=yl.index)
        b["y10"], b["baa"] = yl["y10"], yl["baa"]
        b["dy10"] = yl["y10"].diff()
        b["dspread"] = (yl["baa"] - yl["y10"]).diff()
        b["tsy"] = np.r_[np.nan, par_bond_return(yl["y10"].values[:-1], yl["y10"].values[1:])]
        b["baa_ret"] = np.r_[np.nan, par_bond_return(yl["baa"].values[:-1], yl["baa"].values[1:])]
        b["exc"] = b["baa_ret"] - b["tsy"]
        prev_eq = pd.Series(eq["spx"].index, index=eq["spx"].index).shift(1)
        prev_bd = pd.Series(yl.index, index=yl.index).shift(1)
        d = d.join(b, how="inner").dropna(subset=["reit", "spx", "tsy", "exc"])
        d["interval_mismatch"] = (prev_eq.reindex(d.index) != prev_bd.reindex(d.index)).astype(int)
        d["gap_days"] = pd.Series(d.index, index=d.index).diff().dt.days
        return d, lv
    d = pd.DataFrame(index=lv.index)
    d["reit"] = lv["reit_tr"].pct_change()
    d["spx"] = lv["spx"].pct_change()
    d["y10"] = lv["y10"]
    d["baa"] = lv["baa"]
    d["dy10"] = lv["y10"].diff()
    d["dspread"] = (lv["baa"] - lv["y10"]).diff()
    d["tsy"] = np.r_[np.nan, par_bond_return(lv["y10"].values[:-1], lv["y10"].values[1:])]
    d["baa_ret"] = np.r_[np.nan, par_bond_return(lv["baa"].values[:-1], lv["baa"].values[1:])]
    d["exc"] = d["baa_ret"] - d["tsy"]
    if "reit_pr" in lv:
        d["reit_pr"] = lv["reit_pr"].pct_change()
    d["gap_days"] = pd.Series(lv.index, index=lv.index).diff().dt.days
    d["interval_mismatch"] = 0
    d = d.iloc[1:]
    return d, lv


# ----------------------------------------------------------------------------------
# 2. Estimation helpers
# ----------------------------------------------------------------------------------
def ols(y, X, cov="nonrobust"):
    Xc = sm.add_constant(X, has_constant="add")
    m = sm.OLS(y, Xc, missing="drop")
    if cov == "nonrobust":
        return m.fit()
    if cov == "HC3":
        return m.fit(cov_type="HC3")
    return m.fit(cov_type="HAC", cov_kwds={"maxlags": NW_LAGS})


def dw(res):
    e = res.resid.values
    return float(np.sum(np.diff(e) ** 2) / np.sum(e ** 2))


def tidy(res, label, extra=None):
    rows = []
    for k in res.params.index:
        ci = res.conf_int().loc[k]
        rows.append(dict(model=label, term=k, coef=res.params[k], se=res.bse[k], t=res.tvalues[k],
                         p=res.pvalues[k], ci_low=ci[0], ci_high=ci[1]))
    out = pd.DataFrame(rows)
    out["adj_r2"] = res.rsquared_adj
    out["r2"] = res.rsquared
    out["DW"] = dw(res)
    out["N"] = int(res.nobs)
    out["se_type"] = getattr(res, "cov_type", "nonrobust")
    if extra:
        for k, v in extra.items():
            out[k] = v
    return out


def window(d, a, b):
    return d.loc[pd.Timestamp(a):pd.Timestamp(b)]


def periods_in(d, periods, lo, hi, min_obs=30):
    """Clip a list of (name,start,end) to [lo,hi] and to the data; flag partial periods."""
    out = []
    for name, a, b in periods:
        a2, b2 = max(pd.Timestamp(a), pd.Timestamp(lo)), min(pd.Timestamp(b), pd.Timestamp(hi))
        sub = window(d, a2, b2)
        if len(sub) < min_obs:
            continue
        partial = (sub.index.min() - pd.Timestamp(a)).days > 7 or (pd.Timestamp(b) - sub.index.max()).days > 7
        out.append((name + (" (partial)" if partial and pd.Timestamp(b) < pd.Timestamp("2100-01-01") else ""),
                    sub.index.min(), sub.index.max(), partial))
    return out


def system(d, periods, yname, xnames, cov="nonrobust"):
    """Paper's 'system': one regression with period dummies interacted with every
    regressor (incl. intercept), so all periods are estimated jointly and coefficients
    can be compared with Wald tests."""
    cols, keep = {}, pd.Series(False, index=d.index)
    for name, a, b, _ in periods:
        D = ((d.index >= a) & (d.index <= b)).astype(float)
        keep |= D.astype(bool)
        cols[f"a|{name}"] = D
        for x in xnames:
            cols[f"{x}|{name}"] = D * d[x].values
    X = pd.DataFrame(cols, index=d.index)[keep]
    y = d.loc[keep, yname]
    m = sm.OLS(y, X, hasconst=True)
    if cov == "nonrobust":
        res = m.fit()
    elif cov == "HC3":
        res = m.fit(cov_type="HC3")
    else:
        res = m.fit(cov_type="HAC", cov_kwds={"maxlags": NW_LAGS})
    return res


def system_table(res, periods, xnames, label):
    rows = []
    for name, a, b, partial in periods:
        n = int(((res.model.exog[:, list(res.params.index).index(f"a|{name}")]) > 0).sum())
        for x in ["a"] + xnames:
            k = f"{x}|{name}"
            ci = res.conf_int().loc[k]
            rows.append(dict(model=label, period=name, start=a.date(), end=b.date(), N=n, term=x,
                             coef=res.params[k] * (1000 if x == "a" else 1),
                             t=res.tvalues[k], p=res.pvalues[k],
                             ci_low=ci[0] * (1000 if x == "a" else 1), ci_high=ci[1] * (1000 if x == "a" else 1)))
    out = pd.DataFrame(rows)
    out["system_adj_r2"] = res.rsquared_adj
    out["system_DW"] = dw(res)
    return out


def wald_equal(res, periods, x, label):
    """Joint test that coefficient x is equal across all periods, plus all pairs."""
    names = list(res.params.index)
    keys = [f"{x}|{p[0]}" for p in periods]
    dist = "F" if res.use_t else "chi2"
    rows = []
    if len(keys) > 1:
        R = np.zeros((len(keys) - 1, len(names)))
        for i, k in enumerate(keys[1:]):
            R[i, names.index(keys[0])] = 1; R[i, names.index(k)] = -1
        w = res.wald_test(R, scalar=True)
        rows.append(dict(model=label, coef=x, test="all periods equal", stat=float(w.statistic), dist=dist,
                         df=int(R.shape[0]), p=float(w.pvalue)))
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                R = np.zeros((1, len(names))); R[0, names.index(keys[i])] = 1; R[0, names.index(keys[j])] = -1
                w = res.wald_test(R, scalar=True)
                rows.append(dict(model=label, coef=x, test=f"{periods[i][0]} = {periods[j][0]}",
                                 stat=float(w.statistic), dist=dist, df=1, p=float(w.pvalue)))
    return rows


# ----------------------------------------------------------------------------------
# 3. Turning points of the REIT index (paper's "low tech" sub-period method)
# ----------------------------------------------------------------------------------
def turning_points(level, threshold=0.20):
    """Alternating peaks/troughs: a new pivot is confirmed once the index moves
    `threshold` away from the running extreme.  Returns list of (date, kind)."""
    p = level.dropna()
    piv = [(p.index[0], "start")]
    trend, ext_d, ext_v = 0, p.index[0], p.iloc[0]
    hi_d, hi_v, lo_d, lo_v = ext_d, ext_v, ext_d, ext_v
    for d, v in p.items():
        if trend == 0:
            if v > hi_v: hi_d, hi_v = d, v
            if v < lo_v: lo_d, lo_v = d, v
            if v >= lo_v * (1 + threshold): trend, ext_d, ext_v = 1, d, v; piv.append((lo_d, "trough"))
            elif v <= hi_v * (1 - threshold): trend, ext_d, ext_v = -1, d, v; piv.append((hi_d, "peak"))
        elif trend == 1:
            if v > ext_v: ext_d, ext_v = d, v
            elif v <= ext_v * (1 - threshold): piv.append((ext_d, "peak")); trend, ext_d, ext_v = -1, d, v
        else:
            if v < ext_v: ext_d, ext_v = d, v
            elif v >= ext_v * (1 + threshold): piv.append((ext_d, "trough")); trend, ext_d, ext_v = 1, d, v
    if piv[-1][0] != p.index[-1]:
        piv.append((p.index[-1], "end"))
    # drop a 'start' pivot that coincides with the first confirmed pivot
    piv = [x for i, x in enumerate(piv) if i == 0 or x[0] != piv[i - 1][0]]
    return piv


def legs_from_pivots(piv, level):
    legs = []
    for (a, _), (b, kind_b) in zip(piv[:-1], piv[1:]):
        chg = level.loc[b] / level.loc[a] - 1
        tag = "REIT up" if chg > 0 else "REIT down"
        legs.append((f"{tag} {a:%b %Y}-{b:%b %Y} ({chg:+.0%})", a, b))
    # make legs non-overlapping: each leg starts the trading day after the previous ends
    out = []
    for i, (n, a, b) in enumerate(legs):
        start = a if i == 0 else level.index[level.index.get_loc(a) + 1]
        out.append((n, start.strftime("%Y-%m-%d"), b.strftime("%Y-%m-%d")))
    return out


# ----------------------------------------------------------------------------------
# 4. Main analysis
# ----------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default="results")
    ap.add_argument("--reit-sheet"); ap.add_argument("--reit-col")
    ap.add_argument("--reit-price-sheet"); ap.add_argument("--reit-price-col")
    ap.add_argument("--spx-sheet"); ap.add_argument("--spx-col")
    ap.add_argument("--y10-sheet"); ap.add_argument("--y10-col")
    ap.add_argument("--baa-sheet"); ap.add_argument("--baa-col")
    ap.add_argument("--tp-threshold", type=float, default=0.20)
    ap.add_argument("--label", default="")
    ap.add_argument("--method", choices=["paper", "aligned"], default="paper")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    xl = pd.ExcelFile(a.data)
    sh = xl.sheet_names
    spec = {
        "reit_tr": (_find_sheet(sh, a.reit_sheet, [r"reit.*(total|tr|gross)", r"rms", r"reit"]), a.reit_col),
        "spx": (_find_sheet(sh, a.spx_sheet, [r"s&p|spx|sp500|s.p 500"]), a.spx_col),
        "y10": (_find_sheet(sh, a.y10_sheet, [r"dgs10", r"10.?y"]), a.y10_col),
        "baa": (_find_sheet(sh, a.baa_sheet, [r"dbaa|baa"]), a.baa_col),
    }
    rp = _find_sheet(sh, a.reit_price_sheet, [r"reit.*price", r"rmz"]) if a.reit_price_sheet else None
    if rp: spec["reit_pr"] = (rp, a.reit_price_col)
    missing = [k for k, (s, _) in spec.items() if s is None]
    if missing:
        raise SystemExit(f"Could not find sheets for {missing}. Sheets present: {sh}")

    series, audit = {}, []
    for k, (s, c) in spec.items():
        series[k], au = load_series(xl, s, c, k)
        audit.append(au)
    d, lv = build_daily(series, a.method)
    d_alt, _ = build_daily(series, "aligned" if a.method == "paper" else "paper")
    audit_df = pd.DataFrame(audit)
    common = dict(series="COMMON (all required series present)", usable=len(lv),
                  first=lv.index.min().date(), last=lv.index.max().date())
    audit_df = pd.concat([audit_df, pd.DataFrame([common])], ignore_index=True)
    multi_gap = int((d["gap_days"] > 4).sum())
    mism = int(d["interval_mismatch"].sum())
    notes = [f"Daily observations used: {len(d)} ({d.index.min().date()} to {d.index.max().date()}).",
             f"Observations spanning >4 calendar days (holiday gaps or a series missing that day): {multi_gap}.",
             f"Alignment method: {a.method}. Observations where stock and bond returns span different intervals: {mism} (paper fn 9 reports 51 over 1995-2016).",
             "No values were filled or imputed; dates missing from any series are dropped."]

    data_start, data_end = d.index.min(), d.index.max()
    rep_lo, rep_hi = max(data_start, pd.Timestamp(PAPER_START)), pd.Timestamp(PAPER_END)
    full_replication = data_start <= pd.Timestamp("1995-01-10")
    R = {}  # all output tables

    # ---------------- Exhibit 4 / 1: descriptive stats ----------------
    rep_periods = periods_in(d, PAPER_SUBPERIODS, rep_lo, rep_hi)
    cols = {"tsy": "10Y Treasury price return", "baa_ret": "Baa price return", "exc": "Baa excess return",
            "reit": "REIT total return", "spx": "S&P 500 price return"}
    desc_rows = []
    def describe(sub, label):
        for c, nm in cols.items():
            x = sub[c] * 100
            desc_rows.append(dict(period=label, series=nm, mean_pct=x.mean(), median_pct=x.median(),
                                  max_pct=x.max(), min_pct=x.min(), sd_pct=x.std(), N=len(x)))
    describe(window(d, rep_lo, rep_hi), "Replication window")
    for name, s0, s1, _ in rep_periods:
        describe(window(d, s0, s1), name)
    R["Ex4_DescStats"] = pd.DataFrame(desc_rows)

    # ---------------- Exhibit 2: correlations ----------------
    R["Ex2_Correlations"] = window(d, rep_lo, rep_hi)[list(cols)].rename(columns=cols).corr()

    # ---------------- Exhibit 5: yield-change regressions ----------------
    def ex5(sub, tag):
        out = []
        specs = [("10Y Treasury", "tsy", ["dy10"]), ("Baa (yield only)", "baa_ret", ["dy10"]),
                 ("Baa", "baa_ret", ["dy10", "dspread"]), ("S&P 500", "spx", ["dy10", "dspread"]),
                 ("Equity REIT", "reit", ["dy10", "dspread"])]
        for nm, yv, xs in specs:
            out.append(tidy(ols(sub[yv], sub[xs]), nm, {"sample": tag}))
        return pd.concat(out)

    # ---------------- Exhibit 6: bond-return regressions ----------------
    def ex6(sub, tag, cov="nonrobust"):
        A = tidy(ols(sub["reit"], sub[["tsy", "exc"]], cov), "A: REIT ~ Tsy + Excess", {"sample": tag, "se_type": cov})
        resB = ols(sub["reit"], sub[["tsy", "exc", "spx"]], cov)
        B = tidy(resB, "B: REIT ~ Tsy + Excess + S&P", {"sample": tag, "se_type": cov})
        t1 = resB.t_test("spx = 1")
        B["test_equity_beta_eq_1_p"] = float(t1.pvalue)
        return pd.concat([A, B])

    rep = window(d, rep_lo, rep_hi)
    ext = window(d, pd.Timestamp(PAPER_END) + pd.Timedelta(days=1), data_end)
    full = d
    tag_rep = f"Replication {rep.index.min():%d %b %Y}-{rep.index.max():%d %b %Y}"
    tag_ext = f"Extension {ext.index.min():%d %b %Y}-{ext.index.max():%d %b %Y}" if len(ext) else None
    tag_full = f"Full {full.index.min():%d %b %Y}-{full.index.max():%d %b %Y}"
    R["Ex5_YieldRegs"] = pd.concat([ex5(rep, tag_rep)] + ([ex5(ext, tag_ext)] if len(ext) else []) + [ex5(full, tag_full)])
    R["Ex6_BondRegs"] = pd.concat([ex6(rep, tag_rep)] + ([ex6(ext, tag_ext)] if len(ext) else []) + [ex6(full, tag_full)])

    # ---------------- Exhibit 7: sub-period system ----------------
    ex7, wald = [], []
    def run_system(per, tag):
        for panel, yv, xs in [("A", "reit", ["tsy", "exc"]), ("B", "spx", ["tsy", "exc"]),
                              ("C", "reit", ["tsy", "exc", "spx"])]:
            res = system(d, per, yv, xs)
            t = system_table(res, per, xs, f"{tag} | Panel {panel}")
            t["panel"] = panel; t["sample"] = tag
            ex7.append(t)
            for x in xs:
                for r in wald_equal(res, per, x, f"{tag} | Panel {panel}"):
                    r["se_type"] = "OLS"; wald.append(r)
            if panel == "C":  # robust versions of the key Wald tests
                for cov in ("HAC",):
                    rr = system(d, per, yv, xs, cov)
                    for x in xs:
                        for r in wald_equal(rr, per, x, f"{tag} | Panel {panel}"):
                            r["se_type"] = f"Newey-West({NW_LAGS})"; wald.append(r)
    run_system(rep_periods, "Replication sub-periods")

    # Extension sub-periods: (i) paper's method = REIT index turning points; (ii) Fed regimes
    ext_tp_periods, tp_table = [], pd.DataFrame()
    if len(ext) > 250:
        lvl = series["reit_tr"].loc[ext.index.min() - pd.Timedelta(days=5):]
        piv = turning_points(lvl.loc[ext.index.min():], a.tp_threshold)
        legs = legs_from_pivots(piv, lvl)
        tp_table = pd.DataFrame([dict(date=p[0].date(), kind=p[1], index_level=lvl.loc[p[0]]) for p in piv])
        ext_tp_periods = periods_in(d, legs, ext.index.min(), data_end, min_obs=20)
        run_system(ext_tp_periods, "Extension: REIT turning points")
        ext_fed_periods = periods_in(d, FED_REGIMES, ext.index.min(), data_end)
        run_system(ext_fed_periods, "Extension: Fed regimes")
    else:
        ext_fed_periods = []
    R["Ex7_SubPeriods"] = pd.concat(ex7)
    R["Wald_Tests"] = pd.DataFrame(wald)
    if len(tp_table): R["Ext_TurningPoints"] = tp_table

    # ---------------- Exhibit 8: post-Lehman year ----------------
    ex8 = []
    lw = window(d, *LEHMAN)
    if len(lw) > 200:
        crash_end = pd.Timestamp("2009-03-06")
        # Panel A: one regression.  Panels B and C: the paper estimates the two portions jointly
        # (dummy system, pooled residual variance), which reproduces its t-stats.
        ex8.append(tidy(ols(lw["reit"], lw[["tsy", "exc", "spx"]]), "Entire post-Lehman year"))
        per = [("Crash part", lw.index.min(), crash_end, False),
               ("Surge part", lw.loc[crash_end + pd.Timedelta(days=1):].index.min(), lw.index.max(), False)]
        res = system(d, per, "reit", ["tsy", "exc", "spx"])
        st = system_table(res, per, ["tsy", "exc", "spx"], "post-Lehman system")
        for part, nm in [("Crash part", "Portion in Crash"), ("Surge part", "Portion in Surge")]:
            o = st[st.period == part].copy()
            sc = np.where(o.term == "a", 1000, 1)
            ex8.append(pd.DataFrame(dict(model=nm, term=np.where(o.term == "a", "const", o.term), coef=o.coef / sc,
                                         se=(o.coef / sc) / o.t, t=o.t, p=o.p, ci_low=o.ci_low / sc, ci_high=o.ci_high / sc,
                                         adj_r2=o.system_adj_r2, r2=np.nan, DW=o.system_DW, N=o.N,
                                         se_type="nonrobust (system)")))
        for x in ["tsy", "exc", "spx"]:
            for r in wald_equal(res, per, x, "Post-Lehman year"):
                r["se_type"] = "OLS"; wald.append(r)
        R["Wald_Tests"] = pd.DataFrame(wald)
        R["Ex8_PostLehman"] = pd.concat(ex8)

    # ---------------- Replication vs paper ----------------
    cmp = []
    e7 = R["Ex7_SubPeriods"]
    e7r = e7[e7["sample"] == "Replication sub-periods"]
    termmap = {"b1": "tsy", "b2": "exc", "b3": "spx"}
    for panel, per_d in PAPER_EX7.items():
        for per, coefs in per_d.items():
            row_ours = e7r[(e7r.panel == panel) & (e7r.period == per)]
            if row_ours.empty:
                continue
            for b, (pc, pt) in coefs.items():
                r = row_ours[row_ours.term == termmap[b]].iloc[0]
                cmp.append(dict(exhibit="Exhibit 7", panel=panel, period=per, coef=f"{b} ({termmap[b]})",
                                paper=pc, ours=r.coef, diff=r.coef - pc, paper_t=pt, our_t=r.t,
                                paper_N=PAPER_N.get(per), our_N=r.N,
                                same_sign=np.sign(pc) == np.sign(r.coef),
                                same_signif_5pct=(abs(pt) > 1.96) == (abs(r.t) > 1.96)))
    if "Ex8_PostLehman" in R:
        for nm, vals in PAPER_EX8.items():
            o = R["Ex8_PostLehman"][R["Ex8_PostLehman"].model == nm]
            for b in ("b1", "b2", "b3"):
                r = o[o.term == termmap[b]].iloc[0]
                pc, pt = vals[b]
                cmp.append(dict(exhibit="Exhibit 8", panel="", period=nm, coef=f"{b} ({termmap[b]})", paper=pc,
                                ours=r.coef, diff=r.coef - pc, paper_t=pt, our_t=r.t, paper_N=vals["N"],
                                our_N=r.N, same_sign=np.sign(pc) == np.sign(r.coef),
                                same_signif_5pct=(abs(pt) > 1.96) == (abs(r.t) > 1.96)))
    ds = R["Ex4_DescStats"]
    keymap = {"tsy": "10Y Treasury price return", "baa": "Baa price return", "exc": "Baa excess return",
              "reit": "REIT total return", "spx": "S&P 500 price return"}
    for per, v in PAPER_EX4.items():
        sub = ds[ds.period == per]
        if sub.empty:
            continue
        for k, nm in keymap.items():
            r = sub[sub.series == nm].iloc[0]
            for stat, idx in (("mean_pct", 0), ("sd_pct", 1)):
                cmp.append(dict(exhibit="Exhibit 4", panel="", period=per, coef=f"{nm}: {stat}",
                                paper=v[k][idx], ours=r[stat], diff=r[stat] - v[k][idx],
                                paper_N=v["N"], our_N=r.N))
    if full_replication:
        e5 = R["Ex5_YieldRegs"]; e5 = e5[e5["sample"] == tag_rep]
        for nm, (b1, t1, b2, t2, r2) in PAPER_EX5.items():
            o = e5[e5.model == nm]
            r = o[o.term == "dy10"].iloc[0]
            cmp.append(dict(exhibit="Exhibit 5", period="Full", coef=f"{nm}: dYield10", paper=b1, ours=r.coef,
                            diff=r.coef - b1, paper_t=t1, our_t=r.t, paper_N=5305, our_N=r.N))
        e6 = R["Ex6_BondRegs"]; e6 = e6[e6["sample"] == tag_rep]
        for pan, vals in PAPER_EX6.items():
            o = e6[e6.model.str.startswith(pan)]
            for b in ("b1", "b2", "b3"):
                if b in vals:
                    r = o[o.term == termmap[b]].iloc[0]
                    cmp.append(dict(exhibit="Exhibit 6", panel=pan, period="Full", coef=f"{b} ({termmap[b]})",
                                    paper=vals[b][0], ours=r.coef, diff=r.coef - vals[b][0],
                                    paper_t=vals[b][1], our_t=r.t, paper_N=5305, our_N=r.N))
    R["Replication_vs_Paper"] = pd.DataFrame(cmp)

    # ---------------- Robustness ----------------
    rob = []
    # (1) standard errors
    for tag, sub in [(tag_rep, rep)] + ([(tag_ext, ext)] if len(ext) else []) + [(tag_full, full)]:
        for cov in ("nonrobust", "HC3", "HAC"):
            t = ex6(sub, tag, cov); t["check"] = "SE choice"; rob.append(t)
    # (2) lagged dependent variable (paper fn 11)
    for tag, sub in [(tag_rep, rep)] + ([(tag_ext, ext)] if len(ext) else []):
        s2 = sub.assign(reit_lag=sub["reit"].shift(1)).dropna(subset=["reit_lag"])
        t = tidy(ols(s2["reit"], s2[["tsy", "exc", "spx", "reit_lag"]], "HAC"), "B + lagged REIT return",
                 {"sample": tag, "se_type": "HAC"}); t["check"] = "Lagged dependent variable"; rob.append(t)
    # (3) price-only REIT return (paper fn 6)
    if "reit_pr" in d:
        for tag, sub in [(tag_rep, rep)] + ([(tag_ext, ext)] if len(ext) else []):
            s2 = sub.dropna(subset=["reit_pr"])
            t = tidy(ols(s2["reit_pr"], s2[["tsy", "exc", "spx"]], "HAC"), "B with REIT PRICE return",
                     {"sample": tag, "se_type": "HAC"}); t["check"] = "Price vs total return"; rob.append(t)
    # (3b) the other way of lining up daily returns (paper vs aligned intervals)
    for tag, a0, b0 in [(tag_rep, rep_lo, rep_hi)] + ([(tag_ext, ext.index.min(), data_end)] if len(ext) else []):
        sub = window(d_alt, a0, b0)
        t = tidy(ols(sub["reit"], sub[["tsy", "exc", "spx"]], "HAC"),
                 f"B with {'aligned' if a.method == 'paper' else 'paper'} intervals", {"sample": tag, "se_type": "HAC"})
        t["check"] = "Interval alignment"; rob.append(t)
    # (4) weekly (Wednesday-to-Wednesday) frequency -- reduces close-time mismatch
    wk = lv.resample("W-WED").last().dropna()
    w = pd.DataFrame(index=wk.index)
    w["reit"] = wk["reit_tr"].pct_change(); w["spx"] = wk["spx"].pct_change()
    w["tsy"] = np.r_[np.nan, par_bond_return(wk["y10"].values[:-1], wk["y10"].values[1:])]
    w["exc"] = np.r_[np.nan, par_bond_return(wk["baa"].values[:-1], wk["baa"].values[1:])] - w["tsy"]
    w = w.dropna()
    for tag, a0, b0 in [(tag_rep, rep_lo, rep_hi)] + ([(tag_ext, ext.index.min(), data_end)] if len(ext) else []):
        sub = window(w, a0, b0)
        t = tidy(ols(sub["reit"], sub[["tsy", "exc", "spx"]], "HAC"), "B at weekly frequency",
                 {"sample": tag, "se_type": "HAC"}); t["check"] = "Weekly frequency"; rob.append(t)
    R["Robustness"] = pd.concat(rob)

    # ---------------- Investor implications: % per +100bp ----------------
    imp = []
    def per100(sub, label):
        rt = ols(sub["reit"], sub[["dy10"]], "HAC")            # total sensitivity
        sp = ols(sub["spx"], sub[["dy10"]], "HAC")
        ts = ols(sub["tsy"], sub[["dy10"]], "HAC")
        mg = ols(sub["reit"], sub[["dy10", "spx"]], "HAC")     # holding the stock market fixed
        eq = ols(sub["reit"], sub[["spx"]], "HAC")
        def pc(res, k):
            c = res.params[k]; lo, hi = res.conf_int().loc[k]
            return 100 * c, 100 * lo, 100 * hi
        r = dict(period=label, N=len(sub), avg_10y_yield=sub["y10"].mean())
        for nm, res in [("REIT_total", rt), ("SP500_total", sp), ("Treasury10Y", ts), ("REIT_marginal", mg)]:
            c, lo, hi = pc(res, "dy10")
            r[f"{nm}_pct_per_100bp"], r[f"{nm}_ci_low"], r[f"{nm}_ci_high"] = c, lo, hi
        r["REIT_equity_beta"] = eq.params["spx"]
        r["REIT_rate_R2"] = rt.rsquared
        r["REIT_equity_R2"] = eq.rsquared
        imp.append(r)
    per100(rep, tag_rep)
    for name, s0, s1, _ in rep_periods:
        per100(window(d, s0, s1), name)
    if len(ext):
        per100(ext, tag_ext)
        for name, s0, s1, _ in ext_fed_periods:
            per100(window(d, s0, s1), name)
    per100(full, tag_full)
    R["Implications_per100bp"] = pd.DataFrame(imp)

    # ---------------- Rolling one-year betas (for the chart) ----------------
    roll = []
    X = sm.add_constant(d[["tsy", "exc", "spx"]]).values
    y = d["reit"].values
    W = 250
    for i in range(W, len(d) + 1, 5):
        b = np.linalg.lstsq(X[i - W:i], y[i - W:i], rcond=None)[0]
        b_tot = np.polyfit(d["dy10"].values[i - W:i], y[i - W:i], 1)[0]
        roll.append(dict(date=d.index[i - 1], bond_beta_marginal=b[1], equity_beta=b[3], reit_pct_per_100bp_total=100 * b_tot))
    R["Rolling_250d"] = pd.DataFrame(roll)

    R["Data_Audit"] = audit_df
    d.to_csv(os.path.join(a.out, "daily_dataset.csv"))
    meta = dict(label=a.label, notes=notes, full_replication=bool(full_replication), tag_rep=tag_rep,
                tag_ext=tag_ext, tag_full=tag_full,
                rep_periods=[(p[0], str(p[1].date()), str(p[2].date())) for p in rep_periods],
                ext_tp_periods=[(p[0], str(p[1].date()), str(p[2].date())) for p in ext_tp_periods],
                ext_fed_periods=[(p[0], str(p[1].date()), str(p[2].date())) for p in ext_fed_periods])
    with open(os.path.join(a.out, "run_meta.json"), "w") as f:
        json.dump(meta, f, indent=2, default=str)
    for k, v in R.items():
        v.to_csv(os.path.join(a.out, f"{k}.csv"), index=(k == "Ex2_Correlations"))
    print("\n".join(notes))
    print(f"Tables written to {a.out}: {', '.join(R)}")


if __name__ == "__main__":
    main()

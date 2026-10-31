# Are US REITs bond proxies? (EC4333 group project)

Replication and extension of Giliberto, M. & Shulman, D. (rev. 17 Aug 2016), *On the Interest Rate
Sensitivity of REITs: Evidence from Twenty Years of Daily Data*, UCLA Ziman Center working paper.

## Folder layout
```
US REIT Sensitivity/
├── replicate_gs.R            # main script: replication, extension, charts, Excel workbook
├── fed_regimes_notebook.Rmd  # sensitivity analysis: Fed policy regimes (run second)
├── 4333_DATA.xlsx       # input data (one sheet per series; not in the repo)
├── REIT_RateSensitivity_Results                 
```

## Data (`data/4333_DATA.xlsx`)
| Sheet | Series | Source |
|---|---|---|
| `MSCI US REIT` | MSCI US REIT Index, gross total return (the paper's "RMS"), daily level | Bloomberg |
| `S&P 500 Historical Data` | S&P 500 price index, daily | Investing.com |
| `DGS10` | 10Y Treasury constant-maturity yield, % | FRED |
| `DBAA` | Moody's Baa corporate yield, % | FRED |

Sample: 1 Jun 2005 to 15 Oct 2026.

## Outputs (`results/`)
- `REIT_RateSensitivity_Results.xlsx`: every results table as a sheet, plus a README sheet and the charts.
  | Sheet | Contents | Slides |
  |---|---|---|
  | `Data_Audit` | rows per series and the common sample | 4 |
  | `Replication_vs_Paper` | our estimates next to the paper's, all 60 comparisons | 6, A1 |
  | `Ex4_DescStats` | Exhibit 4 statistics: replication sub-periods and 2016–26 turning-point sub-periods | descriptive statistics |
  | `Ex2_Correlations` | Exhibit 2 correlations, replication window | backup |
  | `Ex5_YieldRegs`, `Ex6_BondRegs` | Exhibits 5 and 6 (yield and bond-return regressions) | regression table, credit spreads |
  | `Ex7_SubPeriods`, `Wald_Tests` | Exhibit 7 sub-period systems and equality tests | 6, backup |
  | `Ex8_PostLehman` | Exhibit 8, post-Lehman year | 6, A1 |
  | `Ext_TurningPoints` | 2016–26 REIT turning points (20% rule) | descriptive statistics |
  | `Robustness` | HC3 / Newey-West errors, lagged REIT return, aligned intervals, weekly data | regression table, A4 |
  | `Implications_per100bp` | % return per +1pp for REITs, the S&P 500 and the bond, by period | 7, benchmark, A6 |
  | `Rolling_250d` | rolling one-year estimates | A5 |
  | `FedRegime_Episodes`, `FedRegime_Stances`, `FedRegime_Wald` | Fed-regime results (written by the notebook) | Fed slide, A2, A3 |
- `chart1_rolling_sensitivity.png`, `chart2_replication_check.png`, `chart3_benchmark_per100bp.png`, `chart4_fed_regimes.png`: the charts used in the slides
- `daily_dataset.csv`: the exact regression dataset (contains licensed REIT returns, so it is git-ignored and not submitted)

## Method notes
- Bond returns follow the paper: par bond priced at 100, coupon = previous day's yield, re-priced at
  today's yield with 10 years left (semi-annual coupons). Excess credit return = Baa return − Treasury return.
- Returns are aligned the paper's way: each market's return is computed on its own trading calendar and
  dates where every series exists are kept. This reproduces the paper's sample sizes exactly.
- Units: returns in decimals, yield changes in percentage points, so −0.081 on ΔYield = −8.1% per +100bp.
- Exhibits 7 and 8 are estimated as dummy-interaction "systems" with Wald tests, as in the paper.
- Main tables use OLS t-stats to compare with the paper; HC3 and Newey-West (5 lags) are in `Robustness`.

## Replication status
Our data start in June 2005, so we replicate the paper's last three sub-periods (Crash, Surge, Taper
Tantrum and Beyond) and the post-Lehman year (Exhibit 8). Exhibits 5 and 6 cover 1995–2016 and need
pre-2005 data.
- Sample sizes: identical (519 / 1,051 / 713 / 250).
- Exhibit 4 means and standard deviations: within 0.0002 percentage points.
- Exhibit 7 and 8 coefficients: all 30 within 0.003 of the paper.
- Exhibit 8 t-stats: match. Exhibit 7 t-stats are smaller than the paper's by a constant factor within each
  panel (about 1.33 in Panel A, 1.25 in Panel C). The paper's system pools the residual variance across all
  six sub-periods from 1995, including the calm 1990s; ours pools only 2005–2016. Coefficients are unaffected.

# Are US REITs bond proxies?

Replication and extension of Giliberto, M. & Shulman, D. (rev. 17 Aug 2016), *On the Interest Rate
Sensitivity of REITs: Evidence from Twenty Years of Daily Data*, UCLA Ziman Center working paper.

## Folder layout
```
US REIT Sensitivity/
├── replicate_gs.R        # main script: analysis + charts + Excel workbook
├── data/4333_DATA.xlsx   # input data (one sheet per series)
├── results/              # everything the script writes
└── python/               # Python version (gives identical tables)
```

## Data (`data/4333_DATA.xlsx`)
| Sheet | Series | Source |
|---|---|---|
| `MSCI US REIT` | MSCI US REIT Index, gross total return (the paper's "RMS"), daily level | Bloomberg |
| `S&P 500 Historical Data` | S&P 500 price index, daily | Investing.com |
| `DGS10` | 10Y Treasury constant-maturity yield, % | FRED |
| `DBAA` | Moody's Baa corporate yield, % | FRED |
| `DGS2` | 2Y Treasury yield (not used in the paper) | FRED |

Sample: 1 Jun 2005 to 15 Oct 2026. The REIT levels match the paper's Exhibit 3 index values exactly
(e.g. 1,851.94 on 30 Mar 2016). No values are filled or imputed.

## How to run
1. RStudio: *File → New Project → Existing Directory* → this folder.
2. Once: `install.packages(c("readxl", "openxlsx", "ggplot2", "sandwich", "jsonlite"))`
3. Open `replicate_gs.R` and click **Source**. Paths in the `SETTINGS` block are relative to the project folder.

Terminal alternative: `Rscript replicate_gs.R`

## Outputs (`results/`)
- `REIT_RateSensitivity_Results.xlsx`: every table, a README sheet and the charts
- `Replication_vs_Paper.csv`: our estimates next to the paper's, line by line
- `chart1_rolling_sensitivity.png`, `chart2_replication_check.png`, `chart3_benchmark_per100bp.png`
- one CSV per table, plus `daily_dataset.csv` (the exact regression dataset)

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

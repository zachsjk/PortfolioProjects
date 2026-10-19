US REIT rate sensitivity: replication of Giliberto & Shulman (2016)
Data needed (one Excel workbook, one sheet per series, column A = date)
Sheet name (suggested)	Series	Source
MSCI US REIT TR	MSCI US REIT Index, total return, daily level	Bloomberg / Refinitiv (paper's "RMS")
MSCI US REIT PR (optional)	same index, price only	Bloomberg / Refinitiv ("RMZ")
S&P 500 Historical Data	S&P 500 price index, daily	Investing.com / Yahoo / Bloomberg SPX Index
DGS10	10Y Treasury constant-maturity yield, %	FRED
DBAA	Moody's Baa corporate yield, %	FRED

Use the longest common history you can get (1995 onwards = full replication; 2005 onwards = partial).

Run in R (main version)
r
install.packages(c("readxl", "openxlsx", "ggplot2", "sandwich", "jsonlite"))

Open replicate_gs.R in RStudio, set data, out, reit_sheet and baa_sheet in the SETTINGS block, then Source the file. Or from a terminal:

Rscript replicate_gs.R --data=4333_DATA.xlsx --out=results --reit_sheet="MSCI US REIT TR" --baa_sheet=DBAA

The R and Python versions produce identical tables (checked to ~1e-11 on a test dataset).

Run in Python (same results)
pip install pandas numpy statsmodels matplotlib openpyxl
python replicate_gs.py --data 4333_DATA.xlsx --out results \
    --reit-sheet "MSCI US REIT TR" --baa-sheet "DBAA" [--reit-price-sheet "MSCI US REIT PR"]
python make_outputs.py --res results

Outputs in results/: REIT_RateSensitivity_Results.xlsx (all tables + charts), one CSV per table, daily_dataset.csv, three PNG charts.

Method choices (all documented in the workbook README sheet)
Returns aligned the paper's way by default (--method paper); --method aligned is the alternative and is also reported in the Robustness sheet.
Main tables use plain OLS t-stats so they compare with the paper; HC3 and Newey-West in Robustness.
No values filled or imputed.

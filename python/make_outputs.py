"""Charts + Excel workbook from the CSVs written by replicate_gs.py.
Usage: python make_outputs.py --res results_dir [--title-note "..."]"""
import argparse, json, os
import numpy as np, pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from openpyxl import load_workbook
from openpyxl.drawing.image import Image as XLImage
from openpyxl.styles import Font, Alignment, PatternFill
from openpyxl.utils import get_column_letter

BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({"font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2,
                     "ytick.color": INK2, "axes.titlesize": 11, "axes.titleweight": "bold",
                     "axes.titlecolor": INK, "figure.facecolor": SURF, "axes.facecolor": SURF,
                     "axes.spines.top": False, "axes.spines.right": False, "font.family": "DejaVu Sans"})


def chart_rolling(res, meta, path, note):
    r = pd.read_csv(os.path.join(res, "Rolling_250d.csv"), parse_dates=["date"])
    fig, axs = plt.subplots(3, 1, figsize=(10, 8.2), sharex=True)
    specs = [("reit_pct_per_100bp_total", "% per +100bp", "Total rate sensitivity: REIT return per +100bp in the 10Y yield"),
             ("bond_beta_marginal", "Bond beta", "Marginal rate sensitivity: Treasury bond beta holding the S&P 500 fixed (paper's b1)"),
             ("equity_beta", "Beta", "Equity beta on the S&P 500 (paper's b3)")]
    bounds = [pd.Timestamp(p[1]) for p in meta["rep_periods"][1:]] + [pd.Timestamp("2016-03-31")]
    for ax, (col, ylab, title) in zip(axs, specs):
        ax.axhline(0 if col != "equity_beta" else 1, color=INK2, lw=0.8, ls=(0, (3, 3)))
        for b in bounds:
            ax.axvline(b, color=GRID, lw=1)
        ax.plot(r["date"], r[col], color=BLUE, lw=2)
        ax.set_title(title, loc="left"); ax.set_ylabel(ylab, fontsize=8.5)
        ax.grid(axis="y", color=GRID, lw=0.6)
    axs[0].text(pd.Timestamp("2016-06-30"), axs[0].get_ylim()[1], "← paper's sample ends", ha="left", va="top",
                fontsize=8, color=INK2)
    fig.suptitle("Rolling one-year (250-day) estimates for the MSCI US REIT Index", x=0.01, ha="left",
                 fontweight="bold", color=INK)
    fig.text(0.01, 0.005, "Vertical lines: paper's sub-period breaks and the end of its sample (30 Mar 2016). "
             "Dashed: 0 (or 1 for equity beta). " + note, fontsize=7.5, color=INK2)
    fig.tight_layout(rect=(0, 0.02, 1, 0.97)); fig.savefig(path, dpi=180); plt.close(fig)


def chart_replication(res, path, note):
    c = pd.read_csv(os.path.join(res, "Replication_vs_Paper.csv"))
    e7 = pd.read_csv(os.path.join(res, "Ex7_SubPeriods.csv"))
    e8 = pd.read_csv(os.path.join(res, "Ex8_PostLehman.csv")) if os.path.exists(os.path.join(res, "Ex8_PostLehman.csv")) else None
    c = c[((c.exhibit == "Exhibit 7") & (c.panel == "C")) | ((c.exhibit == "Exhibit 8") & (c.period == "Entire post-Lehman year"))]
    if c.empty:
        return False
    fig, axs = plt.subplots(1, 2, figsize=(10, 4.2))
    for ax, b, title in [(axs[0], "b1 (tsy)", "Marginal Treasury bond beta (b1)"), (axs[1], "b3 (spx)", "Equity beta (b3)")]:
        sub = c[c.coef == b].reset_index(drop=True)
        labels = [p.replace("Taper Tantrum and Beyond", "Taper Tantrum+").replace("Entire post-Lehman year", "Post-Lehman yr")
                  for p in sub.period]
        y = np.arange(len(sub))[::-1]
        # our CIs
        lo, hi = [], []
        for _, r in sub.iterrows():
            if r.exhibit == "Exhibit 7":
                row = e7[(e7["sample"] == "Replication sub-periods") & (e7.panel == "C") & (e7.period == r.period) &
                         (e7.term == b.split("(")[1][:-1])].iloc[0]
            else:
                row = e8[(e8.model == r.period) & (e8.term == b.split("(")[1][:-1])].iloc[0]
            lo.append(row.ci_low); hi.append(row.ci_high)
        ax.hlines(y, lo, hi, color=BLUE, lw=2, alpha=0.5)
        ax.scatter(sub.ours, y, s=60, color=BLUE, zorder=3, label="Our estimate (95% CI)", edgecolor=SURF, lw=1.5)
        ax.scatter(sub.paper, y, s=60, marker="D", color=ORANGE, zorder=4, label="Paper", edgecolor=SURF, lw=1.5)
        ax.axvline(0, color=INK2, lw=0.8, ls=(0, (3, 3)))
        ax.set_yticks(y); ax.set_yticklabels(labels); ax.set_title(title, loc="left")
        ax.grid(axis="x", color=GRID, lw=0.6)
    h, l = axs[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper left", bbox_to_anchor=(0.01, 0.93), ncol=2, frameon=False, fontsize=8.5)
    fig.suptitle("Replication check: REIT ~ Treasury return + Baa excess return + S&P 500 (Exhibits 7C and 8)",
                 x=0.01, ha="left", fontweight="bold", color=INK)
    fig.text(0.01, 0.01, note, fontsize=7.5, color=INK2)
    fig.tight_layout(rect=(0, 0.03, 1, 0.88)); fig.savefig(path, dpi=180); plt.close(fig)
    return True


def chart_implications(res, meta, path, note):
    im = pd.read_csv(os.path.join(res, "Implications_per100bp.csv"))
    keep = [p[0] for p in meta["rep_periods"]] + [p[0] for p in meta["ext_fed_periods"]]
    im = im[im.period.isin(keep)].reset_index(drop=True)
    fig, ax = plt.subplots(figsize=(10, 0.55 * len(im) + 1.6))
    ax.set_axisbelow(True)
    y = np.arange(len(im))[::-1]; h = 0.26
    series = [("Treasury10Y", "10Y Treasury", AQUA, h), ("SP500_total", "S&P 500", ORANGE, 0), ("REIT_total", "US REITs", BLUE, -h)]
    for col, lab, colr, off in series:
        v = im[f"{col}_pct_per_100bp"]
        ax.barh(y + off, v, height=h * 0.9, color=colr, label=lab)
        if col != "Treasury10Y":
            ax.hlines(y + off, im[f"{col}_ci_low"], im[f"{col}_ci_high"], color=INK2, lw=1)
    ax.axvline(0, color=INK2, lw=0.8)
    ax.set_yticks(y); ax.set_yticklabels([p.replace(" (partial)", "*") for p in im.period])
    ax.set_xlabel("Average same-day return per +100bp rise in the 10Y yield (%), with 95% CI (Newey-West)")
    n_rep = len(meta["rep_periods"])
    if len(im) > n_rep:
        ax.axhline(y[n_rep - 1] - 0.5, color=GRID, lw=1.2)
        ax.text(ax.get_xlim()[1], y[n_rep - 1] - 0.55, "extension (Fed-policy regimes) ↓", ha="right", va="top", fontsize=8, color=INK2)
    ax.legend(loc="lower left", frameon=False, ncol=3, fontsize=8.5)
    ax.grid(axis="x", color=GRID, lw=0.6)
    ax.set_title("Benchmark placement: do REITs react to rates like the bond or like stocks?", loc="left")
    fig.text(0.01, 0.01, "* partial sub-period (data start Jun 2005). " + note, fontsize=7.5, color=INK2)
    fig.tight_layout(rect=(0, 0.03, 1, 1)); fig.savefig(path, dpi=180); plt.close(fig)


README = [
    ("What this is", "Replication and extension of Giliberto & Shulman (rev. 8.17.2016), 'On the Interest Rate Sensitivity of REITs'."),
    ("Units", "Returns are decimals (0.01 = 1%); yield changes in percentage points. A coefficient of -0.081 on dYield = -8.1% per +100bp. Intercepts in sub-period tables are x1000, as in the paper."),
    ("Bond returns", "Paper's method: par bond priced at 100 with coupon = previous day's yield, re-priced at today's yield, 10 years to maturity, semi-annual coupons. Same for Moody's Baa. Excess credit return = Baa return - Treasury return."),
    ("Standard errors", "Main tables use ordinary OLS t-stats, as the paper does (so they can be compared). Robustness sheet repeats with HC3 and Newey-West (5 lags)."),
    ("Sub-periods", "Replication uses the paper's Exhibit 3 dates. Extension uses (i) turning points of the MSCI REIT total-return index (paper's method, 20% swing rule) and (ii) Fed-policy regimes as a robustness check."),
    ("Sheets", "Data_Audit; Replication_vs_Paper; Ex4_DescStats; Ex2_Correlations; Ex5_YieldRegs; Ex6_BondRegs; Ex7_SubPeriods; Wald_Tests; Ex8_PostLehman; Ext_TurningPoints; Robustness; Implications_per100bp; Rolling_250d; Charts."),
    ("Interpretation caution", "Coefficients are associations, not causal effects: yields, growth news and risk appetite move together. Sub-periods defined from the REIT index's own turning points are chosen after the fact."),
]


def workbook(res, meta, charts, path):
    order = ["Data_Audit", "Replication_vs_Paper", "Ex4_DescStats", "Ex2_Correlations", "Ex5_YieldRegs", "Ex6_BondRegs",
             "Ex7_SubPeriods", "Wald_Tests", "Ex8_PostLehman", "Ext_TurningPoints", "Robustness",
             "Implications_per100bp", "Rolling_250d"]
    with pd.ExcelWriter(path, engine="openpyxl") as w:
        rd = pd.DataFrame(README, columns=["Item", "Detail"])
        rd = pd.concat([rd, pd.DataFrame([("Run", meta.get("label", ""))] + [("Note", n) for n in meta["notes"]],
                                         columns=["Item", "Detail"])])
        rd.to_excel(w, sheet_name="README", index=False)
        for k in order:
            f = os.path.join(res, f"{k}.csv")
            if os.path.exists(f):
                df = pd.read_csv(f, index_col=0 if k == "Ex2_Correlations" else None)
                df.to_excel(w, sheet_name=k[:31], index=(k == "Ex2_Correlations"))
        pd.DataFrame().to_excel(w, sheet_name="Charts")
    wb = load_workbook(path)
    for ws in wb.worksheets:
        if ws.title == "Charts":
            continue
        for cell in ws[1]:
            cell.font = Font(bold=True, color="FFFFFF"); cell.fill = PatternFill("solid", fgColor="2A78D6")
            cell.alignment = Alignment(wrap_text=True, vertical="top")
        ws.freeze_panes = "A2"
        for i, col in enumerate(ws.columns, 1):
            width = max(len(str(c.value)) if c.value is not None else 0 for c in list(col)[:200])
            ws.column_dimensions[get_column_letter(i)].width = min(max(10, width + 2), 60 if ws.title != "README" else 120)
            for c in list(col)[1:]:
                if isinstance(c.value, float):
                    c.number_format = "0.0000"
    ws = wb["README"]
    for row in ws.iter_rows(min_row=2):
        row[1].alignment = Alignment(wrap_text=True, vertical="top")
    ws = wb["Charts"]; r = 1
    for c in charts:
        img = XLImage(c); img.width, img.height = img.width * 0.42, img.height * 0.42
        ws.add_image(img, f"A{r}"); r += int(img.height / 20) + 2
    wb.save(path)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--res", required=True); ap.add_argument("--note", default="")
    ap.add_argument("--xlsx", default="REIT_RateSensitivity_Results.xlsx")
    a = ap.parse_args()
    meta = json.load(open(os.path.join(a.res, "run_meta.json")))
    note = a.note or "Source: MSCI US REIT Index (total return), S&P 500, FRED DGS10 and DBAA."
    charts = []
    p = os.path.join(a.res, "chart1_rolling_sensitivity.png"); chart_rolling(a.res, meta, p, note); charts.append(p)
    p = os.path.join(a.res, "chart2_replication_check.png")
    if chart_replication(a.res, p, note): charts.append(p)
    p = os.path.join(a.res, "chart3_benchmark_per100bp.png"); chart_implications(a.res, meta, p, note); charts.append(p)
    workbook(a.res, meta, charts, os.path.join(a.res, a.xlsx))
    print("Wrote", charts, a.xlsx)


if __name__ == "__main__":
    main()

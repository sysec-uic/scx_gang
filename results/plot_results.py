#!/usr/bin/env python3
"""Paper figures from the noise-controlled NUMA experiment.
Chameleon Cloud, 2x Xeon Gold 6240R (2 NUMA nodes, 48 CPUs),
performance governor + turbo off. Sync held constant (sense_barrier).

Figures are rendered at the LaTeX column width (~3.34in for acmart sigconf)
so that \\includegraphics[width=\\columnwidth] applies NO downscaling and the
on-page font sizes match what is set here. In-figure titles are omitted; the
paper captions carry the description."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT = os.path.dirname(os.path.abspath(__file__))
COL = 3.34   # acmart sigconf \columnwidth in inches

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.sans-serif": ["DejaVu Sans"],
    "font.size": 8.5,
    "axes.labelsize": 8.5,
    "axes.titlesize": 8.5,
    "xtick.labelsize": 8,
    "ytick.labelsize": 8,
    "legend.fontsize": 8,
    "axes.linewidth": 0.7,
    "xtick.major.width": 0.7,
    "ytick.major.width": 0.7,
    "axes.grid": True,
    "axes.grid.axis": "y",
    "grid.color": "#cccccc",
    "grid.linewidth": 0.5,
    "grid.alpha": 0.6,
    "figure.dpi": 200,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.02,
})

# Shared palette: warm = default-family placement, gray = manual pin,
# blues = our schedulers (light = spatial scx_gang, dark = temporal).
C_DEFAULT = "#e8853a"   # default scheduler (warm)
C_CROSS   = "#b2182b"   # forced cross-socket (dark red)
C_PIN     = "#9aa0a6"   # manual taskset pin (gray)
C_GANG    = "#2166ac"   # scx_gang  (blue)
C_TGANG   = "#1a4f8a"   # scx_tgang (dark blue)


def despine(ax):
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.set_axisbelow(True)


# ---- Fig 1 (paper Fig 2): single-gang controlled comparison (weak/1M), N=30 ----
# bar = median; whiskers = min..max (bimodal data -> show the spread/floor).
# Ordered worst -> best placement so the eye reads the placement gradient.
rows = [  # label, median, min, max, color
    ("D-crossnode", 62,    9,    577,   C_CROSS),
    ("D-unpinned",  1429,  7,    12284, C_DEFAULT),
    ("D-1socket",   10906, 6710, 27278, C_PIN),
    ("scx_gang",    11835, 4002, 27652, C_GANG),
]
fig, ax = plt.subplots(figsize=(COL, 2.05))
x = np.arange(len(rows))
med = [r[1] for r in rows]
lo  = [r[1]-r[2] for r in rows]
hi  = [r[3]-r[1] for r in rows]
ax.bar(x, med, width=0.66, yerr=[lo, hi], capsize=3,
       color=[r[4] for r in rows], edgecolor="black", linewidth=0.6,
       error_kw={"elinewidth": 0.8, "alpha": 0.7})
ax.set_xticks(x)
ax.set_xticklabels([r[0] for r in rows], rotation=18, ha="right")
ax.set_ylabel("weak behaviours / 1M")
ax.set_ylim(0, 28500)
ax.set_yticks([0, 10000, 20000])
ax.set_yticklabels(["0", "10k", "20k"])
for xi, m in zip(x, med):
    lbl = f"{m/1000:.1f}k" if m >= 1000 else f"{m}"
    ax.text(xi, m + 700, lbl, ha="center", va="bottom", fontsize=7.5)
despine(ax)
fig.savefig(f"{OUT}/fig1_single_gang.pdf")
fig.savefig(f"{OUT}/fig1_single_gang.png", dpi=200)

# ---- Fig 2 (paper Fig 3): throughput scaling (aggregate weak/s), 20 trials ----
K      = [1, 2, 4, 6, 8]
d_mean = [670, 5955, 4754, 8916, 13617]
d_lo   = [7, 9, 105, 2982, 392]
d_hi   = [5813, 13288, 11636, 20687, 26487]
g_mean = [5972, 10019, 19229, 17986, 13084]
g_lo   = [2407, 4707, 7753, 4912, 1351]
g_hi   = [11543, 16604, 35176, 61273, 28283]

fig, ax = plt.subplots(figsize=(COL, 2.7))
xx = np.arange(len(K)); w = 0.40
ax.bar(xx-w/2, d_mean, w, yerr=[np.subtract(d_mean, d_lo), np.subtract(d_hi, d_mean)],
       capsize=2.5, label="default", color=C_DEFAULT, edgecolor="black",
       linewidth=0.6, error_kw={"elinewidth": 0.8, "alpha": 0.6})
ax.bar(xx+w/2, g_mean, w, yerr=[np.subtract(g_mean, g_lo), np.subtract(g_hi, g_mean)],
       capsize=2.5, label="scx_gang", color=C_GANG, edgecolor="black",
       linewidth=0.6, error_kw={"elinewidth": 0.8, "alpha": 0.6})
ax.set_xticks(xx); ax.set_xticklabels([f"K={k}" for k in K])
ax.set_xlabel("concurrent gangs $K$")
ax.set_ylabel("aggregate weak / second")
ax.set_yscale("log")
ax.set_ylim(4, 1.2e5)
despine(ax)
ax.grid(axis="y", which="minor", color="#eeeeee", linewidth=0.4)
# legend above the axes -> never collides with bars/whiskers
ax.legend(frameon=False, ncol=2, loc="lower center",
          bbox_to_anchor=(0.5, 1.0), handlelength=1.3, columnspacing=1.6)
fig.savefig(f"{OUT}/fig2_throughput.pdf")
fig.savefig(f"{OUT}/fig2_throughput.png", dpi=200)

# ---- Fig 3 (paper Fig 4): oversubscription — per-gang weak/1M ----
K3      = [4, 8, 16, 24, 32]
sub     = [0.33, 0.5, 1.0, 1.5, 2.0]
d_med   = [114, 1162, 7252, 14250, 15590]
d_lo    = [16, 9, 34, 309, 1310];          d_hi = [19028, 24426, 261556, 572854, 336735]
ga_med  = [11259, 370, 12033, 7263, 5105]
ga_lo   = [15, 18, 32, 13, 16];            ga_hi = [64542, 54771, 559281, 312119, 315086]
tg_med  = [11028, 11402, 17652, 18365, 14628]
tg_lo   = [7046, 5975, 4001, 4849, 4215];  tg_hi = [16329, 30358, 194681, 195371, 247988]

fig, ax = plt.subplots(figsize=(COL, 2.8))
x = np.arange(len(K3)); w = 0.27


def bars(off, med, lo, hi, c, lab):
    ax.bar(x+off, med, w, yerr=[np.subtract(med, lo), np.subtract(hi, med)],
           capsize=1.8, color=c, edgecolor="black", linewidth=0.5, label=lab,
           error_kw={"elinewidth": 0.7, "alpha": 0.45})


bars(-w, d_med, d_lo, d_hi, C_DEFAULT, "default")
bars(0.0, ga_med, ga_lo, ga_hi, C_PIN, "scx_gang (spatial)")
bars(w, tg_med, tg_lo, tg_hi, C_GANG, "scx_tgang (temporal)")

ax.set_yscale("log")
ax.set_ylim(4, 2e6)
# boundary between fully-packed (K=16, 1x) and oversubscribed (K=24, 1.5x)
ax.axvline(2.5, ls=(0, (3, 2)), c="#555555", linewidth=0.8)
ax.text(2.62, 9e5, "oversubscribed →", fontsize=7.5, color="#555555",
        va="center", ha="left")
ax.set_xticks(x)
ax.set_xticklabels([f"K={k}\n{s:g}×" for k, s in zip(K3, sub)])
ax.set_xlabel("concurrent gangs (subscription = 3K / 48 cores)")
ax.set_ylabel("per-gang weak / 1M")
despine(ax)
ax.grid(axis="y", which="minor", color="#eeeeee", linewidth=0.4)
ax.legend(frameon=False, ncol=3, loc="lower center", bbox_to_anchor=(0.5, 1.0),
          handlelength=1.1, columnspacing=1.1, handletextpad=0.4)
fig.savefig(f"{OUT}/fig3_oversub.pdf")
fig.savefig(f"{OUT}/fig3_oversub.png", dpi=200)
print("wrote fig1_single_gang, fig2_throughput, fig3_oversub (pdf+png) to", OUT)

"""Python reference model of the micro-ring thermal tuning loop.

Same plant numbers as tb/rnm/ring_plant_rnm.sv and the same algorithm as
rtl/ring_tuner.sv, written clock by clock so the two can be compared.

usage:
    python model/ring_model.py              # all plots into docs/, metrics printed
    python model/ring_model.py --corr       # also compare with results/trace_rtl.csv

Plots:
    docs/sweep_curve.png          ADC reading vs heater code during the sweep
    docs/lock_acquisition.png     detuning and heater code while locking (3 offsets)
    docs/drift_tracking.png       tracking a +1 K/ms ambient ramp
    docs/sigma_delta_spectrum.png spectrum of the sigma-delta heater bit stream
    docs/rtl_vs_model.png         RTL + RNM trace on top of this model (with --corr)
"""
import argparse
import math
import pathlib
import random

ROOT = pathlib.Path(__file__).resolve().parent.parent

# ---------------- plant (same as ring_plant_rnm.sv) ----------------
CLK_NS, TAU_CLK, DT_MAX_K, KT_PM_PER_K = 10.0, 256.0, 30.0, 80.0
FWHM_PM, EXT, ADC_FS, ADC_DIV = 100.0, 0.9, 1000.0, 64

# ---------------- controller (same as ring_tuner.sv) ----------------
CW, AW = 12, 10
SWEEP_STEP, SETTLE, NAVG_LOG2 = 64, 512, 3
DITHER, TRACK_STEP, LOCK_MARGIN = 16, 4, 40
CMAX = (1 << CW) - 1
NAVG = 1 << NAVG_LOG2
CHI = CMAX - DITHER


def transmission(detune_pm):
    x = 2.0 * detune_pm / FWHM_PM
    return 1.0 - EXT / (1.0 + x * x)


class Loop:
    """Controller + sigma-delta DAC + plant, advanced one clock at a time."""

    def __init__(self, offset_pm, drift_k_per_ms=0.0, noise_lsb=0, seed=1, pre=0):
        self.offset, self.drift, self.noise = offset_pm, drift_k_per_ms, noise_lsb
        self.rng = random.Random(seed)
        # plant
        self.duty = 0.0
        self.amb = 0.0
        self.div = 0
        self.adc_code, self.adc_valid = 0, 0
        self.detune = offset_pm
        # sigma-delta
        self.sd_acc, self.sd_bit = 0, 0
        # controller
        self.st, self.who = "SETTLE", "SWEEP"
        self.settle, self.n, self.acc = 0, 0, 0
        self.heater, self.sweep, self.best, self.best_code = 0, 0, (1 << AW) - 1, 0
        self.centre, self.p_plus, self.locked, self.phase = 0, 0, 0, 1
        self.pre = pre                  # clocks the plant runs before the controller is started

    # one rising clock edge; every block reads values from before the edge
    def tick(self):
        heater_bit, code_now = self.sd_bit, self.heater
        adc_code, adc_valid = self.adc_code, self.adc_valid

        # plant
        self.duty += (1.0 / TAU_CLK) * ((1.0 if heater_bit else 0.0) - self.duty)
        self.amb += self.drift * CLK_NS * 1e-6
        shift = KT_PM_PER_K * (self.duty * DT_MAX_K + self.amb)
        self.detune = self.offset - shift
        self.adc_valid = 0
        self.div += 1
        if self.div == ADC_DIV:
            self.div = 0
            raw = transmission(self.detune) * ADC_FS
            nz = int(round(self.rng.gauss(0, self.noise))) if self.noise > 0 else 0
            self.adc_code = max(0, min(1023, int(raw + 0.5) + nz))
            self.adc_valid = 1

        # sigma-delta
        s = self.sd_acc + code_now
        self.sd_acc, self.sd_bit = s & CMAX, s >> CW

        # controller
        if self.pre > 0:
            self.pre -= 1
            return heater_bit
        avg = self.acc >> NAVG_LOG2
        st = self.st
        if st == "SETTLE":
            if self.settle == SETTLE - 1:
                self.settle, self.n, self.acc, self.st = 0, 0, 0, "ACC"
            else:
                self.settle += 1
        elif st == "ACC":
            if adc_valid and self.n != NAVG:
                self.acc += adc_code
                self.n += 1
            elif self.n == NAVG:
                self.st = {"SWEEP": "SWEEP_NEXT", "PLUS": "MINUS", "MINUS": "DECIDE"}[self.who]
        elif st == "SWEEP_NEXT":
            better = avg < self.best
            if better:
                self.best, self.best_code = avg, self.sweep
            if self.sweep > CMAX - SWEEP_STEP:
                c = self.sweep if better else self.best_code
                self.centre = min(max(c, DITHER), CHI)
                self.phase, self.st = 2, "PLUS"
            else:
                self.sweep += SWEEP_STEP
                self.heater = self.sweep
                self.who, self.st = "SWEEP", "SETTLE"
        elif st == "PLUS":
            self.heater = self.centre + DITHER
            self.who, self.st = "PLUS", "SETTLE"
        elif st == "MINUS":
            self.p_plus = avg
            self.heater = self.centre - DITHER
            self.who, self.st = "MINUS", "SETTLE"
        elif st == "DECIDE":
            if self.p_plus < avg:
                self.centre = CHI if self.centre >= CHI - TRACK_STEP else self.centre + TRACK_STEP
            elif avg < self.p_plus:
                self.centre = DITHER if self.centre <= DITHER + TRACK_STEP else self.centre - TRACK_STEP
            self.locked = int(min(self.p_plus, avg) <= self.best + LOCK_MARGIN)
            self.st = "PLUS"
        return heater_bit


def run(offset, clocks, drift_after_lock=0.0, noise=0, settle_after_lock=20000, every=64):
    """Run until lock, then settle_after_lock clocks, then `clocks` more with drift."""
    lp = Loop(offset, 0.0, noise)
    t, lock_t = 0, None
    tr = {"t": [], "detune": [], "heater": [], "adc": [], "locked": []}
    total = None
    while True:
        lp.tick()
        t += 1
        if lock_t is None and lp.locked:
            lock_t = t
            total = t + settle_after_lock + clocks
        if lock_t is not None and t == lock_t + settle_after_lock:
            lp.drift = drift_after_lock
        if t % every == 0:
            tr["t"].append(t); tr["detune"].append(lp.detune); tr["heater"].append(lp.heater)
            tr["adc"].append(lp.adc_code); tr["locked"].append(lp.locked)
        if (total is not None and t >= total) or t > 400000:
            break
    return lock_t, tr, lp


def plots(args):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    ink, acc, gold, red = "#16202A", "#0E7660", "#B7860B", "#C0392B"

    # sweep curve: static transmission vs heater code, and what the ADC reads
    codes = list(range(0, 4096, 8))
    fig, ax = plt.subplots(figsize=(7, 3.6))
    for off, col in ((400, acc), (1100, gold), (1900, red)):
        ax.plot(codes, [transmission(off - KT_PM_PER_K * DT_MAX_K * c / 4096) * ADC_FS for c in codes],
                color=col, label=f"laser offset {off} pm")
    ax.set_xlabel("heater code"); ax.set_ylabel("through-port ADC code")
    ax.set_title("What the sweep sees: one resonance dip per offset", fontsize=11)
    ax.legend(fontsize=8); ax.grid(alpha=.3); fig.tight_layout()
    fig.savefig(docs / "sweep_curve.png", dpi=150); plt.close(fig)

    # lock acquisition
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(7, 5.2), sharex=True)
    for off, col in ((400, acc), (1100, gold), (1900, red)):
        lock_t, tr, _ = run(off, 20000)
        ms = [x * CLK_NS * 1e-6 for x in tr["t"]]
        a1.plot(ms, tr["heater"], color=col, lw=1, label=f"{off} pm (lock {lock_t*CLK_NS*1e-6:.2f} ms)")
        a2.plot(ms, [max(-200, min(200, d)) for d in tr["detune"]], color=col, lw=1)
        print(f"lock from {off:4d} pm: {lock_t} clocks = {lock_t*CLK_NS*1e-6:.3f} ms")
    a1.set_ylabel("heater code"); a1.legend(fontsize=8); a1.grid(alpha=.3)
    a2.set_ylabel("detuning (pm, clipped ±200)"); a2.set_xlabel("time (ms)"); a2.grid(alpha=.3)
    a2.axhspan(-20, 20, color=acc, alpha=.12)
    a1.set_title("Sweep, then dither tracking (Python model)", fontsize=11)
    fig.tight_layout(); fig.savefig(docs / "lock_acquisition.png", dpi=150); plt.close(fig)

    # drift tracking
    lock_t, tr, lp = run(1100, 150000, drift_after_lock=1.0, noise=3)
    start = lock_t + 20000
    sel = [i for i, t in enumerate(tr["t"]) if t >= start]
    ms = [(tr["t"][i] - start) * CLK_NS * 1e-6 for i in sel]
    det = [tr["detune"][i] for i in sel]
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(7, 5), sharex=True)
    a1.plot(ms, [tr["heater"][i] for i in sel], color=gold, lw=1)
    a1.set_ylabel("heater code"); a1.grid(alpha=.3)
    a1.set_title("Ambient +1 K/ms for 1.5 ms (resonance moves 120 pm), 3 LSB ADC noise", fontsize=10)
    a2.plot(ms, det, color=acc, lw=1); a2.axhspan(-20, 20, color=acc, alpha=.12)
    a2.set_ylabel("detuning (pm)"); a2.set_xlabel("time since drift started (ms)"); a2.grid(alpha=.3)
    fig.tight_layout(); fig.savefig(docs / "drift_tracking.png", dpi=150); plt.close(fig)
    print(f"drift +1 K/ms, noise 3 LSB: max |detune| {max(abs(d) for d in det):.1f} pm, "
          f"mean {sum(abs(d) for d in det)/len(det):.1f} pm")

    # sigma-delta spectrum (code 1100 of 4096)
    import numpy as np
    n, code, a, bits = 1 << 16, 1100, 0, []
    for _ in range(n):
        s = a + code; a, b = s & CMAX, s >> CW; bits.append(b)
    x = np.array(bits, float) - np.mean(bits)
    w = np.hanning(n)
    spec = np.abs(np.fft.rfft(x * w)) ** 2
    f = np.fft.rfftfreq(n, CLK_NS * 1e-9)
    spec_db = 10 * np.log10(spec / spec.max() + 1e-20)
    fc = 1.0 / (2 * math.pi * TAU_CLK * CLK_NS * 1e-9)
    fig, ax = plt.subplots(figsize=(7, 3.6))
    ax.semilogx(f[1:], spec_db[1:], color=ink, lw=.6)
    ax.axvline(fc, color=red, lw=1, ls="--", label=f"heater corner {fc/1e3:.0f} kHz")
    ax.set_xlabel("frequency (Hz)"); ax.set_ylabel("power (dB, normalised)")
    ax.set_title("Sigma-delta bit stream, code 1100: lowest tone 98 kHz, heater corner 62 kHz", fontsize=10)
    ax.legend(fontsize=8); ax.grid(alpha=.3, which="both"); fig.tight_layout()
    fig.savefig(docs / "sigma_delta_spectrum.png", dpi=150); plt.close(fig)
    print(f"sigma-delta: mean density {np.mean(bits):.5f} vs code/4096 = {code/4096:.5f}")

    if args.corr:
        corr(plt)


def corr(plt):
    """Compare results/trace_rtl.csv (Icarus, RTL + SV real-number model) with this model."""
    import csv
    src = ROOT / "results" / "trace_rtl.csv"
    rows = list(csv.DictReader(open(src)))
    rtl = {int(r["clk"]): (int(r["heater_code"]), float(r["detune_pm"]), int(r["locked"])) for r in rows}
    rtl_lock = min((c for c, v in rtl.items() if v[2]), default=None)
    clks = sorted(rtl)
    best = None
    for pre in range(0, 4):                    # plant runs 0..3 clocks before start is seen
        lp = Loop(1100.0, pre=pre)
        model = {}
        for t in range(1, clks[-1] + 200):
            lp.tick()
            model[t] = (lp.heater, lp.detune, lp.locked)
        for base in range(0, 12):              # RTL clock = model tick + base
            dh = [abs(model[c - base][0] - rtl[c][0]) for c in clks if (c - base) in model]
            dd = [abs(model[c - base][1] - rtl[c][1]) for c in clks if (c - base) in model]
            score = (max(dh), max(dd))
            if best is None or score < best[0]:
                best = (score, pre, base, model)
    (mh, md), pre, base, model = best
    dh, xs, hr, hm, dd = [], [], [], [], []
    for c in clks:
        m = model.get(c - base)
        if m is None:
            continue
        dh.append(abs(m[0] - rtl[c][0])); dd.append(abs(m[1] - rtl[c][1]))
        xs.append(c * CLK_NS * 1e-6); hr.append(rtl[c][0]); hm.append(m[0])
    m_lock = min((c for c in clks if (c - base) in model and model[c - base][2]), default=None)
    worst_i = max(range(len(dd)), key=lambda i: dd[i])
    print(f"correlation (offset 1100 pm, no noise): {len(dh)} sample points (every 64 clocks), "
          f"plant head start {pre}, clock offset {base}")
    print(f"  heater code mismatch: max {max(dh)}")
    print(f"  detuning difference : mean {sum(dd)/len(dd):.4f} pm, max {max(dd):.3f} pm "
          f"at {xs[worst_i]:.3f} ms (heater code there {hr[worst_i]}, previous sample {hr[worst_i-1]})")
    print(f"  first sample with locked=1: RTL clock {rtl_lock}, model clock {m_lock}")
    fig, ax = plt.subplots(figsize=(7, 3.4))
    ax.plot(xs, hr, color="#0E7660", lw=2.2, label="RTL + SV real-number model (Icarus)")
    ax.plot(xs, hm, color="#B7860B", lw=1, ls="--", label="Python reference model")
    ax.set_xlabel("time (ms)"); ax.set_ylabel("heater code"); ax.grid(alpha=.3)
    ax.set_title(f"Heater code, RTL vs model (max mismatch {max(dh)} codes)", fontsize=10)
    ax.legend(fontsize=8); fig.tight_layout()
    fig.savefig(ROOT / "docs" / "rtl_vs_model.png", dpi=150); plt.close(fig)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--corr", action="store_true", help="compare with results/trace_rtl.csv")
    plots(ap.parse_args())

#!/usr/bin/env python3
"""helm/observability/preview-dashboards.py — see the dashboards without a cluster.

WHAT THIS IS, AND WHAT IT IS NOT

It reads the committed dashboard JSON and draws the real layout: the actual
24-column grid, the real panel sizes and positions, the real titles, units and
threshold colours, and the real PromQL behind each panel. Because it is
generated from the same files that get deployed, it cannot drift from what
Grafana will actually load.

It is NOT a Grafana screenshot. The data is synthetic — Grafana has not run,
no Prometheus has been queried, and the curves are drawn from a seeded RNG to
show panel SHAPE, not values. Anything that depends on real data (exact
colours per series, legend ordering, table contents) will differ.

Use it to answer "is this laid out sensibly, and is anything missing?" before
spending 35 minutes on a deploy. Use a real screenshot for evidence.

    python3 helm/observability/preview-dashboards.py > /tmp/preview.html
"""
import glob
import html
import json
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
COL_W = 58          # px per grid column (Grafana's grid is 24 columns wide)
ROW_H = 34          # px per grid row unit

# Grafana's classic series palette, so the preview reads like the real thing.
PALETTE = ["#7EB26D", "#EAB839", "#6ED0E0", "#EF843C", "#E24D42",
           "#1F78C1", "#BA43A9", "#705DA0", "#508642", "#CCA300"]

THRESHOLD_COLOR = {"green": "#73BF69", "orange": "#FF9830",
                   "red": "#F2495C", "yellow": "#FADE2A"}


def spark(w, h, seed, kind="line", n=44):
    """A plausible curve. Shape only — there is no data behind it."""
    rnd = random.Random(seed)
    pts, v = [], rnd.uniform(0.35, 0.65)
    for i in range(n):
        v += rnd.uniform(-0.11, 0.11)
        if kind == "spiky" and rnd.random() < 0.09:
            v += rnd.uniform(0.2, 0.45)
        v = max(0.05, min(0.95, v))
        pts.append((i / (n - 1) * w, h - v * h))
    line = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    area = f"0,{h} {line} {w},{h}"
    return line, area


def fmt_value(unit, seed, steps=None):
    """A representative reading, so a stat panel is not an empty box.

    The DIRECTION matters. "Availability 98.7%" and "Error ratio 98.7%" are the
    same number meaning opposite things, and the first draft printed the second
    one -- a preview showing a 98% error rate as if it were normal is worse
    than a blank box, because it teaches the reader the wrong shape.

    Direction is read off the thresholds rather than guessed from the title:
    if the HIGHEST threshold is green, higher is better; if it is red or
    orange, lower is better.
    """
    rnd = random.Random(seed)
    higher_is_better = bool(steps) and steps[-1]["color"] == "green"
    if unit == "percentunit":
        if higher_is_better:
            return f"{rnd.uniform(0.985, 0.999):.3%}"
        # Two bands: a ratio-style metric (error rate) sits near zero; a
        # utilisation-style one (disk used) sits mid-range. Told apart by the
        # threshold spacing -- utilisation thresholds start well above zero.
        first = steps[0]["value"] if steps else 0.02
        if first >= 0.5:
            return f"{rnd.uniform(0.35, 0.58):.1%}"
        return f"{rnd.uniform(0.0004, 0.006):.3%}"
    if unit == "s":
        # Seconds spans two very different scales here: request latency
        # (fractions of a second) and "time since the last successful build"
        # (hours). The thresholds tell them apart -- a latency SLO is under a
        # second, a staleness threshold is 86400.
        if steps and steps[0]["value"] >= 60:
            return f"{rnd.uniform(1.5, 9.0):.1f} hr"
        return f"{rnd.uniform(0.08, 0.31):.2f} s"
    if unit == "reqps":
        return f"{rnd.uniform(1.2, 9.0):.1f}"
    if unit == "ms":
        return f"{rnd.randint(90, 400)} ms"
    if unit == "bytes":
        return f"{rnd.uniform(0.4, 3.1):.1f} GiB"
    # Counts, same direction rule. "Firing alerts: 4" or "OOMKilled: 3" as the
    # resting state is the same mistake as a 98% error ratio -- it normalises
    # the unhealthy value.
    if steps and not higher_is_better:
        return str(rnd.choice([0, 0, 0, 1]))
    return str(rnd.randint(2, 6))


def panel_html(p, idx):
    g = p["gridPos"]
    x, y, w, h = g["x"] * COL_W, g["y"] * ROW_H, g["w"] * COL_W, g["h"] * ROW_H
    title = html.escape(p.get("title", ""))
    desc = html.escape(p.get("description", ""))
    defaults = p.get("fieldConfig", {}).get("defaults", {})
    unit = defaults.get("unit", "")
    steps = [s for s in defaults.get("thresholds", {}).get("steps", [])
             if s.get("value") is not None]
    ptype = p["type"]
    inner_w, inner_h = w - 22, h - 46

    if ptype == "stat":
        # Show the HEALTHY band. A preview permanently amber teaches the reader
        # that amber is the normal state, which is exactly backwards.
        if steps:
            healthy = "green" if steps[-1]["color"] == "green" else steps[0]["color"]
            colour = THRESHOLD_COLOR.get("green" if healthy == "green" else "green", "#73BF69")
        else:
            colour = "#CCCCDC"
        line, area = spark(inner_w, max(inner_h - 34, 18), idx)
        body = (
            f'<div class="statwrap">'
            f'<div class="statval" style="color:{colour}">{fmt_value(unit, idx, steps)}</div>'
            f'<svg class="statspark" viewBox="0 0 {inner_w} {max(inner_h-34,18)}" preserveAspectRatio="none">'
            f'<polygon points="{area}" fill="{colour}" opacity="0.16"/>'
            f'<polyline points="{line}" fill="none" stroke="{colour}" stroke-width="1.6"/>'
            f'</svg></div>')
    elif ptype == "table":
        rows = "".join(
            f'<tr><td>{html.escape(c)}</td><td class="tv">{v}</td></tr>'
            for c, v in (("devops-app / backend", "1"),
                         ("devops-app / worker", "1"),
                         ("devops-app / frontend", "1"),
                         ("jenkins / jenkins", "1"),
                         ("observability / prometheus", "1")))
        body = (f'<table class="ptable"><thead><tr><th>target</th><th>value</th>'
                f'</tr></thead><tbody>{rows}</tbody></table>')
    else:  # timeseries
        n_series = 3 if g["w"] >= 12 else 2
        svgs = []
        for s in range(n_series):
            line, area = spark(inner_w, inner_h - 22, idx * 10 + s,
                               kind="spiky" if s == 0 else "line")
            c = PALETTE[(idx + s) % len(PALETTE)]
            svgs.append(f'<polygon points="{area}" fill="{c}" opacity="0.10"/>'
                        f'<polyline points="{line}" fill="none" stroke="{c}" stroke-width="1.7"/>')
        thr_line = ""
        if steps:
            c = THRESHOLD_COLOR.get(steps[-1]["color"], "#F2495C")
            yy = (inner_h - 22) * 0.28
            thr_line = (f'<line x1="0" y1="{yy}" x2="{inner_w}" y2="{yy}" '
                        f'stroke="{c}" stroke-width="1.2" stroke-dasharray="5 4" opacity="0.85"/>')
        grid = "".join(
            f'<line x1="0" y1="{(inner_h-22)*f:.0f}" x2="{inner_w}" y2="{(inner_h-22)*f:.0f}" '
            f'stroke="#2b2f3a" stroke-width="1"/>' for f in (0.25, 0.5, 0.75))
        legend = "".join(
            f'<span class="lg"><i style="background:{PALETTE[(idx+s)%len(PALETTE)]}"></i>series {s+1}</span>'
            for s in range(n_series))
        body = (f'<svg class="ts" viewBox="0 0 {inner_w} {inner_h-22}" preserveAspectRatio="none">'
                f'{grid}{"".join(svgs)}{thr_line}</svg>'
                f'<div class="legend">{legend}</div>')

    thr_badge = ""
    if steps:
        thr_badge = '<span class="thr">' + " ".join(
            f'<i style="background:{THRESHOLD_COLOR.get(s["color"], "#888")}"></i>{s["value"]}'
            for s in steps) + "</span>"
    unit_badge = f'<span class="unit">{html.escape(unit)}</span>' if unit else ""

    queries = "".join(
        f'<code>{html.escape((t.get("expr") or "")[:400])}</code>'
        for t in (p.get("targets") or []) if t.get("expr"))

    return (
        f'<div class="panel" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px">'
        f'<div class="phead"><span class="ptitle">{title}</span>{unit_badge}{thr_badge}</div>'
        f'<div class="pbody">{body}</div>'
        f'<div class="tip"><b>{title}</b>'
        f'{"<p>" + desc + "</p>" if desc else ""}{queries}</div>'
        f'</div>')


def row_html(p):
    g = p["gridPos"]
    return (f'<div class="rowhead" style="left:0;top:{g["y"]*ROW_H}px;width:{24*COL_W}px">'
            f'<span>{html.escape(p["title"])}</span></div>')


def dashboard_html(d):
    parts, idx = [], 0
    height = 0
    for p in d["panels"]:
        g = p["gridPos"]
        height = max(height, (g["y"] + g["h"]) * ROW_H)
        if p["type"] == "row":
            parts.append(row_html(p))
        else:
            idx += 1
            parts.append(panel_html(p, idx))
    variables = "".join(
        f'<span class="var"><em>{html.escape(v["name"])}</em> All</span>'
        for v in d.get("templating", {}).get("list", []))
    ann = "".join(
        f'<span class="ann">▮ {html.escape(a["name"])}</span>'
        for a in d.get("annotations", {}).get("list", []))
    return (
        f'<section class="dash">'
        f'<header class="dhead">'
        f'<h2>{html.escape(d["title"])}</h2>'
        f'<div class="dmeta"><code>{html.escape(d["uid"])}</code>'
        f'<span>refresh {html.escape(d.get("refresh", ""))}</span>'
        f'<span>{html.escape(d["time"]["from"])} → now</span>{variables}{ann}</div>'
        f'<p class="ddesc">{html.escape(d.get("description", ""))}</p>'
        f'</header>'
        f'<div class="canvas" style="height:{height+16}px;width:{24*COL_W}px">'
        f'{"".join(parts)}</div></section>')


CSS = """
*{box-sizing:border-box}
body{margin:0;background:#0b0c0e;color:#d8d9da;
     font-family:"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-size:14px}
.wrap{max-width:1500px;margin:0 auto;padding:34px 26px 90px}
.masthead{border-bottom:1px solid #24262b;padding-bottom:22px;margin-bottom:30px}
.masthead h1{font-size:25px;font-weight:600;margin:0 0 10px;letter-spacing:-.01em;color:#fff}
.warn{background:#241a10;border:1px solid #6b4a1f;border-left:3px solid #FF9830;
      padding:13px 17px;border-radius:4px;margin:16px 0 0;color:#e8d7c0;line-height:1.6;font-size:13.5px}
.warn b{color:#FF9830}
.dash{margin:44px 0 0}
.dhead h2{font-size:19px;font-weight:600;margin:0 0 7px;color:#fff}
.dmeta{display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;
       font-size:11.5px;color:#8e8e8e;margin-bottom:6px}
.dmeta code{background:#17181b;border:1px solid #26282e;border-radius:3px;padding:1px 6px;color:#9aa0a6}
.var{background:#17181b;border:1px solid #26282e;border-radius:3px;padding:2px 8px}
.var em{color:#6ED0E0;font-style:normal}
.ann{color:#E24D42}
.ddesc{color:#909296;font-size:13px;margin:0 0 16px;max-width:78ch;line-height:1.55}
.canvas{position:relative;margin-bottom:10px}
.rowhead{position:absolute;height:34px;display:flex;align-items:center;
         border-bottom:1px solid #202227}
.rowhead span{font-size:12.5px;font-weight:600;color:#c7c9cc;letter-spacing:.01em}
.rowhead span::before{content:"▾";color:#6e7075;margin-right:8px;font-size:10px}
.panel{position:absolute;background:#141619;border:1px solid #24262b;border-radius:3px;
       padding:8px 10px 10px;overflow:visible}
.panel:hover{border-color:#3d71d9;z-index:40}
.phead{display:flex;align-items:center;gap:7px;margin-bottom:6px;min-height:17px}
.ptitle{font-size:12.5px;font-weight:500;color:#d8d9da;white-space:nowrap;
        overflow:hidden;text-overflow:ellipsis;flex:1}
.unit{font-size:9.5px;color:#7a7d82;border:1px solid #2a2c31;border-radius:2px;padding:0 4px}
.thr{display:flex;gap:5px;align-items:center;font-size:9.5px;color:#7a7d82}
.thr i{width:7px;height:7px;border-radius:50%;display:inline-block;margin-right:2px}
.pbody{height:calc(100% - 24px);position:relative}
.statwrap{height:100%;display:flex;flex-direction:column;justify-content:space-between}
.statval{font-size:29px;font-weight:600;line-height:1;letter-spacing:-.02em;
         font-variant-numeric:tabular-nums}
.statspark{width:100%;display:block}
.ts{width:100%;display:block}
.legend{display:flex;gap:12px;margin-top:5px;font-size:10px;color:#8e8e8e}
.lg i{width:9px;height:2.5px;display:inline-block;margin-right:5px;vertical-align:middle;border-radius:1px}
.ptable{width:100%;border-collapse:collapse;font-size:11px}
.ptable th{text-align:left;color:#8e8e8e;font-weight:500;padding:3px 5px;
           border-bottom:1px solid #26282e;font-size:10px;text-transform:uppercase;letter-spacing:.05em}
.ptable td{padding:3.5px 5px;border-bottom:1px solid #1c1e22;color:#b6b8bb}
.ptable .tv{color:#73BF69;text-align:right;font-variant-numeric:tabular-nums}
.tip{display:none;position:absolute;left:0;top:calc(100% + 6px);width:520px;z-index:60;
     background:#0a0b0d;border:1px solid #3d71d9;border-radius:4px;padding:12px 14px;
     box-shadow:0 12px 32px rgba(0,0,0,.75)}
.panel:hover .tip{display:block}
.tip b{color:#fff;font-size:12.5px}
.tip p{color:#a9abae;font-size:12px;line-height:1.55;margin:7px 0 9px}
.tip code{display:block;background:#141619;border:1px solid #24262b;border-radius:3px;
          padding:7px 9px;margin-top:6px;font-family:ui-monospace,"SF Mono",Menlo,monospace;
          font-size:10.5px;color:#6ED0E0;white-space:pre-wrap;word-break:break-word;line-height:1.5}
footer{margin-top:56px;padding-top:20px;border-top:1px solid #24262b;color:#7a7d82;font-size:12.5px;line-height:1.65}
"""


def main():
    files = sorted(glob.glob(os.path.join(HERE, "dashboards", "*.json")))
    order = {"vm-app-overview": 0, "vm-k8s-cluster": 1, "vm-jenkins-delivery": 2}
    dashboards = sorted((json.load(open(f)) for f in files),
                        key=lambda d: order.get(d["uid"], 99))
    n_panels = sum(len([p for p in d["panels"] if p["type"] != "row"]) for d in dashboards)
    n_q = sum(len(t.get("expr", "")) > 0
              for d in dashboards for p in d["panels"] for t in (p.get("targets") or []))

    body = "".join(dashboard_html(d) for d in dashboards)
    print(f"""<!doctype html><html><head><meta charset="utf-8">
<title>Dashboard layout preview</title><style>{CSS}</style></head><body><div class="wrap">
<header class="masthead">
<h1>Grafana dashboards — layout preview</h1>
<p style="color:#909296;margin:0;max-width:80ch;line-height:1.6">
Generated from <code style="color:#9aa0a6">helm/observability/dashboards/*.json</code>,
the same files the ConfigMaps are built from. {len(dashboards)} dashboards,
{n_panels} panels, {n_q} PromQL queries. Hover any panel for its description and its real query.</p>
<div class="warn"><b>This is not a Grafana screenshot.</b> The layout, panel sizes, titles, units,
threshold colours and queries are real — read straight out of the committed JSON, so they cannot
drift from what gets deployed. <b>The data is invented.</b> No Prometheus has been queried and
Grafana has not run; the curves are a seeded RNG drawn to show panel shape. Series colours, legend
ordering and table contents will differ in the real thing. Use this to check the layout is
sensible before a 35-minute deploy — use a real screenshot for evidence.</div>
</header>
{body}
<footer>Regenerate:
<code style="color:#6ED0E0">python3 helm/observability/preview-dashboards.py &gt; preview.html</code><br>
Edit them in <code style="color:#6ED0E0">helm/observability/build-dashboards.py</code>, never by hand —
<code style="color:#6ED0E0">tests/check_dashboards.py</code> fails if the JSON and the builder disagree.</footer>
</div></body></html>""")


if __name__ == "__main__":
    main()

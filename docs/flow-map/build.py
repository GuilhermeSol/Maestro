#!/usr/bin/env python3
"""Lays out flows.py as a star map and writes index.html next to it. Run: python3 -I build.py
flows.py holds every agent flow (questions, answers, targets). Change it when an agent changes, then rebuild."""
import html
import re
import math
import os
import sys
import textwrap

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flows import AGENTS

BW, ROWH, PILLH, PILLGAP = 214, 17, 24, 14
STAR_R = 120
E = html.escape

COL = {"mae": "#f4f7fb", "ba": "#9aa7b8", "arc": "#8f9bff", "dev": "#4fb4f0",
       "rev": "#f08cc4", "sec": "#c7a6ff", "prm": "#b5835a", "rtn": "#7ee0d6"}
GREEN, RED = "#4ade80", "#f87171"
HAPPY = re.compile(r"^(\d(\.\d)? )?(Yes|Clean|All pass|Green|Approved|None|Merged)\b|^Found$|^A RED confirmed|^1 Proceed|^1 Post, proceed|^0 Clean|^1\.1 (Merge|Accept|Mark)|^Fresh start|^Q1, Q2 Yes")
SAD = re.compile(r"^(\d )?No$|^N Skip$|Escalate|^3 Stop|^Stop$|^1\.2 Stop|^Red$|Tests fail|Rejected|^Critical|Timed out|Discard|Loop back|Send back|Regression|Cannot build|Limit reached|Failed|^1 Fix it")


def answer_col(a, t):
    ts = t if isinstance(t, tuple) else (t,)
    if any(x.startswith("@") for x in ts):
        return "y"
    if any(x in ("STOP", "BLOCK") for x in ts):
        return "bad"
    if HAPPY.search(a):
        return "ok"
    if SAD.search(a):
        return "bad"
    return ""


# Automatic decisions: the agent decides from a result. It asks the user nothing.
DEC = {"mae": {"state", "assignee", "run"}, "ba": {"clear", "pathb"}, "arc": {"result", "pattern", "ci"},
       "dev": {"tree", "unexp", "outcome", "more", "kind"}, "rev": {"verdict"}, "sec": {"breach", "verdict"},
       "prm": {"exit"}, "rtn": {"state", "draft", "decision", "event", "result"}}


def box_size(kind, text):
    lines = textwrap.wrap(text, 30) or [""]
    return BW, len(lines) * ROWH + (26 if kind in "qod" else 16), lines


def pill_w(a):
    return 18 + len(a) * 6.5


class Node:
    pass


def build_nodes():
    """Makes Node objects, the question IDs, and each agent's special nodes."""
    systems = []
    for ref, prefix, name, role, raw in AGENTS:
        nodes, qn = [], 0
        cnt = {"Q": 0, "D": 0, "O": 0}
        for key, kind, text, exits in raw:
            if key in DEC.get(ref, ()):
                kind = "d"
            n = Node()
            n.key, n.kind, n.text, n.exits, n.agent = key, kind, text, exits, ref
            n.w, n.h, n.lines = box_size(kind, text)
            n.id = ""
            if kind in "qod":
                cls = {"q": "Q", "d": "D", "o": "O"}[kind]
                cnt[cls] += 1
                qn += 1
                n.id = f"{prefix}-{cls}{cnt[cls]:02d}"
            nodes.append(n)
        used = set()
        for n in nodes:
            ex = n.exits
            targets = [ex] if not isinstance(ex, list) else [t for _, t in ex]
            for t in targets:
                used.update(t if isinstance(t, tuple) else (t,))
        for sp, label, kind in (("BLOCK", "Blocked: wait for PO", "x"), ("GAP", "Gap: not defined", "g"),
                                ("STOP", "STOP", "x"), ("END", "Task Completed. Ticket is ready for QA.", "e")):
            if sp in used:
                n = Node()
                n.key, n.kind, n.text, n.exits, n.agent = sp, kind, label, [], ref
                n.w, n.h, n.lines = box_size(kind, label)
                n.id = ""
                nodes.append(n)
        systems.append(dict(ref=ref, prefix=prefix, name=name, role=role, nodes=nodes, qn=qn))
    return systems


CW, RPAD = BW + 80 + 175 + 190, 130


def layout(systems):
    """Each agent is a grid of cells (one cell per node) under its star. The grids sit on a ring around Maestro."""
    for s in systems:
        nodes = s["nodes"]
        per = max(4, math.ceil(math.sqrt(len(nodes)) * 1.1))
        chunks = [nodes[i:i + per] for i in range(0, len(nodes), per)]
        W = len(chunks) * CW
        top = 2 * STAR_R + 60
        heights = []
        for ch in chunks:
            heights.append(sum(max(m.h, len(m.exits) * (PILLH + PILLGAP) if m.kind in "qod" else 0) + RPAD for m in ch))
        H = top + max(heights)
        s["W"], s["H"] = W, H
        for c, ch in enumerate(chunks):
            y = top
            for n in ch:
                h = max(n.h, len(n.exits) * (PILLH + PILLGAP) if n.kind in "qod" else 0) + RPAD
                n.x = -W / 2 + c * CW + BW / 2 + 20
                n.y = -H / 2 + y + h / 2 - RPAD / 2
                n.answers = []
                if n.kind in "qod":
                    total = len(n.exits) * (PILLH + PILLGAP) - PILLGAP
                    py = n.y - total / 2 + PILLH / 2
                    for a_, t_ in n.exits:
                        w = pill_w(a_)
                        n.answers.append(dict(text=a_, target=t_, x=n.x + BW / 2 + 80 + w / 2, y=py, w=w))
                        py += PILLH + PILLGAP
                y += h
        s["radius"] = math.hypot(W, H) / 2
        s["zr"] = max(W, H) / 2
    core, ring = systems[0], systems[1:]
    gap = 900
    D = max(sum(2 * s["radius"] + gap for s in ring) / (2 * math.pi), core["radius"] + max(s["radius"] for s in ring) + gap)
    used = sum(2 * math.asin(min(1, (s["radius"] + gap / 2) / D)) for s in ring)
    spare = (2 * math.pi - used) / len(ring)
    ang = -math.pi / 2
    pos = [(core, 0.0, 0.0)]
    for s in ring:
        half = math.asin(min(1, (s["radius"] + gap / 2) / D))
        ang += half
        pos.append((s, D * math.cos(ang), D * math.sin(ang)))
        ang += half + spare
    for s, ux, uy in pos:
        s["ucx"], s["ucy"] = ux, uy
        s["cx"], s["cy"] = ux - s["W"] / 2 + STAR_R + 20, uy - s["H"] / 2 + STAR_R
        for n in s["nodes"]:
            n.x += ux
            n.y += uy
            for p in n.answers:
                p["x"] += ux
                p["y"] += uy
    return D


def overlaps(boxes):
    m, c = 6, 0
    for i, a in enumerate(boxes):
        for b_ in boxes[i + 1:]:
            if a[0] - m < b_[2] and b_[0] - m < a[2] and a[1] - m < b_[3] and b_[1] - m < a[3]:
                c += 1
    return c


def border(cx, cy, w, h, fx, fy):
    """The point where the line from (fx,fy) to the box centre meets the box."""
    dx, dy = fx - cx, fy - cy
    if dx == 0 and dy == 0:
        return cx, cy
    s = min((w / 2 + 3) / abs(dx) if dx else 1e9, (h / 2 + 3) / abs(dy) if dy else 1e9)
    return cx + dx * s, cy + dy * s


def resolve(systems, agent, target):
    by = {s["ref"]: s for s in systems}
    if target.startswith("@"):
        ref, _, key = target[1:].partition(".")
        if key:
            return next(n for n in by[ref]["nodes"] if n.key == key), True
        return by[ref], True
    return next(n for n in by[agent]["nodes"] if n.key == target), False


def geom(t):
    if isinstance(t, dict):
        return t["cx"], t["cy"], STAR_R * 2, STAR_R * 2, "star-" + t["ref"]
    return t.x, t.y, t.w, t.h, f"{t.agent}-{t.key}"


def curve(x1, y1, tgt, cx, cy, bend, cls, a, b, vstart=False, col=""):
    """One smooth cubic. It leaves to the right. A target on the right is entered from its left side.
    Any other target is entered from the top or bottom, so the line turns once and never doubles back."""
    x2, y2, w, h, _ = geom(tgt)
    if vstart and y2 - h / 2 > y1 + 10:
        ex, ey = x2, y2 - h / 2 - 4
        d = max(30, (ey - y1) * 0.5)
        return (f'<path class="{cls}{" " + col if col else ""}" data-a="{a}" data-b="{b}" marker-end="url(#ah{col})" '
                f'd="M{x1:.0f} {y1:.0f}C{x1:.0f} {y1 + d:.0f} {ex:.0f} {ey - d:.0f} {ex:.0f} {ey:.0f}"/>')
    if x2 - w / 2 > x1 + 50:
        ex, ey = x2 - w / 2 - 4, y2
        d = max(70, (ex - x1) * 0.5)
        c1, c2 = (x1 + d, y1), (ex - d, ey)
    else:
        down = y2 >= y1
        ex, ey = x2, (y2 - h / 2 - 4 if down else y2 + h / 2 + 4)
        d = max(90, abs(ey - y1) * 0.45)
        c1, c2 = (x1 + 150, y1), (ex, ey - d if down else ey + d)
    return (f'<path class="{cls}{" " + col if col else ""}" data-a="{a}" data-b="{b}" marker-end="url(#ah{col})" '
            f'd="M{x1:.0f} {y1:.0f}C{c1[0]:.0f} {c1[1]:.0f} {c2[0]:.0f} {c2[1]:.0f} {ex:.0f} {ey:.0f}"/>')


def draw(systems, D):
    edges, nodes = [], []
    missing = []
    for s in systems:
        cx, cy = s["cx"], s["cy"]
        first = s["nodes"][0]
        fid = f"{s['ref']}-{first.key}"
        sid = "star-" + s["ref"]
        edges.append(curve(cx, cy + STAR_R, first, cx, cy, 0, "e", sid, fid, vstart=True) if first.y - first.h / 2 > cy + STAR_R + 10 else curve(cx + STAR_R, cy, first, cx, cy, 0, "e", sid, fid))
        ordered = s["nodes"]
        for i, n in enumerate(ordered):
            nid = f"{s['ref']}-{n.key}"
            if n.kind == "s":
                t = n.exits or ordered[i + 1].key
                tgt, inter = resolve(systems, s["ref"], t)
                below = isinstance(tgt, Node) and abs(tgt.x - n.x) < 5 and tgt.y > n.y
                x, y = (n.x, n.y + n.h / 2 + (6 if n.kind == "d" else 0)) if below else (n.x + n.w / 2, n.y)
                edges.append(curve(x, y, tgt, cx, cy, 0.12, "e", nid, geom(tgt)[4], vstart=below))
            for j, p in enumerate(n.answers):
                pid = f"{nid}-a{j}"
                x0, y0 = border(n.x, n.y, n.w, n.h, p["x"], p["y"])
                edges.append(f'<path class="stub" data-a="{nid}" data-b="{pid}" d="M{x0:.0f} {y0:.0f}L{p["x"]:.0f} {p["y"]:.0f}"/>')
                p["col"] = answer_col(p["text"], p["target"])
                ts = p["target"] if isinstance(p["target"], tuple) else (p["target"],)
                for t in ts:
                    tgt, inter = resolve(systems, s["ref"], t)
                    tx, ty = (tgt.x, tgt.y) if isinstance(tgt, Node) else (tgt["cx"], tgt["cy"])
                    sx = p["x"] + p["w"] / 2
                    if inter:
                        edges.append(curve(sx, p["y"], tgt, 0, 0, 0.22, "x", nid, geom(tgt)[4], col=p["col"]))
                    else:
                        edges.append(curve(sx, p["y"], tgt, cx, cy, 0.22, "e", nid, geom(tgt)[4], col=p["col"]))
            nodes.append(node_svg(n, nid))
        nodes.append(f'<g class="star" id="{sid}" data-n="{sid}" style="--c:{COL[s["ref"]]}"><circle cx="{cx:.0f}" cy="{cy:.0f}" r="{STAR_R}"/>'
                     f'<text class="sname" x="{cx:.0f}" y="{cy + 14:.0f}" text-anchor="middle">{E(s["name"] if len(s["name"]) < 11 else s["prefix"])}</text></g>'
                     f'<text class="sbig" style="--c:{COL[s["ref"]]}" x="{cx + STAR_R + 40:.0f}" y="{cy + 50:.0f}">{E(s["name"])}</text>')
    return "".join(edges), "".join(nodes)


def node_svg(n, nid):
    x0, y0 = n.x - n.w / 2, n.y - n.h / 2
    out = [f'<g class="n k{n.kind}" data-n="{nid}" style="--c:{COL[n.agent]}">']
    if n.kind in "qod":
        s = 12
        x1, y1 = x0 + n.w, y0 + n.h
        if n.kind == "d":
            out.append(f'<polygon points="{n.x:.0f},{y0 - 6:.0f} {x1 + 6:.0f},{n.y:.0f} {n.x:.0f},{y1 + 6:.0f} {x0 - 6:.0f},{n.y:.0f}"/>')
        else:
            out.append(f'<polygon points="{x0:.0f},{n.y:.0f} {x0 + s:.0f},{y0:.0f} {x1 - s:.0f},{y0:.0f} {x1:.0f},{n.y:.0f} {x1 - s:.0f},{y1:.0f} {x0 + s:.0f},{y1:.0f}"/>')
        out.append(f'<text class="qid" x="{x0 + s:.0f}" y="{y0 - 4:.0f}">{E(n.id)}{" · open" if n.kind == "o" else (" · decision" if n.kind == "d" else "")}</text>')
    else:
        out.append(f'<rect x="{x0:.0f}" y="{y0:.0f}" width="{n.w}" height="{n.h}" rx="3"/>')
    ty = n.y - (len(n.lines) - 1) * ROWH / 2 + 5
    for i, l in enumerate(n.lines):
        out.append(f'<text class="t" x="{n.x:.0f}" y="{ty + i * ROWH:.0f}" text-anchor="middle">{E(l)}</text>')
    out.append("</g>")
    for j, p in enumerate(n.answers):
        out.append(f'<g class="p {p["col"]}" data-n="{nid}-a{j}" data-of="{nid}" style="--c:{COL[n.agent]}"><rect x="{p["x"] - p["w"] / 2:.0f}" y="{p["y"] - PILLH / 2:.0f}" width="{p["w"]:.0f}" height="{PILLH}" rx="12"/>'
                   f'<text x="{p["x"]:.0f}" y="{p["y"] + 4:.0f}" text-anchor="middle">{E(p["text"])}</text></g>')
    return "".join(out)


CSS = """
:root {
  /* One visual world: a night sky in one ink. Shape carries the meaning. Layout idea: Maestro at the centre, seven star systems around it. */
  --sky: #0d1420; --bar: #141e2d; --ink: #d3e3f7; --soft: #8ba3bf; --line: #5b7391;
  --font-body: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
  --font-mono: "IBM Plex Mono", ui-monospace, Menlo, monospace;
  color-scheme: dark;
}
html, body { height: 100%; margin: 0; background: var(--sky); color: var(--ink); font-family: var(--font-body); }
.app { height: 100%; display: flex; flex-direction: column; }
header { background: var(--bar); border-bottom: 1px solid var(--line); padding: 8px 16px; display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: center; }
h1 { font-size: 16px; font-weight: 600; margin: 0; }
.tools, .jump, .key { display: flex; flex-wrap: wrap; gap: 4px 6px; align-items: center; }
.hint { flex-basis: 100%; margin: 0; font-size: 13px; color: #fff; }
footer { background: var(--bar); border-top: 1px solid var(--line); padding: 8px 16px; display: flex; flex-wrap: wrap; gap: 4px 18px; font-size: 12px; color: var(--soft); }
footer strong { color: var(--ink); }
button { font: 500 13px var(--font-body); color: var(--ink); background: none; border: 1px solid var(--line); border-radius: 4px; padding: 4px 9px; cursor: pointer; }
button:hover { background: var(--line); }
button:focus-visible, svg:focus-visible { outline: 2px solid var(--ink); outline-offset: -2px; }
#map { flex: 1; min-height: 0; width: 100%; display: block; touch-action: none; cursor: grab; user-select: none; }
#map.drag { cursor: grabbing; }
.e, .x, .stub { fill: none; stroke: var(--line); stroke-width: 1.5; }
.x { stroke: var(--ink); stroke-width: 3.5; }
.e.ok, .x.ok { stroke: #4ade80; }
.e.y, .x.y { stroke: #ffd21f; }
.e.bad, .x.bad { stroke: #f87171; }
.stub { stroke-width: 1.1; }
.n polygon, .n rect { fill: var(--sky); stroke: var(--c); stroke-width: 1.8; }
.ks rect { stroke: var(--c); stroke-opacity: .6; stroke-width: 1.4; }
.ko polygon { stroke-dasharray: 6 4; }
.kd polygon { stroke: var(--soft); stroke-width: 1.4; }
.kg rect { stroke-dasharray: 6 4; }
.kx rect { stroke-width: 4; }
.ke rect { fill: var(--c); }
.ke .t { fill: var(--sky); font-weight: 600; }
.t { fill: var(--ink); font: 400 13px var(--font-body); }
.qid { fill: var(--c); font: 500 10.5px var(--font-mono); }
.p rect { fill: var(--bar); stroke: var(--c); stroke-opacity: .55; stroke-width: 1.2; }
.p.ok rect { stroke: #4ade80; stroke-opacity: 1; }
.p.bad rect { stroke: #f87171; stroke-opacity: 1; }
.p.y rect { stroke: #ffd21f; stroke-opacity: 1; }
.p text { fill: var(--ink); font: 400 11.5px var(--font-body); }
.star circle { fill: var(--c); }
.sname { fill: var(--sky); font: 600 30px var(--font-body); }
.sbig { fill: var(--c); font: 600 130px var(--font-body); opacity: .9; }
.n, .p, .star { cursor: pointer; }
svg.focus .e, svg.focus .x, svg.focus .stub { opacity: .08; }
svg.focus .n, svg.focus .p { opacity: .28; }
svg.focus .on { opacity: 1; }
svg.focus path.on { stroke-width: 3; }
"""

JS = """
(function () {
  var svg = document.getElementById('map');
  var home = svg.getAttribute('viewBox').split(' ').map(Number);
  var v = home.slice();
  function apply() { svg.setAttribute('viewBox', v.join(' ')); }
  function pt(e) {
    var r = svg.getBoundingClientRect();
    var s = Math.max(v[2] / r.width, v[3] / r.height);
    return { x: v[0] + v[2] / 2 + (e.clientX - r.left - r.width / 2) * s,
             y: v[1] + v[3] / 2 + (e.clientY - r.top - r.height / 2) * s, s: s };
  }
  function zoom(f, p) {
    var w = Math.min(home[2] * 1.5, Math.max(500, v[2] * f)); f = w / v[2];
    p = p || { x: v[0] + v[2] / 2, y: v[1] + v[3] / 2 };
    v = [p.x - (p.x - v[0]) * f, p.y - (p.y - v[1]) * f, v[2] * f, v[3] * f];
    apply();
  }
  svg.addEventListener('wheel', function (e) {
    e.preventDefault();
    zoom(Math.exp(e.deltaY * (e.ctrlKey ? 0.01 : 0.0016)), pt(e));
  }, { passive: false });
  var ptrs = {}, dist = 0, moved = false;
  svg.addEventListener('pointerdown', function (e) {
    svg.setPointerCapture(e.pointerId);
    ptrs[e.pointerId] = { x: e.clientX, y: e.clientY }; moved = false;
    downNode = nodeAt(e);
    svg.classList.add('drag');
  });
  svg.addEventListener('pointermove', function (e) {
    var p = ptrs[e.pointerId]; if (!p) return;
    var ids = Object.keys(ptrs);
    if (ids.length === 2) {
      p.x = e.clientX; p.y = e.clientY;
      var a = ptrs[ids[0]], b = ptrs[ids[1]];
      var d = Math.hypot(a.x - b.x, a.y - b.y);
      if (dist) zoom(dist / d, pt({ clientX: (a.x + b.x) / 2, clientY: (a.y + b.y) / 2 }));
      dist = d; moved = true; return;
    }
    var dx = e.clientX - p.x, dy = e.clientY - p.y;
    if (Math.abs(dx) + Math.abs(dy) > 3) moved = true;
    var r = svg.getBoundingClientRect(), s = Math.max(v[2] / r.width, v[3] / r.height);
    v[0] -= dx * s; v[1] -= dy * s; p.x = e.clientX; p.y = e.clientY; apply();
  });
  var downNode = null;
  function nodeAt(e) { var t = e.target.closest ? e.target.closest('[data-n]') : null; return t; }
  function end(e) {
    delete ptrs[e.pointerId]; dist = 0; svg.classList.remove('drag');
    if (!moved && !Object.keys(ptrs).length) select(downNode);
  }
  svg.addEventListener('pointerup', end);
  svg.addEventListener('pointercancel', end);
  function select(g) {
    svg.querySelectorAll('.on').forEach(function (x) { x.classList.remove('on'); });
    if (!g) { svg.classList.remove('focus'); return; }
    var id = g.getAttribute('data-of') || g.getAttribute('data-n');
    svg.classList.add('focus');
    g.classList.add('on');
    svg.querySelectorAll('[data-a="' + id + '"],[data-b="' + id + '"]').forEach(function (p) {
      p.classList.add('on');
      [p.getAttribute('data-a'), p.getAttribute('data-b')].forEach(function (o) {
        svg.querySelectorAll('[data-n="' + o + '"]').forEach(function (n) { n.classList.add('on'); });
      });
    });
    svg.querySelectorAll('[data-of="' + id + '"]').forEach(function (n) { n.classList.add('on'); });
  }
  document.getElementById('in').onclick = function () { zoom(0.6); };
  document.getElementById('out').onclick = function () { zoom(1 / 0.6); };
  document.getElementById('fit').onclick = function () { v = home.slice(); apply(); select(null); };
  document.querySelectorAll('[data-go]').forEach(function (b) {
    b.onclick = function () {
      var a = b.getAttribute('data-go').split(' ').map(Number);
      v = [a[0] - a[2], a[1] - a[2], a[2] * 2, a[2] * 2]; apply(); select(null);
    };
  });
  svg.addEventListener('keydown', function (e) {
    var k = e.key, s = v[2] * 0.12;
    if (k === '+' || k === '=') zoom(0.8);
    else if (k === '-') zoom(1.25);
    else if (k === '0') { v = home.slice(); apply(); }
    else if (k === 'ArrowLeft') { v[0] -= s; apply(); }
    else if (k === 'ArrowRight') { v[0] += s; apply(); }
    else if (k === 'ArrowUp') { v[1] -= s; apply(); }
    else if (k === 'ArrowDown') { v[1] += s; apply(); }
    else return;
    e.preventDefault();
  });
})();
"""


def main():
    systems = build_nodes()
    D = layout(systems)
    edges, nodes = draw(systems, D)
    extent = max(math.hypot(s["ucx"], s["ucy"]) + s["radius"] for s in systems) + 80
    vb = f"{-extent:.0f} {-extent:.0f} {extent * 2:.0f} {extent * 2:.0f}"
    jump = "".join(f'<button data-go="{s["ucx"]:.0f} {s["ucy"]:.0f} {s["zr"]:.0f}">{E(s["name"])}</button>' for s in systems)
    total_q = sum(1 for s in systems for n in s["nodes"] if n.kind == "q")
    total_d = sum(1 for s in systems for n in s["nodes"] if n.kind == "d")
    total_o = sum(1 for s in systems for n in s["nodes"] if n.kind == "o")
    ans = sum(len(n.answers) for s in systems for n in s["nodes"])
    arrows = edges.count('marker-end')
    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Maestro Star Map</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@500&family=IBM+Plex+Sans:wght@400;600&display=swap">
<style>{CSS}</style>
</head>
<body>
<div class="app">
<header>
<h1>Maestro Star Map</h1>
<div class="tools"><button id="in" aria-label="Zoom in">+</button><button id="out" aria-label="Zoom out">−</button><button id="fit">Show all</button></div>
<div class="jump">{jump}</div>
<p class="hint">Scroll to zoom, drag to move, select a node to trace it</p>
</header>
<svg id="map" viewBox="{vb}" preserveAspectRatio="xMidYMid meet" tabindex="0" role="img" aria-label="Star map of Maestro. Maestro is at the centre with seven agents around it. Every answer has an arrow to the next question, step or agent.">
<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto"><path d="M1 1 L9 5 L1 9" fill="none" style="stroke:var(--ink)" stroke-width="1.8"/></marker><marker id="ahok" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto"><path d="M1 1 L9 5 L1 9" fill="none" style="stroke:#4ade80" stroke-width="1.8"/></marker><marker id="ahbad" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto"><path d="M1 1 L9 5 L1 9" fill="none" style="stroke:#f87171" stroke-width="1.8"/></marker><marker id="ahy" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto"><path d="M1 1 L9 5 L1 9" fill="none" style="stroke:#ffd21f" stroke-width="1.8"/></marker></defs>
{edges}{nodes}
</svg>
<footer><strong>Legend:</strong>
<span>{total_q} questions · {total_o} open follow-ups · {total_d} decisions · {ans} answers · {arrows} arrows</span>
<span>Hexagon: question to the user (QID)</span>
<span>Dashed hexagon: open follow-up (OID)</span>
<span>Diamond: decision, no question (DID)</span>
<span style="color:#4ade80">Green line: yes, happy path</span>
<span style="color:#f87171">Red line: no, escalate, failure</span>
<span style="color:#ffd21f">Yellow thick line: goes to another agent</span>
<span>Colour of a box: the agent</span>
<span>Dashed box: gap</span>
</footer>
</div>
<script>{JS}</script>
</body>
</html>
"""
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
    open(out, "w").write(page)
    print("agents", [(s["ref"], s["qn"], round(s["radius"])) for s in systems])
    print("questions", total_q, "answers", ans, "arrows", arrows, "extent", round(extent), "bytes", len(page))
    for s in systems:
        o = overlaps([(n.x - n.w / 2, n.y - n.h / 2, n.x + n.w / 2, n.y + n.h / 2) for n in s["nodes"]] + [(p["x"] - p["w"] / 2, p["y"] - PILLH / 2, p["x"] + p["w"] / 2, p["y"] + PILLH / 2) for n in s["nodes"] for p in n.answers])
        if o:
            print("overlap", s["ref"], o)
    for s in systems:
        for n in s["nodes"]:
            if n.kind == "q":
                print("Q", n.id, "|", n.text)
    ring = systems
    for i, a in enumerate(ring):
        for b in ring[i + 1:]:
            if math.hypot(a["ucx"] - b["ucx"], a["ucy"] - b["ucy"]) < a["radius"] + b["radius"]:
                print("systems overlap", a["ref"], b["ref"])


main()

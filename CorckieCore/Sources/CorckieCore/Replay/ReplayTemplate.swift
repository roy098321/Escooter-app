import Foundation

/// M5-04: the Ride Replay page, written from scratch for the app (CONCEPT "Sharing a ride"): one self-contained HTML file with a desktop
/// layout (map beside synced charts) and a phone layout (map card, 2 x 2 live squircles, one chart at a time, "This ride" tiles, play
/// controls in the bottom bar). Replay 1/4x ... 50x, stops on the time bar, values / change. No outside address anywhere in the file.
/// The chart rows at the end of the style are the B01 fix (2026-10-03): short windows no longer squash the charts.
/// Placeholders: `/*TITLE*/` (HTML-escaped), `/*DATA*/` (JSON for `D`), `/*TILES*/` (`<image>` elements).
public enum ReplayTemplate {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>/*TITLE*/</title>
<style>
:root{--bg:#f2f3f5;--card:#ffffff;--ink:#14161a;--mut:#6a7079;--acc:#0a84ff;--line:#e1e4e8;--map:#e9e7e1}
@media (prefers-color-scheme:dark){:root{--bg:#0e1013;--card:#191c21;--ink:#f1f2f4;--mut:#9aa1ab;--line:#2a2e35;--map:#1c1f24}}
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{font:15px/1.35 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--ink);overscroll-behavior:none}
button,select{font:inherit;color:inherit}
#app{display:flex;flex-direction:column;height:100vh;height:100dvh}
header{padding:10px 14px 4px;padding-top:max(10px,env(safe-area-inset-top))}
h1{margin:0;font-size:20px;font-weight:650;letter-spacing:-.01em}
#sub{color:var(--mut);font-size:13px}
main{flex:1;min-height:0;overflow-y:auto;padding:8px 12px 12px;display:grid;gap:12px;align-content:start}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px}
#mapcard{position:relative;height:38vh;min-height:220px;overflow:hidden;background:var(--map)}
#map{width:100%;height:100%;display:block;touch-action:none}
#leg{position:absolute;left:8px;bottom:8px;width:130px;padding:5px 7px;border-radius:10px;background:var(--card);border:1px solid var(--line);font-size:11px;color:var(--mut);display:flex;flex-wrap:wrap;justify-content:space-between}#leg i{display:block;width:100%;height:7px;border-radius:4px;margin-bottom:2px}
#nomap{display:none;padding:22px;text-align:center;color:var(--mut)}
.mapbtns{position:absolute;right:8px;top:8px;display:flex;flex-direction:column;gap:6px}
.mapbtns button{width:38px;height:38px;border-radius:12px;border:1px solid var(--line);background:var(--card);font-size:18px;line-height:1}
.mapbtns button.on{background:var(--acc);color:#fff;border-color:var(--acc)}
#live{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.sq{padding:12px 10px;text-align:center}
.sq .lab{font-size:12px;color:var(--mut)}
.sq .val{font-size:30px;font-weight:650;font-variant-numeric:tabular-nums;line-height:1.15}
.sq .unit{font-size:12px;color:var(--mut)}
#tabs{display:flex;gap:6px;overflow-x:auto}
#tabs button{flex:1;padding:8px 6px;border-radius:12px;border:1px solid var(--line);background:var(--card)}
#tabs button.on{background:var(--acc);border-color:var(--acc);color:#fff}
#charts{display:grid;gap:10px}
.chart{display:none;padding:8px 10px}
.chart.on{display:block}
.crow{display:flex;justify-content:space-between;align-items:baseline;gap:8px;font-size:13px;color:var(--mut)}
.crow b{color:var(--ink);font-weight:600}
.cv{font-variant-numeric:tabular-nums;color:var(--ink)}
.cs{width:100%;height:110px;display:block;touch-action:none;cursor:pointer}
#tiles{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.tile{padding:10px 12px}
.tile .lab{font-size:12px;color:var(--mut)}
.tile .val{font-size:18px;font-weight:600;font-variant-numeric:tabular-nums}
footer{padding:8px 12px;padding-bottom:max(8px,env(safe-area-inset-bottom));background:var(--card);border-top:1px solid var(--line)}
#seekwrap{position:relative;height:22px}
#seek{width:100%;margin:0;position:relative;z-index:2;background:transparent}
#marks{position:absolute;left:0;right:0;top:9px;height:6px;z-index:1;pointer-events:none}
#marks i{position:absolute;top:0;height:6px;background:#e53935;opacity:.55;border-radius:3px}
.ctl{display:flex;align-items:center;gap:8px;margin-top:4px}
#play{width:46px;height:40px;border-radius:14px;border:0;background:var(--acc);color:#fff;font-size:18px}
#rate,#mode{height:40px;border-radius:12px;border:1px solid var(--line);background:var(--card);padding:0 8px}
#clock{margin-left:auto;font-variant-numeric:tabular-nums;color:var(--mut);font-size:13px;text-align:right}
@media (min-width:1000px){
  main{grid-template-columns:minmax(0,1.25fr) minmax(0,1fr);grid-template-rows:auto 1fr;align-content:stretch;overflow:hidden}
  #mapcard{grid-row:1/3;height:auto;min-height:0}
  #side{display:grid;gap:12px;grid-template-rows:auto 1fr auto;min-height:0}
  #tabs{display:none}
  .chart{display:block}
  #live{grid-template-columns:repeat(4,1fr)}
  .sq .val{font-size:26px}
}
@media (max-width:999px){
  #side{display:grid;gap:12px}
}
/* fix 2026-10-03: short windows squashed the charts and pushed the side buttons into the next chart */
@media (min-width: 1000px) {
  #charts { grid-auto-rows: minmax(150px, 1fr); overflow-y: auto; overscroll-behavior: contain; padding-right: 4px; scrollbar-gutter: stable; }
  .chart { min-height: 150px; }
  .crow { min-height: 96px; }
}
</style>
</head>
<body>
<div id="app">
<header><h1 id="title"></h1><div id="sub"></div></header>
<main>
<section id="mapcard" class="card">
<svg id="map" viewBox="0 0 100 100" preserveAspectRatio="xMidYMid slice"><g id="tilesg">/*TILES*/</g><path id="halo"></path><g id="route"></g><g id="stopsg"></g><g id="dotg"></g></svg>
<div class="mapbtns"><button id="zin" aria-label="Zoom in">+</button><button id="zout" aria-label="Zoom out">&minus;</button><button id="follow" class="on" aria-label="Follow">&#9678;</button></div>
<div id="nomap">No GPS on this ride, so there is no map. The numbers are complete.</div>
</section>
<div id="side">
<div id="live"></div>
<div id="tabs"></div>
<div id="charts"></div>
<div id="tiles"></div>
</div>
</main>
<footer>
<div id="seekwrap"><div id="marks"></div><input id="seek" type="range" min="0" max="1" step="0.05" value="0" aria-label="Time"></div>
<div class="ctl"><button id="play" aria-label="Play">&#9654;</button><select id="rate" aria-label="Speed"></select><button id="mode">Values</button><span id="clock"></span></div>
</footer>
</div>
<script>
(function () {
'use strict';
var D = /*DATA*/null;
var errors = [];
window.addEventListener('error', function (e) { errors.push(String(e && e.message)); });
function $(id) { return document.getElementById(id); }
function pad2(n) { return (n < 10 ? '0' : '') + n; }
function clock(sec) { sec = Math.max(0, Math.floor(sec)); return pad2(Math.floor(sec / 3600) % 24) + ':' + pad2(Math.floor(sec % 3600 / 60)) + ':' + pad2(sec % 60); }
function dur(sec) { sec = Math.max(0, Math.floor(sec)); return Math.floor(sec / 60) + ':' + pad2(sec % 60); }
function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }
function dash(v, f) { return (v === null || v === undefined) ? '–' : f(v); }

var N = D.spd.length;
var S = D.s;
var hasMap = !!D.map && D.x.length === N;
var RATES = [0.25, 0.5, 1, 2, 5, 10, 20, 50];
var RATE_LABELS = ['¼×', '½×', '1×', '2×', '5×', '10×', '20×', '50×'];
var HEX = ['#7fd37f', '#22b24c', '#f2d21b', '#f28c1b', '#e53935'];
var RAMP = ['#22b24c', '#f2d21b', '#f28c1b', '#e53935'];
var st = { pos: 0, playing: false, rate: 1, follow: true, zoom: 1, change: false, tab: 'spd', last: 0, lastI: -1, dragging: false };

function lerp(a, b, f) { if (a === null || a === undefined) { return b; } if (b === null || b === undefined) { return a; } return a + (b - a) * f; }
function at(arr, pos) { var i = Math.min(N - 1, Math.floor(pos)); var j = Math.min(N - 1, i + 1); return lerp(arr[i], arr[j], pos - i); }

var CH = [
  { k: 'spd', name: 'Speed', unit: 'km/h', color: '#f28c1b', arr: D.spd },
  { k: 'bat', name: 'Battery', unit: '%', color: '#22b24c', arr: D.bat },
  { k: 'pwr', name: 'Power', unit: 'W', color: '#8e5bd6', arr: D.pwr },
  { k: 'ele', name: 'Elevation', unit: 'm', color: '#1e88e5', arr: D.ele }
];

var map = $('map'), seek = $('seek'), playBtn = $('play');
var cum = [0];
var MW = 0, MH = 0;
var haloEl = null, dotEl = null;

function hexRgb(h) { return [parseInt(h.substr(1, 2), 16), parseInt(h.substr(3, 2), 16), parseInt(h.substr(5, 2), 16)]; }
function rampColour(v) {
  var t = clamp(v / 50, 0, 1) * (RAMP.length - 1), i = Math.min(RAMP.length - 2, Math.floor(t)), f = t - i;
  var a = hexRgb(RAMP[i]), b = hexRgb(RAMP[i + 1]);
  return 'rgb(' + Math.round(a[0] + (b[0] - a[0]) * f) + ',' + Math.round(a[1] + (b[1] - a[1]) * f) + ',' + Math.round(a[2] + (b[2] - a[2]) * f) + ')';
}
function smoothSpeed() {
  var out = [], r = 5, i, j, sum, n;
  for (i = 0; i < N; i++) { sum = 0; n = 0; for (j = Math.max(0, i - r); j <= Math.min(N - 1, i + r); j++) { sum += D.spd[j]; n++; } out.push(sum / n); }
  return out;
}

function buildMap() {
  if (!hasMap) { map.style.display = 'none'; $('nomap').style.display = 'block'; $('mapcard').style.height = 'auto'; return; }
  MW = D.map.w; MH = D.map.h;
  var i, d = 0;
  for (i = 1; i < N; i++) { var dx = D.x[i] - D.x[i - 1], dy = D.y[i] - D.y[i - 1]; d += Math.sqrt(dx * dx + dy * dy); cum.push(d); }
  var html = '', sm = smoothSpeed();
  for (i = 1; i < N; i++) {
    html += '<line x1="' + D.x[i - 1] + '" y1="' + D.y[i - 1] + '" x2="' + D.x[i] + '" y2="' + D.y[i] + '" stroke="' + rampColour((sm[i - 1] + sm[i]) / 2) + '" stroke-width="4" stroke-linecap="round" vector-effect="non-scaling-stroke"/>';
  }
  var leg = document.createElement('div');
  leg.id = 'leg';
  leg.innerHTML = '<i style="background:linear-gradient(90deg,' + RAMP.join(',') + ')"></i><span>0</span><span>50 km/h</span>';
  $('mapcard').appendChild(leg);
  $('route').innerHTML = html;
  var dd = 'M' + D.x[0] + ' ' + D.y[0];
  for (i = 1; i < N; i++) { dd += 'L' + D.x[i] + ' ' + D.y[i]; }
  haloEl = $('halo');
  haloEl.setAttribute('d', dd);
  haloEl.setAttribute('fill', 'none');
  haloEl.setAttribute('stroke', '#ffffff');
  haloEl.setAttribute('stroke-width', '10');
  haloEl.setAttribute('stroke-linecap', 'round');
  haloEl.setAttribute('stroke-linejoin', 'round');
  haloEl.setAttribute('pathLength', '1000');
  haloEl.setAttribute('stroke-dasharray', '0 1000');
  haloEl.setAttribute('opacity', '0.95');
  var sh = '';
  for (i = 0; i < D.stops.length; i++) {
    var a = D.stops[i][0], z = D.stops[i][1];
    sh += '<g class="stop"><circle cx="' + D.x[a] + '" cy="' + D.y[a] + '" r="9" fill="#e53935" fill-opacity=".85" stroke="#fff" stroke-width="2" vector-effect="non-scaling-stroke"/>' +
          '<text x="' + D.x[a] + '" y="' + (D.y[a] - 12) + '" text-anchor="middle" font-size="12" font-weight="600" fill="#e53935" stroke="#fff" stroke-width="3" paint-order="stroke">' + dur(z - a) + '</text></g>';
  }
  $('stopsg').innerHTML = sh;
  $('dotg').innerHTML = '<circle id="ring" cx="0" cy="0" r="14" fill="#0a84ff" fill-opacity=".25"/><circle id="dot" cx="0" cy="0" r="7" fill="#0a84ff" stroke="#fff" stroke-width="3" vector-effect="non-scaling-stroke"/>';
  dotEl = $('dotg');
}

function view(px, py) {
  if (!hasMap) { return; }
  var r = map.getBoundingClientRect();
  var W = r.width || 360, H = r.height || 300;
  var kFit = Math.max(MW / W, MH / H);
  var k = st.follow ? Math.min(kFit, (700 / W) / st.zoom) : kFit / st.zoom;
  k = clamp(k, 0.15, 40);
  var vw = W * k, vh = H * k;
  var cx = st.follow ? px : MW / 2, cy = st.follow ? py : MH / 2;
  map.setAttribute('viewBox', (cx - vw / 2) + ' ' + (cy - vh / 2) + ' ' + vw + ' ' + vh);
  haloEl.setAttribute('stroke-width', String(10 * k));
  var ring = $('ring'), dot = $('dot');
  if (ring) { ring.setAttribute('r', String(14 * k)); }
  if (dot) { dot.setAttribute('r', String(7 * k)); }
  var circles = $('stopsg').getElementsByTagName('circle');
  for (var i = 0; i < circles.length; i++) { circles[i].setAttribute('r', String(9 * k)); }
  var texts = $('stopsg').getElementsByTagName('text');
  for (var j = 0; j < texts.length; j++) { texts[j].setAttribute('font-size', String(12 * k)); texts[j].setAttribute('stroke-width', String(3 * k)); }
}

function fmtVal(key, v) {
  if (v === null || v === undefined) { return '–'; }
  if (key === 'bat') { return String(Math.round(v)); }
  return String(Math.round(v));
}

function buildLive() {
  var html = '';
  for (var i = 0; i < CH.length; i++) {
    html += '<div class="sq card"><div class="lab">' + CH[i].name + '</div><div class="val" id="lv_' + CH[i].k + '">–</div><div class="unit" id="lu_' + CH[i].k + '">' + CH[i].unit + '</div></div>';
  }
  $('live').innerHTML = html;
}

function chartSvg(c) {
  var W = Math.min(N, 600), lo = Infinity, hi = -Infinity, i, v;
  var vals = [];
  for (i = 0; i < W; i++) { v = c.arr[Math.round(i / (W - 1) * (N - 1))]; vals.push(v); if (v < lo) { lo = v; } if (v > hi) { hi = v; } }
  if (!(hi > lo)) { hi = lo + 1; }
  var padv = (hi - lo) * 0.08; lo -= padv; hi += padv;
  var d = '';
  for (i = 0; i < W; i++) { d += (i ? 'L' : 'M') + (i / (W - 1) * 1000).toFixed(1) + ' ' + (100 - (vals[i] - lo) / (hi - lo) * 100).toFixed(1); }
  return '<svg class="cs" id="cs_' + c.k + '" viewBox="0 0 1000 100" preserveAspectRatio="none">' +
         '<path d="' + d + 'L1000 100L0 100Z" fill="' + c.color + '" fill-opacity=".16" stroke="none"/>' +
         '<path d="' + d + '" fill="none" stroke="' + c.color + '" stroke-width="2" vector-effect="non-scaling-stroke"/>' +
         '<line id="cl_' + c.k + '" x1="0" x2="0" y1="0" y2="100" stroke="#e53935" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>';
}

function seekTo(pos) { st.pos = clamp(pos, 0, N - 1); st.lastI = -1; render(); }

function buildCharts() {
  var html = '', tabs = '';
  for (var i = 0; i < CH.length; i++) {
    html += '<div class="chart card" id="ch_' + CH[i].k + '"><div class="crow"><b>' + CH[i].name + ' <span style="font-weight:400">(' + CH[i].unit + ')</span></b><span class="cv" id="cv_' + CH[i].k + '">–</span></div>' + chartSvg(CH[i]) + '</div>';
    tabs += '<button data-k="' + CH[i].k + '">' + CH[i].name + '</button>';
  }
  $('charts').innerHTML = html;
  $('tabs').innerHTML = tabs;
  var btns = $('tabs').getElementsByTagName('button');
  for (var b = 0; b < btns.length; b++) {
    btns[b].addEventListener('click', function (e) { st.tab = e.currentTarget.getAttribute('data-k'); tabState(); });
  }
  for (var c = 0; c < CH.length; c++) {
    (function (key) {
      var el = $('cs_' + key);
      function from(e) { var r = el.getBoundingClientRect(); seekTo((e.clientX - r.left) / (r.width || 1) * (N - 1)); }
      el.addEventListener('pointerdown', function (e) { st.dragging = true; from(e); });
      el.addEventListener('pointermove', function (e) { if (st.dragging) { from(e); } });
      window.addEventListener('pointerup', function () { st.dragging = false; });
    })(CH[c].k);
  }
  tabState();
}

function tabState() {
  for (var i = 0; i < CH.length; i++) {
    var on = CH[i].k === st.tab;
    var el = $('ch_' + CH[i].k);
    if (el) { el.className = 'chart card' + (on ? ' on' : ''); }
  }
  var btns = $('tabs').getElementsByTagName('button');
  for (var b = 0; b < btns.length; b++) { btns[b].className = btns[b].getAttribute('data-k') === st.tab ? 'on' : ''; }
}

function buildTiles() {
  var t = [
    ['Distance', dash(S.dist, function (v) { return v.toFixed(1) + ' km'; })],
    ['Time', S.mins + ' min'],
    ['Avg. speed', dash(S.avg, function (v) { return Math.round(v) + ' km/h'; })],
    ['Top speed', dash(S.top, function (v) { return Math.round(v) + ' km/h'; })],
    ['Battery', dash(S.bat0, function (v) { return Math.round(v) + '% → ' + dash(S.bat1, function (w) { return Math.round(w) + '%'; }); })],
    ['Energy', dash(S.wh, function (v) { return '~' + v + ' Wh' + (S.whkm ? ' (' + S.whkm + ' Wh/km)' : ''); })],
    ['Climb', dash(S.gain, function (v) { return '+' + v + ' m −' + (S.loss || 0) + ' m'; })],
    ['Stops', dash(S.stops, function (v) { return String(v); }) + (S.tmax !== null && S.tmax !== undefined ? ' · peak ' + Math.round(S.tmax) + ' °C' : '')]
  ];
  var html = '';
  for (var i = 0; i < t.length; i++) { html += '<div class="tile card"><div class="lab">' + t[i][0] + '</div><div class="val">' + t[i][1] + '</div></div>'; }
  $('tiles').innerHTML = html;
}

function buildMarks() {
  var html = '';
  for (var i = 0; i < D.stops.length; i++) {
    var l = D.stops[i][0] / (N - 1) * 100, w = Math.max(0.4, (D.stops[i][1] - D.stops[i][0]) / (N - 1) * 100);
    html += '<i style="left:' + l.toFixed(2) + '%;width:' + w.toFixed(2) + '%"></i>';
  }
  $('marks').innerHTML = html;
}

function render() {
  var pos = st.pos;
  var i = Math.min(N - 1, Math.floor(pos));
  if (hasMap) {
    var px = at(D.x, pos), py = at(D.y, pos);
    dotEl.setAttribute('transform', 'translate(' + px + ' ' + py + ')');
    var f = cum[N - 1] > 0 ? (at(cum, pos) / cum[N - 1]) : pos / (N - 1);
    haloEl.setAttribute('stroke-dasharray', (f * 1000).toFixed(2) + ' 1000');
    view(px, py);
  }
  seek.value = String(pos);
  var fx = (pos / (N - 1) * 1000).toFixed(1);
  for (var c = 0; c < CH.length; c++) {
    var line = $('cl_' + CH[c].k);
    if (line) { line.setAttribute('x1', fx); line.setAttribute('x2', fx); }
  }
  if (i !== st.lastI) {
    st.lastI = i;
    var back = Math.max(0, i - 10);
    for (var k = 0; k < CH.length; k++) {
      var key = CH[k].k, arr = CH[k].arr;
      var shown = st.change ? (arr[i] - arr[back]) : arr[i];
      var txt = (st.change && shown > 0 ? '+' : '') + fmtVal(key, shown);
      $('lv_' + key).textContent = txt;
      $('lu_' + key).textContent = CH[k].unit + (st.change ? ' in 10 s' : '');
      $('cv_' + key).textContent = txt + ' ' + CH[k].unit;
    }
    $('clock').textContent = clock(D.t0 + i) + ' · ' + dur(i) + ' / ' + dur(N - 1);
  }
}

function syncPlay() { playBtn.innerHTML = st.playing ? '&#10074;&#10074;' : '&#9654;'; }

function step(dt) {
  if (!st.playing) { return; }
  st.pos += dt * st.rate;
  if (st.pos >= N - 1) { st.pos = N - 1; st.playing = false; syncPlay(); }
  render();
}

function frame(ts) {
  if (st.last) { step(Math.min(0.1, (ts - st.last) / 1000)); }
  st.last = ts;
  window.requestAnimationFrame(frame);
}

function setRate(idx) {
  idx = clamp(idx, 0, RATES.length - 1);
  st.rate = RATES[idx];
  $('rate').selectedIndex = idx;
}

function init() {
  if (N < 2) { document.body.textContent = 'This ride has no data to replay.'; return; }
  $('title').textContent = D.title;
  $('sub').textContent = D.date + ' · ' + S.start + '–' + S.end;
  var opts = '';
  for (var i = 0; i < RATES.length; i++) { opts += '<option value="' + i + '">' + RATE_LABELS[i] + '</option>'; }
  $('rate').innerHTML = opts;
  setRate(2);
  seek.max = String(N - 1);
  buildMap(); buildLive(); buildCharts(); buildTiles(); buildMarks();
  syncPlay();
  render();
  playBtn.addEventListener('click', function () { if (st.pos >= N - 1) { st.pos = 0; } st.playing = !st.playing; st.last = 0; syncPlay(); });
  $('rate').addEventListener('change', function () { setRate(parseInt($('rate').value, 10)); });
  $('mode').addEventListener('click', function () { st.change = !st.change; $('mode').textContent = st.change ? 'Change' : 'Values'; st.lastI = -1; render(); });
  seek.addEventListener('input', function () { seekTo(parseFloat(seek.value)); });
  $('zin').addEventListener('click', function () { st.zoom = clamp(st.zoom * 1.5, 0.5, 12); render(); });
  $('zout').addEventListener('click', function () { st.zoom = clamp(st.zoom / 1.5, 0.5, 12); render(); });
  $('follow').addEventListener('click', function () { st.follow = !st.follow; $('follow').className = st.follow ? 'on' : ''; render(); });
  window.addEventListener('resize', function () { render(); });
  document.addEventListener('keydown', function (e) {
    var key = e.key;
    if (key === ' ') { e.preventDefault(); playBtn.click(); }
    else if (key === 'ArrowRight') { seekTo(st.pos + (e.shiftKey ? 60 : 10)); }
    else if (key === 'ArrowLeft') { seekTo(st.pos - (e.shiftKey ? 60 : 10)); }
    else if (key === 'Home') { seekTo(0); }
    else if (key === 'End') { seekTo(N - 1); }
    else if (key === '+' || key === '=') { setRate($('rate').selectedIndex + 1); }
    else if (key === '-') { setRate($('rate').selectedIndex - 1); }
    else if (key === 'f') { $('follow').click(); }
  });
  window.requestAnimationFrame(frame);
}

window.__replay = {
  ready: false,
  errors: errors,
  count: N,
  // the same code the animation frame runs, without waiting for frames: 5 real seconds at 50x
  test: function () {
    st.pos = 0; st.playing = true; setRate(7);
    for (var k = 0; k < 100; k++) { step(0.05); }
    return { pos: st.pos, n: N, rate: st.rate, errors: errors.length, playing: st.playing };
  },
  state: function () { return { pos: st.pos, n: N, playing: st.playing, rate: st.rate, errors: errors.length }; }
};

try { init(); window.__replay.ready = true; } catch (err) { errors.push(String(err && err.stack || err)); }
})();
</script>
</body>
</html>
"""#
}

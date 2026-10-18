// Clipstar's dock: the whole screen while it is open. The Milky Way behind,
// a rail of stardust, and the screenshots and copies riding it, newest at
// the top right. The same design as the Mac app, drawn on one canvas.

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const convertFileSrc = window.__TAURI__.core.convertFileSrc;

const GOLD = '#ffe08a';
const c = document.getElementById('c');
const ctx = c.getContext('2d');

let items = [];            // oldest first, as the app keeps them
let settings = { skin: 'card', arrival: 'warp', size: 150, sky: 0.8, keep_text: 60 };
let unlocked = false;
let open = false, closing = null, openedAt = 0;
let scroll = 0, scrollTarget = 0, lastWheel = 0;
let zoom = { id: null, k: 1, at: 0 };
let hover = null, copied = null, mouse = { x: -1, y: -1 };
const images = new Map(), texts = new Map(), shapes = new Map(), flights = new Map();

// MARK: Sizes, like the Mac app: for a 1440 by 900 screen, following the real one.

const W = () => window.innerWidth, H = () => window.innerHeight;
const screenScale = () => Math.max(0.5, Math.min(W() / 1440, H() / 900));
const INSET = 4, RAIL = 12, GAP = 12, TAIL_ROOM = 150;

const SKINS = {
  card:        { reach: [0, 0],   engines: [[0, 19]], corner: 6 },
  starfighter: { reach: [20, 14], engines: [[-17, 23], [17, 23]], corner: 10 },
  shuttle:     { reach: [18, 18], engines: [[0, 26]], corner: 4 },
  freighter:   { reach: [14, 10], engines: [[-23, 24], [0, 24], [23, 24]], corner: 4 },
  rocket:      { reach: [10, 22], engines: [[0, 26]], corner: 10 },
  satellite:   { reach: [36, 13], engines: [[-19, 19], [19, 19]], corner: 4 },
  xwing:       { reach: [24, 16], engines: [[-45, 18], [45, 18]], corner: 8 },
  capsule:     { reach: [9, 10],  engines: [[0, 26]], corner: 4 },
  module:      { reach: [13, 6],  engines: [[-34, 18], [34, 18]], corner: 4 },
  stealth:     { reach: [26, 16], engines: [[-14, 24], [14, 24]], corner: 4 },
};
const skin = () => SKINS[settings.skin] ? settings.skin : 'card';

function cardSize() {
  const s = settings.size / 100 * screenScale();
  return { w: Math.round(140 * s), h: Math.round(96 * s) + INSET * 2 };
}
const share = k => ({ w: 50 / (50 + 2 * SKINS[k].reach[0]), h: 32 / (32 + 2 * SKINS[k].reach[1]) });
/** The window a screenshot shows in, the same on every ship of a skin. */
function windowSize() {
  const card = cardSize(), k = skin();
  if (k === 'card') return card;
  const sh = share(k), most = { w: card.w * 1.55, h: card.h * 1.6 };
  return { w: Math.min(card.w * 0.85, most.w * sh.w), h: Math.min(card.h * 0.85, most.h * sh.h) };
}
function box() {
  const w = windowSize(), k = skin();
  if (k === 'card') return w;
  const sh = share(k);
  return { w: Math.round(w.w / sh.w), h: Math.round(w.h / sh.h) };
}

// MARK: The rail: from the top right, left along the top, down the left, back along the bottom.

function ring() {
  const b = box(), out = [];
  const topY = RAIL + GAP + b.h / 2, leftX = RAIL + GAP + b.w / 2, bottomY = H() - RAIL - GAP - b.h / 2;
  const stepX = b.w + 24, stepY = b.h + 18;
  const from = leftX + b.w / 2 + 12 + b.w / 2, to = W() - TAIL_ROOM - b.w / 2;
  const cols = Math.max(1, Math.floor((to - from) / stepX) + 1);
  const xs = cols === 1 ? [from] : [...Array(cols).keys()].map(i => from + (to - from) * i / (cols - 1));
  for (const x of [...xs].reverse()) out.push({ side: 'top', x, y: topY });
  const top = topY + b.h + 12, bottom = bottomY - b.h - 12;
  const rows = bottom >= top ? Math.floor((bottom - top) / stepY) + 1 : 0;
  for (let i = 0; i < rows; i++) out.push({ side: 'left', x: leftX, y: rows === 1 ? (top + bottom) / 2 : top + (bottom - top) * i / (rows - 1) });
  for (const x of xs) out.push({ side: 'bottom', x, y: bottomY });
  out.forEach((s, i) => s.index = i);
  return out;
}
const head = r => ({ x: Math.min(r[0].x + box().w * 0.75, W() - 30), y: r[0].y });
const tail = () => ({ x: W() - TAIL_ROOM / 2 - 10, y: H() - RAIL - GAP - box().h / 2 });
function approach(slot) {
  const o = { top: [0, -1], bottom: [0, 1], left: [-1, 0] }[slot.side], sl = slot.index % 2 === 0 ? 0.45 : -0.45;
  const d = [o[0] - o[1] * sl, o[1] + o[0] * sl], l = Math.hypot(d[0], d[1]);
  return [d[0] / l, d[1] / l];
}

/** Where a card is drawn at position p on the rail (0 = newest port). */
function place(p, r) {
  const n = r.length, h = head(r), t = tail();
  if (p < 0 || p > n - 1) {
    const k = 1 - Math.min(1, (p < 0 ? -p : p - (n - 1)) / 0.5);
    if (k <= 0.02) return null;
    const from = p < 0 ? r[0] : r[n - 1], to = p < 0 ? h : t;
    return { x: to.x + (from.x - to.x) * k, y: to.y + (from.y - to.y) * k, slot: from, scale: 0.25 + 0.75 * k, alpha: k };
  }
  const i = Math.floor(p), f = p - i, a = r[i], b = r[Math.min(i + 1, n - 1)];
  return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, slot: f < 0.5 ? a : b, scale: 1, alpha: 1 };
}

// MARK: Arrivals: where a ship is, k of the way from its start to its port.

const ARRIVALS = {
  warp: { dur: 0.6, burns: false, at(k, port, slot) { const e = 1 - (1 - k) ** 4, a = approach(slot); return { x: port.x + a[0] * 1400 * (1 - e), y: port.y + a[1] * 1400 * (1 - e), stretch: 1 + 2.5 * (1 - e) }; } },
  deep: { dur: 1.0, burns: true, at(k, port, slot) {
    const e = 1 - (1 - k) ** 2.2, n = slot.index, mid = { x: W() * 0.55, y: H() * 0.5 };
    const s = { x: mid.x + ((n % 3) - 1) * 50, y: mid.y + (n % 2 ? -24 : 24) };
    const cc = { x: (s.x + port.x) / 2 + (port.y - s.y) * 0.25, y: (s.y + port.y) / 2 - (port.x - s.x) * 0.25 };
    const u = 1 - e; return { x: u * u * s.x + 2 * u * e * cc.x + e * e * port.x, y: u * u * s.y + 2 * u * e * cc.y + e * e * port.y, scale: 0.25 + 0.75 * e }; } },
  formation: { dur: 1.1, burns: true, at(k, port, slot) {
    const e = 1 - (1 - k) ** 2.4, lane = slot.side === 'left' ? H() / 2 : port.y, sx = W() + 120 + slot.index * 34;
    return { x: sx + (port.x - sx) * e, y: lane + (port.y - lane) * e ** 3 }; } },
  reentry: { dur: 0.9, burns: true, at(k, port) { const e = 1 - (1 - k) ** 2, sx = port.x + 160, sy = -160; return { x: sx + (port.x - sx) * e, y: sy + (port.y - sy) * e, heat: 1 - k }; } },
  wormhole: { dur: 1.2, burns: true, at(k, port, slot) {
    const e = 1 - (1 - k) ** 2, a = (1 - e) * 4.5 + slot.index, mid = { x: W() * 0.55, y: H() * 0.5 };
    return { x: mid.x + (port.x - mid.x) * e + Math.cos(a) * 110 * (1 - e), y: mid.y + (port.y - mid.y) * e + Math.sin(a) * 70 * (1 - e), scale: 0.2 + 0.8 * e }; } },
  orbit: { dur: 1.6, burns: true, at(k, port, slot) {
    const mid = { x: W() * 0.55, y: H() * 0.5 }, r = 170 + slot.index * 7, a0 = slot.index * 0.7;
    if (k < 0.5) { const a = k / 0.5 * Math.PI * 2 + a0; return { x: mid.x + Math.cos(a) * r, y: mid.y + Math.sin(a) * r * 0.55, scale: 0.7 }; }
    const e = 1 - (1 - (k - 0.5) / 0.5) ** 2, s = { x: mid.x + Math.cos(a0) * r, y: mid.y + Math.sin(a0) * r * 0.55 };
    return { x: s.x + (port.x - s.x) * e, y: s.y + (port.y - s.y) * e, scale: 0.7 + 0.3 * e }; } },
  hyperjump: { dur: 0.7, burns: false, at(k, port) { return k < 0.55 ? { x: port.x, y: port.y, hidden: true, streak: k / 0.55 } : { x: port.x, y: port.y, flash: 1 - (k - 0.55) / 0.45 }; } },
};
const arrival = () => ARRIVALS[settings.arrival] || ARRIVALS.warp;

// MARK: Drawing helpers

function hexA(h, a) { const n = parseInt(h.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`; }
function rng(seed) { let s = seed; return () => { s = (s * 9301 + 49297) % 233280; return s / 233280; }; }
function blob(x, y, r, col, a) { const g = ctx.createRadialGradient(x, y, 0, x, y, r); g.addColorStop(0, hexA(col, a)); g.addColorStop(1, hexA(col, 0)); ctx.fillStyle = g; ctx.fillRect(x - r, y - r, 2 * r, 2 * r); }
function rr(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, w, h, r); }

let sky = null, skyKey = '';
/** The Milky Way, painted once per screen size, skin and size. */
function paintSky(r) {
  const key = `${W()}x${H()}-${settings.skin}-${settings.size}`;
  if (sky && skyKey === key) return sky;
  const dpr = window.devicePixelRatio || 1, cv = document.createElement('canvas');
  cv.width = W() * dpr; cv.height = H() * dpr;
  const g = cv.getContext('2d'); g.scale(dpr, dpr);
  const rand = rng(11), w = W(), h = H();
  const bg = g.createLinearGradient(0, 0, w, h); bg.addColorStop(0, '#03050f'); bg.addColorStop(1, '#0a1024'); g.fillStyle = bg; g.fillRect(0, 0, w, h);
  for (let i = 0; i < w * h / 260; i++) { g.fillStyle = `rgba(255,255,255,${0.25 + rand() * 0.6})`; const s = rand() * 1.3 + 0.3; g.fillRect(rand() * w, rand() * h, s, s); }
  g.save(); g.globalCompositeOperation = 'lighter'; g.translate(w / 2, h / 2); g.rotate(-0.42);
  const glow = (x, y, rad, col, a) => { const gr = g.createRadialGradient(x, y, 0, x, y, rad); gr.addColorStop(0, hexA(col, a)); gr.addColorStop(1, hexA(col, 0)); g.fillStyle = gr; g.fillRect(x - rad, y - rad, rad * 2, rad * 2); };
  glow(0, 0, w * 0.38, '#ffe6b8', 0.2); glow(-w * 0.15, 10, w * 0.16, '#ffb98a', 0.16); glow(w * 0.17, -8, w * 0.17, '#b8c8ff', 0.14);
  const spread = h * 0.08;
  for (let i = 0; i < w * h / 70; i++) { g.fillStyle = `rgba(255,${225 + rand() * 30},${195 + rand() * 60},${0.12 + rand() * 0.45})`; g.fillRect((rand() - 0.5) * w * 1.6, (rand() + rand() + rand() - 1.5) * spread, 1.1, 1.1); }
  g.restore();
  // Stardust along the rail, head to tail.
  const pts = [head(r), ...r, tail()], b = box();
  g.save(); g.globalCompositeOperation = 'lighter';
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], z = pts[i + 1], len = Math.hypot(z.x - a.x, z.y - a.y);
    for (let j = 0; j < len * 1.6; j++) { const k = rand(); g.fillStyle = hexA(GOLD, 0.15 + rand() * 0.5); g.fillRect(a.x + (z.x - a.x) * k + (rand() - 0.5) * b.w * 0.5, a.y + (z.y - a.y) * k + (rand() - 0.5) * b.h * 0.5, 1.4, 1.4); }
  }
  g.restore();
  sky = cv; skyKey = key;
  return sky;
}

// The hulls, in design units round a screenshot 50 wide and 32 tall at (0, 0).
function metal(x0, y0, x1, y1, a = '#c9d2e3', b = '#5d6577') { const g = ctx.createLinearGradient(x0, y0, x1, y1); g.addColorStop(0, a); g.addColorStop(0.5, '#eef2fa'); g.addColorStop(1, b); return g; }
function poly(pts, fill) { ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]); for (const p of pts.slice(1)) ctx.lineTo(p[0], p[1]); ctx.closePath(); ctx.fillStyle = fill; ctx.fill(); }
const HULLS = {
  starfighter() { poly([[0, -30], [45, 22], [23, 18], [-23, 18], [-45, 22]], metal(-45, 0, 45, 0)); ctx.fillStyle = '#21252f'; ctx.fillRect(-21, 16, 8, 6); ctx.fillRect(13, 16, 8, 6); ctx.fillStyle = '#ff5f57'; ctx.fillRect(-44, 19, 3, 3); ctx.fillStyle = '#28c840'; ctx.fillRect(41, 19, 3, 3); },
  shuttle() { ctx.beginPath(); ctx.moveTo(0, -34); ctx.quadraticCurveTo(31, -20, 29, 24); ctx.lineTo(-29, 24); ctx.quadraticCurveTo(-31, -20, 0, -34); ctx.fillStyle = '#ebebeb'; ctx.fill();
    poly([[-29, 12], [-43, 26], [-23, 24]], '#21252f'); poly([[29, 12], [43, 26], [23, 24]], '#21252f'); poly([[-9, -31], [9, -31], [6, -26], [-6, -26]], '#21252f'); ctx.fillStyle = '#999'; ctx.fillRect(-8, 24, 16, 4); },
  freighter() { ctx.fillStyle = metal(0, -26, 0, 24, '#8f8f8f', '#3d3d3d'); ctx.fillRect(-33, -26, 66, 50); ctx.fillStyle = '#ffb547'; for (let k = 0; k < 6; k++) ctx.fillRect(-33 + k * 11, -26, 5.5, 3); ctx.fillStyle = '#21252f'; ctx.fillRect(-39, -6, 6, 14); ctx.fillRect(33, -6, 6, 14); },
  rocket() { ctx.beginPath(); ctx.moveTo(0, -38); ctx.quadraticCurveTo(27, -22, 23, 24); ctx.lineTo(-23, 24); ctx.quadraticCurveTo(-27, -22, 0, -38); ctx.fillStyle = '#f2f2f2'; ctx.fill();
    ctx.beginPath(); ctx.moveTo(0, -38); ctx.quadraticCurveTo(10, -32, 14, -26); ctx.lineTo(-14, -26); ctx.quadraticCurveTo(-10, -32, 0, -38); ctx.fillStyle = '#e8473f'; ctx.fill();
    poly([[-23, 10], [-35, 28], [-19, 24]], '#e8473f'); poly([[23, 10], [35, 28], [19, 24]], '#e8473f'); },
  satellite() { for (const s of [-1, 1]) { const x0 = s < 0 ? -61 : 31; ctx.fillStyle = '#1c3b8a'; ctx.fillRect(x0, -9, 30, 18); ctx.strokeStyle = '#7fa2ff'; ctx.lineWidth = 0.6; for (let k = 1; k < 5; k++) { ctx.beginPath(); ctx.moveTo(x0 + k * 6, -9); ctx.lineTo(x0 + k * 6, 9); ctx.stroke(); }
      ctx.strokeStyle = '#b3b3b3'; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(s * 25, 0); ctx.lineTo(s * 31, 0); ctx.stroke(); }
    ctx.fillStyle = '#c9a54a'; ctx.fillRect(-27, -18, 54, 36); ctx.strokeStyle = '#ddd'; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(0, -18); ctx.lineTo(0, -28); ctx.stroke(); ctx.fillStyle = '#ddd'; ctx.beginPath(); ctx.arc(0, -29, 2.5, 0, 6.28); ctx.fill(); },
  xwing() { for (const [sx, sy] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) { poly([[sx * 15, sy * 3], [sx * 49, sy * 16], [sx * 49, sy * 10], [sx * 15, sy * -3]], '#d9d9d9'); ctx.fillStyle = '#e8473f'; ctx.fillRect(sx * 37 - 4, sy * 12 - 1.5, 8, 3); }
    rr(-25, -22, 50, 44, 8); ctx.fillStyle = metal(0, -22, 0, 22); ctx.fill(); },
  capsule() { poly([[-14, -26], [14, -26], [33, 20], [-33, 20]], metal(-33, 0, 33, 0, '#808080', '#3d3d3d')); ctx.fillStyle = '#4a2c1a'; ctx.beginPath(); ctx.ellipse(0, 21, 34, 5, 0, 0, 6.28); ctx.fill(); },
  module() { rr(-31, -20, 62, 40, 6); ctx.fillStyle = metal(0, -20, 0, 20, '#b0b0b0', '#4d4d4d'); ctx.fill();
    for (const s of [-1, 1]) { ctx.strokeStyle = GOLD; ctx.lineWidth = 2.5; ctx.beginPath(); ctx.ellipse(s * 34, 0, 4, 18, 0, 0, 6.28); ctx.stroke(); }
    ctx.fillStyle = '#5ff4ff'; for (let k = 0; k < 4; k++) ctx.fillRect(-21 + k * 13, -19, 5, 2); },
  stealth() { ctx.beginPath(); ctx.moveTo(0, -32); ctx.lineTo(51, 24); ctx.lineTo(-51, 24); ctx.closePath(); ctx.fillStyle = '#14191f'; ctx.fill(); ctx.strokeStyle = 'rgba(95,244,255,.7)'; ctx.lineWidth = 1; ctx.stroke(); },
};

function flame(x, y, dx, dy, len, w, seed) {
  const f = 1 + 0.2 * Math.sin(performance.now() / 21 + seed * 3) + 0.1 * Math.sin(performance.now() / 12 + seed);
  const L = len * f, ex = x + dx * L, ey = y + dy * L, nx = -dy, ny = dx;
  ctx.save(); ctx.globalCompositeOperation = 'lighter';
  const g = ctx.createLinearGradient(x, y, ex, ey); g.addColorStop(0, 'rgba(255,255,255,.95)'); g.addColorStop(0.2, hexA(GOLD, 0.9)); g.addColorStop(0.55, 'rgba(255,140,60,.5)'); g.addColorStop(1, 'rgba(255,80,30,0)');
  ctx.fillStyle = g; ctx.beginPath(); ctx.moveTo(x + nx * w, y + ny * w);
  ctx.quadraticCurveTo(x + dx * L * 0.5 + nx * w * 0.7, y + dy * L * 0.5 + ny * w * 0.7, ex, ey);
  ctx.quadraticCurveTo(x + dx * L * 0.5 - nx * w * 0.7, y + dy * L * 0.5 - ny * w * 0.7, x - nx * w, y - ny * w); ctx.closePath(); ctx.fill();
  blob(x, y, w * 1.8, GOLD, 0.5); ctx.restore();
}

// MARK: One docked item

function imageFor(it) {
  if (it.kind !== 'image') return null;
  let img = images.get(it.id);
  if (!img) { img = new Image(); img.src = convertFileSrc(it.path); images.set(it.id, img); }
  return img.complete && img.naturalWidth ? img : null;
}
function shapeFor(it) {
  if (!shapes.has(it.id)) { shapes.set(it.id, null); invoke('text_shape', { id: it.id }).then(s => shapes.set(it.id, s)).catch(() => {}); }
  return shapes.get(it.id);
}
function textFor(it) {
  if (!unlocked) return null;
  if (!texts.has(it.id)) { texts.set(it.id, null); invoke('read_text', { id: it.id }).then(t => texts.set(it.id, t)).catch(() => texts.delete(it.id)); }
  return texts.get(it.id);
}

/** The photo's size inside the window, keeping its proportions. */
function photoSize(it) {
  const win = windowSize(), maxW = win.w - INSET * 2, maxH = win.h - INSET * 2;
  const img = imageFor(it);
  const nw = img ? img.naturalWidth : 280, nh = img ? img.naturalHeight : 180;
  const s = Math.min(maxW / nw, maxH / nh);
  return { w: nw * s, h: nh * s };
}

function drawItem(it, number, x, y, scale, alpha, f) {
  const k = skin(), win = windowSize(), p = photoSize(it), b = box();
  const outer = k === 'card' ? 10 : SKINS[k].corner + INSET, inner = Math.max(0, outer - INSET);
  const zoomed = zoom.id === it.id ? zoom.k : 1;
  ctx.save(); ctx.globalAlpha = alpha; ctx.translate(x, y);
  // Grows towards the middle of the screen, never off an edge.
  const ax = (x / W() - 0.5) * b.w, ay = (y / H() - 0.5) * b.h;
  ctx.translate(ax, ay); ctx.scale(scale * zoomed, scale * zoomed * (f?.stretch || 1)); ctx.translate(-ax, -ay);
  if (f?.heat) { ctx.save(); ctx.globalCompositeOperation = 'lighter'; blob(0, -10, 110, '#ff7a2e', 0.55 * f.heat); ctx.restore(); }
  if (k !== 'card') {
    ctx.save(); ctx.scale(win.w / 50, win.h / 32); HULLS[k](); ctx.restore();
    rr(-win.w / 2, -win.h / 2, win.w, win.h, outer); ctx.fillStyle = '#080a14'; ctx.fill();
  }
  const cw = p.w + INSET * 2, ch = p.h + INSET * 2, hov = hover === it.id;
  ctx.shadowColor = hexA(GOLD, number === 1 || hov ? 0.8 : 0.4); ctx.shadowBlur = number === 1 || hov ? 14 : 6;
  rr(-cw / 2, -ch / 2, cw, ch, outer); ctx.fillStyle = 'rgba(0,0,0,.45)'; ctx.fill(); ctx.shadowBlur = 0;
  ctx.save(); rr(-p.w / 2, -p.h / 2, p.w, p.h, inner); ctx.clip();
  if (it.kind === 'text') {
    ctx.fillStyle = '#0f121f'; ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h);
    const shape = shapeFor(it), text = textFor(it);
    ctx.fillStyle = hexA(GOLD, 0.7); ctx.font = `700 ${Math.max(8, p.h * 0.07)}px Consolas, Menlo, monospace`;
    ctx.fillText(`TEXT · ${shape ? shape[0] : ''}`, -p.w / 2 + 8, -p.h / 2 + p.h * 0.12);
    if (text != null) {
      ctx.fillStyle = '#fff'; ctx.font = `${Math.max(9, p.h * 0.075)}px Consolas, Menlo, monospace`;
      text.split('\n').slice(0, 8).forEach((l, i) => ctx.fillText(l.slice(0, 40), -p.w / 2 + 8, -p.h / 2 + p.h * (0.26 + i * 0.1)));
    } else if (shape) {
      ctx.fillStyle = GOLD; ctx.font = `700 ${Math.max(10, p.h * 0.1)}px Consolas, Menlo, monospace`;
      shape[1].slice(0, 3).forEach((n, i) => ctx.fillText('*'.repeat(Math.min(Math.max(n, 3), 14)), -p.w / 2 + 8, -p.h / 2 + p.h * (0.32 + i * 0.16)));
    }
  } else {
    const img = imageFor(it);
    if (img) ctx.drawImage(img, -p.w / 2, -p.h / 2, p.w, p.h); else { ctx.fillStyle = '#1a1d2b'; ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h); }
    ctx.fillStyle = 'rgba(255,224,138,.07)'; for (let yy = -p.h / 2; yy < p.h / 2; yy += 3) ctx.fillRect(-p.w / 2, yy, p.w, 1);
  }
  ctx.restore();
  rr(-cw / 2, -ch / 2, cw, ch, outer); ctx.strokeStyle = hexA(GOLD, hov ? 1 : 0.7); ctx.lineWidth = hov ? 1.6 : 1.1; ctx.stroke();
  // 1 is the newest.
  const bx = cw / 2, by = -ch / 2, label = String(number);
  ctx.font = '700 11px Consolas, Menlo, monospace'; const bw = Math.max(19, ctx.measureText(label).width + 8);
  rr(bx - bw / 2, by - 9.5, bw, 19, 9.5); ctx.fillStyle = number === 1 ? GOLD : 'rgba(0,0,0,.85)'; ctx.fill(); ctx.strokeStyle = hexA(GOLD, 0.8); ctx.lineWidth = 1; ctx.stroke();
  ctx.fillStyle = number === 1 ? '#000' : '#fff'; ctx.textAlign = 'center'; ctx.fillText(label, bx, by + 4); ctx.textAlign = 'left';
  if (copied && copied.id === it.id) {
    const t = Math.min(1, (performance.now() - copied.at) / 200);
    ctx.globalAlpha = alpha * t; ctx.font = '600 12px Consolas, Menlo, monospace';
    const lw = ctx.measureText('✓ Copied').width + 22, ly = (y > H() / 2 ? -ch / 2 - 22 : ch / 2 + 8);
    rr(-lw / 2, ly, lw, 22, 11); ctx.fillStyle = 'rgba(0,0,0,.75)'; ctx.fill(); ctx.strokeStyle = hexA(GOLD, 0.7); ctx.stroke();
    ctx.fillStyle = GOLD; ctx.textAlign = 'center'; ctx.fillText('✓ Copied', 0, ly + 15); ctx.textAlign = 'left';
  }
  ctx.restore();
  return { x: x - cw / 2 * scale, y: y - ch / 2 * scale, w: cw * scale, h: ch * scale };
}

// MARK: The frame

let hits = [], lockRect = null;
let shown = 0;

function frame() {
  const now = performance.now();
  const dpr = window.devicePixelRatio || 1;
  // The canvas holds device pixels but is laid out in CSS pixels, so it is
  // drawn once at the display's scale (125% on many Windows PCs), not twice.
  const pw = Math.round(W() * dpr), ph = Math.round(H() * dpr);
  if (c.width !== pw || c.height !== ph) {
    c.width = pw; c.height = ph;
    c.style.width = W() + 'px'; c.style.height = H() + 'px';
    sky = null;
  }
  ctx.setTransform(pw / W(), 0, 0, ph / H(), 0, 0);
  ctx.clearRect(0, 0, W(), H());
  const r = ring();
  // Closing: everything slips out past its edge in about a quarter second.
  const leave = closing ? Math.min(1, (now - closing) / 240) : 0;
  shown = closing ? settings.sky * (1 - leave) : Math.min(settings.sky, settings.sky * (now - openedAt) / 300);
  ctx.globalAlpha = shown; ctx.drawImage(paintSky(r), 0, 0, W(), H()); ctx.globalAlpha = 1;
  for (let i = 0; i < 120; i++) { const rd = rng(77 + i); const x = rd() * W(), y = rd() * H(); ctx.fillStyle = `rgba(255,255,255,${(0.5 + 0.5 * Math.sin(now / 400 + i)) * shown})`; ctx.fillRect(x, y, 1.6, 1.6); }

  scroll += (scrollTarget - scroll) * 0.25;
  if (now - zoom.at > 260 && zoom.k > 1) { zoom.k += (1 - zoom.k) * 0.3; if (zoom.k < 1.01) { zoom.k = 1; zoom.id = null; } }

  const live = items.slice().reverse();     // newest first
  const older = Math.max(0, live.length - r.length - Math.round(scroll)), newer = Math.round(scroll);
  if (live.length) {
    const h = head(r), t = tail();
    ctx.save(); ctx.globalAlpha = shown / settings.sky; ctx.globalCompositeOperation = 'lighter';
    blob(h.x, h.y, 34 * (1 + 0.15 * Math.sin(now / 250)), '#ffffff', 0.7); blob(h.x, h.y, 60, GOLD, 0.25);
    blob(t.x, t.y, 40, GOLD, 0.45);
    for (let i = 0; i < 160; i++) { const a = i * 2.39996 + now / 1000 * (0.8 + (i % 7) / 7), d = 6 + (i * 37) % 34; ctx.fillStyle = hexA(GOLD, 0.4 + 0.4 * ((i * 13) % 10) / 10); ctx.fillRect(t.x + Math.cos(a) * d, t.y + Math.sin(a) * d * 0.55, 1.5, 1.5); }
    ctx.restore();
    tag(older > 0 ? `+${older}` : null, t.x, t.y - 40); tag(newer > 0 ? `+${newer} newer` : null, h.x, h.y + 34);
  }

  // Room round a zoomed card: its neighbours slide along the rail away from it.
  const zIndex = zoom.id ? live.findIndex(i => i.id === zoom.id) : -1;
  const ar = arrival();
  hits = [];
  const order = live.map((it, i) => ({ it, i })).sort((a, b) => (a.it.id === zoom.id) - (b.it.id === zoom.id));
  for (const { it, i } of order) {
    let p = i - scroll;
    if (zIndex >= 0 && i !== zIndex) p += (i < zIndex ? -1 : 1) * (zoom.k - 1) * 0.6;
    const pl = place(p, r);
    if (!pl) continue;
    let x = pl.x, y = pl.y, f = null;
    const fl = flights.get(it.id);
    if (leave > 0) {
      const a = approach(pl.slot), e = leave * leave;
      x += a[0] * 900 * e; y += a[1] * 900 * e;
    } else if (fl) {
      const k = Math.min(1, Math.max(0, (now - fl.start) / (ar.dur * 1000)));
      if (k <= 0) continue;
      f = ar.at(k, { x, y }, pl.slot);
      const before = ar.at(Math.max(0, k - 0.02), { x, y }, pl.slot);
      if (f.streak !== undefined) { streak(x, y, pl.slot, f.streak); continue; }
      if (f.hidden) continue;
      if (ar.burns && k < 0.999) {
        const dx = f.x - before.x, dy = f.y - before.y, l = Math.hypot(dx, dy);
        if (l > 0.3) {
          const bx = -dx / l, by = -dy / l, win = windowSize(), s = f.scale || 1, power = Math.min(Math.max(l / 9, 0.35), 1.8);
          if (k < 0.82) for (const [ex, ey] of SKINS[skin()].engines) flame(f.x + ex * win.w / 50 * s, f.y + ey * win.h / 32 * s, bx, by, (40 + 110 * power) * s, 10 * s, it.id + ex);
          if (k > 0.62 && k < 0.95) { const rr2 = Math.sin(Math.PI * (k - 0.62) / 0.33), bb = box(); flame(f.x - bx * bb.w * 0.42, f.y - by * bb.h * 0.42, -bx, -by, 60 * rr2, 9 * rr2 + 1, it.id + 9); }
        }
      }
      x = f.x; y = f.y;
      if (k >= 1) flights.delete(it.id);
    }
    const rect = drawItem(it, i + 1, x, y, pl.scale * (f?.scale || 1), pl.alpha, f);
    if (f?.flash) { ctx.save(); ctx.globalCompositeOperation = 'lighter'; blob(x, y, box().w * 0.6, '#ffffff', 0.9 * f.flash); ctx.restore(); }
    if (!fl && !leave && pl.alpha > 0.9) hits.push({ id: it.id, ...rect });
  }

  // One button for all copied text.
  lockRect = null;
  if (live.some(i => i.kind === 'text') && !closing) {
    const label = unlocked ? '🔓 Hide text' : '🔒 Show text';
    ctx.font = '600 13px Consolas, Menlo, monospace'; const w = ctx.measureText(label).width + 26, x = W() - 90 - w / 2, y = H() / 2 - 15;
    rr(x, y, w, 30, 15); ctx.fillStyle = 'rgba(0,0,0,.7)'; ctx.fill(); ctx.strokeStyle = hexA(GOLD, 0.8); ctx.lineWidth = 1; ctx.stroke();
    ctx.fillStyle = GOLD; ctx.fillText(label, x + 13, y + 20);
    lockRect = { x, y, w, h: 30 };
  }
  if (!live.length && !closing) tag('Take a screenshot and it will dock here', W() / 2, H() / 2);
  if (notice && now - notice.at < 5000) tag(notice.text, W() / 2, H() / 2 + 40);

  if (closing && leave >= 1) { closing = null; open = false; invoke('hide_dock'); return; }
  if (open) requestAnimationFrame(frame);
}

function tag(text, x, y) {
  if (!text) return;
  ctx.font = '700 12px Consolas, Menlo, monospace'; const w = ctx.measureText(text).width + 18;
  rr(x - w / 2, y - 11, w, 22, 11); ctx.fillStyle = 'rgba(0,0,0,.65)'; ctx.fill();
  ctx.fillStyle = GOLD; ctx.textAlign = 'center'; ctx.fillText(text, x, y + 4); ctx.textAlign = 'left';
}
function streak(x, y, slot, t) {
  const a = approach(slot), L = 260 * t, sx = x + a[0] * 300 * (1 - t), sy = y + a[1] * 300 * (1 - t);
  ctx.save(); ctx.globalAlpha = Math.sin(Math.PI * t); ctx.strokeStyle = GOLD; ctx.lineWidth = 3;
  ctx.beginPath(); ctx.moveTo(sx, sy); ctx.lineTo(sx + a[0] * L, sy + a[1] * L); ctx.stroke(); ctx.restore();
}

// MARK: Opening and closing

async function refresh() {
  const s = await invoke('state');
  items = s.items; settings = s.settings; unlocked = s.unlocked;
  if (!unlocked) texts.clear();
}

listen('open', async () => {
  await refresh();
  setTimeout(() => invoke('note', { text: `page ${innerWidth}x${innerHeight} dpr ${devicePixelRatio} canvas ${c.width}x${c.height} css ${c.getBoundingClientRect().width}x${c.getBoundingClientRect().height}` }), 300);
  scroll = scrollTarget = 0; zoom = { id: null, k: 1, at: 0 }; closing = null; copied = null;
  const t0 = performance.now() + 60, r = ring();
  flights.clear();
  items.slice().reverse().forEach((it, i) => { if (i < r.length + 1) flights.set(it.id, { start: t0 + Math.min(i * 45, 600) }); });
  openedAt = performance.now();
  if (!open) { open = true; requestAnimationFrame(frame); }
});
listen('close', () => close());
listen('items', e => { items = e.payload; });
listen('settings', e => { settings = e.payload; sky = null; });

function close() {
  if (!open || closing) return;
  hideMenu();
  closing = performance.now();
}

// MARK: Input

function hitAt(x, y) { return hits.find(h => x >= h.x - 4 && x <= h.x + h.w + 4 && y >= h.y - 4 && y <= h.y + h.h + 4); }

c.addEventListener('mousemove', e => { mouse = { x: e.clientX, y: e.clientY }; hover = hitAt(e.clientX, e.clientY)?.id ?? null; });
c.addEventListener('click', async e => {
  hideMenu();
  if (lockRect && e.clientX >= lockRect.x && e.clientX <= lockRect.x + lockRect.w && e.clientY >= lockRect.y && e.clientY <= lockRect.y + lockRect.h) {
    if (unlocked) { await invoke('lock_text'); unlocked = false; texts.clear(); } else { await unlock(); }
    return;
  }
  const h = hitAt(e.clientX, e.clientY);
  if (!h) { close(); return; }
  await invoke('copy_item', { id: h.id });
  copied = { id: h.id, at: performance.now() };
  setTimeout(close, 650);     // "Copied", then the dock bows out
});
c.addEventListener('dblclick', e => { const h = hitAt(e.clientX, e.clientY); if (h) invoke('open_item', { id: h.id }); });
window.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
let authenticating = false, notice = null;
/** Windows Hello, then every text card shows; says why if it cannot. */
async function unlock() {
  authenticating = true;
  const answer = await invoke('unlock_text');
  authenticating = false;
  unlocked = answer === 'ok';
  const why = { 'not set up': 'Set up Windows Hello (a PIN is enough) in Settings › Accounts › Sign-in options',
                'cancelled': null, 'no device': 'Windows Hello is not available on this PC' }[answer];
  if (!unlocked && why !== null) notice = { text: why || `Could not unlock: ${answer}`, at: performance.now() };
}
window.addEventListener('blur', () => { if (open && !closing && !authenticating) close(); });

// Wheel and two fingers slide the rail; a pinch, or Ctrl and the wheel, zooms
// the card under the pointer, only while it lasts.
c.addEventListener('wheel', e => {
  e.preventDefault();
  if (e.ctrlKey) {
    const h = hitAt(e.clientX, e.clientY) || (zoom.id && { id: zoom.id });
    if (!h) return;
    if (zoom.id !== h.id) zoom = { id: h.id, k: 1, at: 0 };
    zoom.k = Math.min(2, Math.max(1, zoom.k - e.deltaY / 100)); zoom.at = performance.now();
    return;
  }
  const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
  const most = Math.max(0, items.length - ring().length);
  const step = e.deltaMode === 1 || Math.abs(d) >= 100 ? Math.sign(d) : d / 60;
  scrollTarget = Math.min(most, Math.max(0, scrollTarget + step));
  clearTimeout(lastWheel); lastWheel = setTimeout(() => { scrollTarget = Math.round(scrollTarget); }, 180);
}, { passive: false });

// Right click: a small menu for the card.
const menu = document.getElementById('menu');
function hideMenu() { menu.style.display = 'none'; }
c.addEventListener('contextmenu', e => {
  e.preventDefault();
  const h = hitAt(e.clientX, e.clientY);
  if (!h) { hideMenu(); return; }
  const it = items.find(i => i.id === h.id);
  const rows = [['Copy', () => { invoke('copy_item', { id: h.id }); copied = { id: h.id, at: performance.now() }; setTimeout(close, 650); }],
                ['Open', () => invoke('open_item', { id: h.id })],
                ['Show in Explorer', () => invoke('reveal_item', { id: h.id })], null,
                ['Undock', () => invoke('remove_item', { id: h.id })]];
  if (it.kind === 'text' && !unlocked) rows.splice(1, 0, ['Show Text…', unlock]);
  menu.innerHTML = '';
  for (const r of rows) {
    if (!r) { menu.appendChild(document.createElement('hr')); continue; }
    const d = document.createElement('div'); d.textContent = r[0]; d.onclick = ev => { ev.stopPropagation(); hideMenu(); r[1](); }; menu.appendChild(d);
  }
  menu.style.left = Math.min(e.clientX, W() - 200) + 'px'; menu.style.top = Math.min(e.clientY, H() - 180) + 'px'; menu.style.display = 'block';
});

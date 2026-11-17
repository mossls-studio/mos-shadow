// tools/test_wasm.js — 用假宿主直接跑 dist/mos_shadow/mos_shadow.wasm
// 不依赖 EffectCraft，快速验证几何 / 模糊 / 渐隐 / 合成，并输出 PNG。
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.join(__dirname, '..');
const WASM = process.env.WASM || path.join(ROOT, 'dist', 'mos_shadow', 'mos_shadow.wasm');
const OUT = path.join(ROOT, 'tests');

const PARAMS = [
  ['axis_start', 2], ['axis_end', 2], ['aim', 2],
  ['blur', 1], ['blur_start', 1], ['blur_end', 1],
  ['opacity', 1], ['fade_start', 1], ['fade_end', 1],
  ['color', 4], ['source', 1], ['behind', 1], ['only_shadow', 1],
  ['expand', 1],
];

function defaults() {
  return {
    axis_start: [0.12, 0.62], axis_end: [0.88, 0.62], aim: [0.70, 0.24],
    blur: 24, blur_start: 10, blur_end: 100, opacity: 80,
    fade_start: 20, fade_end: 100, color: [0.02, 0.02, 0.03, 1],
    source: 0, behind: 1, only_shadow: 0, expand: 0,
  };
}

function flatten(p, w, h) {
  const out = [];
  for (const [k, n] of PARAMS) {
    const v = p[k];
    if (n === 2) out.push(v[0] * w, v[1] * h);
    else if (n === 4) out.push(...v);
    else out.push(v);
  }
  return out;
}

function star(w, h) {
  // 白色五角星，中心 (w*0.5, h*0.36)，外半径 0.23*min(w,h)
  const cx = w * 0.5, cy = h * 0.36, R = Math.min(w, h) * 0.23;
  const pts = [];
  for (let i = 0; i < 10; i++) {
    const r = i % 2 === 0 ? R : R * 0.42;
    const a = -Math.PI / 2 + i * Math.PI / 5;
    pts.push([cx + Math.cos(a) * r, cy + Math.sin(a) * r]);
  }
  const inside = (x, y) => {
    let c = false;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      const [xi, yi] = pts[i], [xj, yj] = pts[j];
      if (((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) c = !c;
    }
    return c;
  };
  const px = new Float32Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (!inside(x + 0.5, y + 0.5)) continue;
      const i = (y * w + x) * 4;
      px[i] = 0.92; px[i + 1] = 0.92; px[i + 2] = 0.95; px[i + 3] = 1;
    }
  }
  return px;
}

function wideMask(w, h) {
  // 横跨画面的大块条带，模拟文字层，用来量 bbox 优化的收益
  const px = new Float32Array(w * h * 4);
  const x0 = Math.floor(w * 0.06), x1 = Math.floor(w * 0.94);
  const y0 = Math.floor(h * 0.34), y1 = Math.floor(h * 0.66);
  const bars = 9, gap = Math.floor(w * 0.012);
  const bw = Math.floor((x1 - x0 - gap * (bars - 1)) / bars);
  for (let b = 0; b < bars; b++) {
    const bx = x0 + b * (bw + gap);
    for (let y = y0; y < y1; y++) {
      for (let x = bx; x < bx + bw && x < w; x++) {
        const i = (y * w + x) * 4;
        px[i] = 0.9; px[i + 1] = 0.9; px[i + 2] = 0.9; px[i + 3] = 1;
      }
    }
  }
  return px;
}

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const b = Buffer.alloc(8 + data.length + 4);
  b.writeUInt32BE(data.length, 0);
  b.write(type, 4, 'ascii');
  data.copy(b, 8);
  b.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), data])), 8 + data.length);
  return b;
}

function writePng(file, w, h, rgba) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4)
      .copy(raw, y * (w * 4 + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
  fs.writeFileSync(file, png);
}

function composite(px, w, h, bg = [0.62, 0.62, 0.64]) {
  const out = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const a = px[i * 4 + 3], ia = 1 - a;
    for (let c = 0; c < 3; c++) {
      out[i * 4 + c] = Math.round((px[i * 4 + c] + bg[c] * ia) * 255);
    }
    out[i * 4 + 3] = 255;
  }
  return out;
}

async function main() {
  const wabt = await require('wabt')();
  const wasm = fs.readFileSync(WASM);
  const mod = await WebAssembly.compile(wasm);
  const inst = await WebAssembly.instantiate(mod, {});
  const ex = inst.exports;
  const mem = ex.memory;

  const nparams = PARAMS.reduce((a, [, n]) => a + n, 0);
  const w = Number(process.env.W) || 480, h = Number(process.env.H) || 320;
  const nbytes = nparams * 8 + w * h * 16;
  const base = ex.ec_alloc(nbytes);
  const paramsPtr = base;
  const pixPtr = base + nparams * 8;

  console.log('exports:', Object.keys(ex).join(', '));
  console.log('manifest:', ex.ec_manifest_ptr(), ex.ec_manifest_len(),
    JSON.parse(Buffer.from(mem.buffer, ex.ec_manifest_ptr(), ex.ec_manifest_len()).toString()).id);
  console.log('arena:', base, 'nparams:', nparams);

  fs.mkdirSync(OUT, { recursive: true });

  function render(params, name, srcOverride) {
    const flat = flatten(params, w, h);
    const f64 = new Float64Array(mem.buffer, paramsPtr, nparams);
    f64.set(flat);
    const src = srcOverride || star(w, h);
    new Float32Array(mem.buffer, pixPtr, w * h * 4).set(src);
    const t0 = Date.now();
    const rc = ex.ec_render(pixPtr, w, h, paramsPtr, nparams, 0, 1);
    const ms = Date.now() - t0;
    const out = new Float32Array(mem.buffer, pixPtr, w * h * 4);
    if (name) {
      writePng(path.join(OUT, name + '.png'), w, h, composite(out, w, h));
      fs.writeFileSync(path.join(OUT, name + '.rgba'), Buffer.from(out.buffer, out.byteOffset, out.byteLength));
    }
    return { rc, ms, out, src };
  }

  // ---- 1. 基础：无模糊、无渐隐，只显示阴影 ----
  const p1 = defaults();
  p1.blur = 0; p1.only_shadow = 1; p1.opacity = 100; p1.color = [1, 0, 0, 1];
  p1.fade_start = 100; p1.fade_end = 100;
  const r1 = render(p1, '01-basic');
  let sum = 0, max = 0;
  for (let i = 0; i < w * h; i++) { const a = r1.out[i * 4 + 3]; sum += a; max = Math.max(max, a); }
  console.log('01 basic: rc=%d %dms  alphaSum=%s max=%s', r1.rc, r1.ms, sum.toFixed(1), max.toFixed(3));

  // 基线以下应该没有阴影
  let below = 0;
  for (let y = Math.floor(h * p1.axis_start[1]) + 2; y < h; y++)
    for (let x = 0; x < w; x++) below = Math.max(below, r1.out[(y * w + x) * 4 + 3]);
  console.log('  below baseline max alpha:', below.toFixed(4));

  // 阴影应该在 aim 方向有内容
  const aimX = Math.floor(p1.aim[0] * w), aimY = Math.floor(p1.aim[1] * h);
  let nearAim = 0;
  for (let y = aimY - 10; y <= aimY + 10; y++)
    for (let x = aimX - 10; x <= aimX + 10; x++)
      nearAim = Math.max(nearAim, r1.out[(y * w + x) * 4 + 3]);
  console.log('  near aim max alpha:', nearAim.toFixed(4));

  // ---- 2. 渐隐 ----
  const p2 = defaults();
  p2.blur = 0; p2.only_shadow = 1; p2.fade_start = 50; p2.fade_end = 100;
  p2.color = [0, 0, 1, 1];
  const r2 = render(p2, '02-fade');
  // 取 t=0.25 / 0.75 的基线法线位置，沿阴影中心采样
  const A = [p2.axis_start[0] * w, p2.axis_start[1] * h];
  const B = [p2.axis_end[0] * w, p2.axis_end[1] * h];
  const L = [(B[0] - A[0]) / Math.hypot(B[0] - A[0], B[1] - A[1]), (B[1] - A[1]) / Math.hypot(B[0] - A[0], B[1] - A[1])];
  const N = [-L[1], L[0]];
  const baseLen = Math.hypot(B[0] - A[0], B[1] - A[1]);
  const C = [p2.aim[0] * w, p2.aim[1] * h];
  const M = [(A[0] + B[0]) / 2, (A[1] + B[1]) / 2];
  let W = [C[0] - M[0], C[1] - M[1]];
  if (W[0] * N[0] + W[1] * N[1] < 0) { N[0] *= -1; N[1] *= -1; }
  const wn = Math.abs(W[0] * N[0] + W[1] * N[1]);
  const wu = W[0] * L[0] + W[1] * L[1];
  const sampleT = (t, u) => {
    // 源点切向坐标 u、阴影坐标 t -> Q = A + u*L + t*W
    const px = A[0] + u * L[0] + t * W[0];
    const py = A[1] + u * L[1] + t * W[1];
    const xi = Math.round(px), yi = Math.round(py);
    return r2.out[(yi * w + xi) * 4 + 3];
  };
  console.log('02 fade: t=0.25 a=%s  t=0.75 a=%s', sampleT(0.25, baseLen * 0.5).toFixed(3), sampleT(0.75, baseLen * 0.5).toFixed(3));

  // ---- 3. 模糊随距离增加 ----
  const p3 = defaults();
  p3.only_shadow = 1; p3.blur = 30; p3.blur_start = 20; p3.blur_end = 100;
  p3.fade_start = 100; p3.fade_end = 100; p3.color = [0, 0.8, 0, 1];
  const r3 = render(p3, '03-blur');
  console.log('03 blur: %dms  (visual: tests/03-blur.png)', r3.ms);

  if (process.env.WIDE) {
    const p5 = defaults();
    p5.only_shadow = 1; p5.blur = 26; p5.blur_start = 12;
    p5.fade_start = 15; p5.color = [0.1, 0.08, 0.07, 1];
    const r5 = render(p5, '05-wide', wideMask(w, h));
    console.log('05 wide: %dms', r5.ms);
  }

  // ---- 4. 远端放大：t≈0.8 的切向跨度应随 expand 变宽 ----
  const p6 = defaults();
  p6.blur = 0; p6.only_shadow = 1; p6.fade_start = 100; p6.fade_end = 100;
  p6.color = [1, 0, 0.2, 1]; p6.expand = 0;
  const geo6 = (() => {
    const A = [p6.axis_start[0] * w, p6.axis_start[1] * h];
    const B = [p6.axis_end[0] * w, p6.axis_end[1] * h];
    const len = Math.hypot(B[0] - A[0], B[1] - A[1]);
    const L = [(B[0] - A[0]) / len, (B[1] - A[1]) / len];
    const N = [-L[1], L[0]];
    const C = [p6.aim[0] * w, p6.aim[1] * h];
    const M = [(A[0] + B[0]) / 2, (A[1] + B[1]) / 2];
    const W = [C[0] - M[0], C[1] - M[1]];
    if (W[0] * N[0] + W[1] * N[1] < 0) { N[0] *= -1; N[1] *= -1; }
    const wn = Math.abs(W[0] * N[0] + W[1] * N[1]);
    return { A, L, N, wn };
  })();
  const spread = (out) => {
    let mn = Infinity, mx = -Infinity, n = 0;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        if (out[(y * w + x) * 4 + 3] <= 0.1) continue;
        const qx = x + 0.5, qy = y + 0.5;
        const t = ((qx - geo6.A[0]) * geo6.N[0] + (qy - geo6.A[1]) * geo6.N[1]) / geo6.wn;
        if (t < 0.7 || t > 0.9) continue;
        const u = (qx - geo6.A[0]) * geo6.L[0] + (qy - geo6.A[1]) * geo6.L[1];
        mn = Math.min(mn, u); mx = Math.max(mx, u); n++;
      }
    }
    return { mn, mx, span: mx - mn, n };
  };
  const r6 = render(p6, '06-expand');
  const s0 = spread(r6.out);
  const p6e = { ...p6, expand: 100 };
  const r6e = render(p6e, '06-expand-100');
  const s1 = spread(r6e.out);
  console.log('06 expand: u-span t=0.7..0.9 base=%s expand100=%s ratio=%s (n=%d/%d)',
    s0.span.toFixed(2), s1.span.toFixed(2), (s1.span / s0.span).toFixed(3), s0.n, s1.n);
  if (!(s1.span > s0.span * 1.25)) {
    throw new Error('expand did not widen the far end: ' + s0.span + ' -> ' + s1.span);
  }

  function alphaOf(out) {
    const a = new Float32Array(w * h);
    for (let i = 0; i < w * h; i++) a[i] = out[i * 4 + 3];
    return a;
  }

  if (process.env.BENCH) {
    const bench = (label, params, src) => {
      const times = [];
      for (let i = 0; i < 12; i++) times.push(render(params, null, src).ms);
      times.sort((a, b) => a - b);
      const avg = times.reduce((a, b) => a + b, 0) / times.length;
      console.log('bench %s: avg=%sms min=%dms med=%dms', label,
        avg.toFixed(1), times[0], times[6]);
    };
    const b1 = defaults();
    b1.blur = 0; b1.only_shadow = 1; b1.opacity = 100;
    b1.fade_start = 100; b1.fade_end = 100; b1.color = [1, 0, 0, 1];
    const b3 = defaults();
    b3.only_shadow = 1; b3.blur = 30; b3.blur_start = 20;
    b3.fade_start = 100; b3.fade_end = 100; b3.color = [0, 0.8, 0, 1];
    bench('basic', b1);
    bench('blur30', b3);
    const b6 = defaults();
    b6.only_shadow = 1; b6.blur = 0; b6.fade_start = 100; b6.fade_end = 100;
    b6.expand = 60;
    bench('expand60', b6);
    const wide = wideMask(w, h);
    bench('wide-basic', b1, wide);
    bench('wide-blur30', b3, wide);
    const b4 = defaults();
    b4.only_shadow = 0; b4.behind = 1; b4.blur = 26; b4.blur_start = 12;
    b4.fade_start = 15; b4.color = [0.1, 0.08, 0.07, 1];
    bench('wide-behind', b4, wide);
  }

  console.log('wrote', OUT);
}

main().catch((e) => { console.error(e); process.exit(1); });

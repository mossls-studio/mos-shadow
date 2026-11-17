// build.js — 编译 src/mos_shadow.wat → dist/mos_shadow/mos_shadow.wasm
// 并组装可安装的插件 bundle
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const NAME = 'mos_shadow';
const WASM_NAME = 'mos_shadow.wasm';

function escapeWatString(bytes) {
  let out = '';
  for (const b of bytes) {
    if (b === 0x22 || b === 0x5c) out += '\\' + String.fromCharCode(b);
    else if (b >= 0x20 && b <= 0x7e) out += String.fromCharCode(b);
    else out += '\\' + b.toString(16).padStart(2, '0');
  }
  return out;
}

async function main() {
  const manifestSrc = fs.readFileSync(path.join(ROOT, 'src', 'manifest.json'), 'utf8');
  const manifest = JSON.stringify(JSON.parse(manifestSrc));
  const mbytes = Buffer.from(manifest, 'utf8');

  let wat = fs.readFileSync(path.join(ROOT, 'src', 'mos_shadow.wat'), 'utf8');
  if (!wat.includes('__MANIFEST_BYTES__')) throw new Error('wat: missing __MANIFEST_BYTES__ placeholder');
  wat = wat
    .replace('__MANIFEST_BYTES__', escapeWatString(mbytes))
    .replace('__MANIFEST_LEN__', String(mbytes.length));

  const buildDir = path.join(ROOT, 'build');
  fs.mkdirSync(buildDir, { recursive: true });
  fs.writeFileSync(path.join(buildDir, 'mos_shadow.wat'), wat, 'utf8');

  const wabtFactory = require('wabt');
  const wabt = await wabtFactory();
  // wabt 1.0.39 的词法器对源码里的非 ASCII 字节（只可能出现在注释里）会误报
  // `unexpected char`，所以喂给解析器之前把它们换成空格；写回 build/ 的仍是原文。
  const watForParse = wat.replace(/[^\x00-\x7F]/g, ' ');
  let mod;
  try {
    mod = wabt.parseWat('mos_shadow.wat', watForParse, {});
    mod.resolveNames();
    mod.validate();
  } catch (e) {
    console.error('WAT 编译失败:\n' + (e && e.message ? e.message : e));
    process.exit(1);
  }
  const { buffer } = mod.toBinary({ log: false, write_debug_names: false });
  const wasm = Buffer.from(buffer);

  const distDir = path.join(ROOT, 'dist', NAME);
  fs.mkdirSync(distDir, { recursive: true });
  fs.writeFileSync(path.join(distDir, WASM_NAME), wasm);
  fs.writeFileSync(path.join(ROOT, 'build', 'manifest.json'), manifest + '\n');

  const panelDir = path.join(ROOT, 'panel');
  if (fs.existsSync(panelDir)) {
    for (const f of fs.readdirSync(panelDir)) {
      fs.copyFileSync(path.join(panelDir, f), path.join(distDir, f));
    }
  }
  for (const f of ['README.md']) {
    const p = path.join(ROOT, f);
    if (fs.existsSync(p)) fs.copyFileSync(p, path.join(distDir, f));
  }
  for (const f of ['preview.png', 'preview-expand.png', 'preview-bend.png', 'preview-bend-smooth.png', 'preview-layer-color.png']) {
    const p = path.join(ROOT, 'docs', f);
    if (fs.existsSync(p)) {
      fs.mkdirSync(path.join(distDir, 'docs'), { recursive: true });
      fs.copyFileSync(p, path.join(distDir, 'docs', f));
    }
  }

  console.log(`OK  wasm ${wasm.length} bytes  manifest ${mbytes.length} bytes  ->  ${distDir}`);
  console.log(fs.readdirSync(distDir).join('  '));
}

main().catch((e) => { console.error(e); process.exit(1); });

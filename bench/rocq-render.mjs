// Renders one example with the Rocq implementation: drives the Wasm module
// CertiRocq compiled from theories/, outside a browser.
//
// The value representation and the calling convention are the ones
// src/index.js documents; this is the same marshalling without a canvas, so
// that a render can be timed and written to a file from a shell.
//
//   node bench/rocq-render.mjs --name first-light --scene 0 --width 512 \
//        --height 256 --samples 1 --depth 1 --out bench/results
//
// Writes <out>/<name>.rocq.ppm, <out>/<name>.rocq.png and prints one JSON
// object with the timings.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { encodePNG } from "./png.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

// --- the module ------------------------------------------------------------

let ex, names, api, baseMem;

let dataView = null;
const view = () =>
  dataView?.buffer === ex.memory.buffer ? dataView
                                        : (dataView = new DataView(ex.memory.buffer));
const ld = (addr, i) => view().getInt32(addr + 4 * i, true);

const outOfMemory = () => {
  throw Object.assign(new Error("out of memory"), { oom: true });
};

function alloc(words) {
  const addr = ex.mem_ptr.value;
  const end = addr + words.length * 4;
  if (end > ex.memory.buffer.byteLength) {
    const pages = Math.ceil((end - ex.memory.buffer.byteLength) / 65536);
    try { ex.memory.grow(pages); } catch { outOfMemory(); }
  }
  for (let i = 0; i < words.length; i++) view().setInt32(addr + 4 * i, words[i], true);
  ex.mem_ptr.value = end;
  return addr;
}

const mkPair = (a, b) => alloc([0, a, b]);

function mkUint63(n) {
  const v = BigInt(n);
  if (v < 0n || 2n ** 63n <= v) throw new Error("not a 63-bit unsigned integer: " + n);
  return alloc([Number(v % 2n ** 32n), Number(v / 2n ** 32n)]);
}

// a Flt.t is that same cell holding binary64 bits (theories/Flt.v), so one
// setFloat64 is the whole encoding -- the fixed-point port had to scale by
// 2^24 here and put negative values in two's complement.  alloc reserves the
// two words and handles the grow; the float then overwrites them.
function mkFloat(x) {
  const addr = alloc([0, 0]);
  view().setFloat64(addr, x, true);
  return addr;
}

const mkVec3 = (v) => alloc([0, mkFloat(v[0]), mkFloat(v[1]), mkFloat(v[2])]);

const mkKnobs = (k) => alloc([0,
  mkVec3(k.cam), mkFloat(k.vfov), mkFloat(k.aperture), mkFloat(k.focus),
  mkVec3(k.obj), mkFloat(k.radius), mkUint63(k.mat), mkFloat(k.param),
  mkVec3(k.albedo)]);

const mkConfig = (c) => alloc([0,
  mkUint63(c.width), mkUint63(c.height), mkUint63(c.samples),
  mkUint63(c.depth), mkUint63(c.seed), mkUint63(c.scene), mkKnobs(c.knobs)]);

const mkJob = (cfg, y, x0, count) =>
  alloc([0, cfg, mkUint63(y), mkUint63(x0), mkUint63(count)]);

function call(clos, arg) {
  const f = ex[names[clos.fidx]];
  if (typeof f !== "function") throw new Error("closure did not resolve to a function");
  if (f.length === 1) f(arg); else f(clos.env, arg);
  if (ex.out_of_mem.value === 1) outOfMemory();
  return ex.result.value;
}

// list byte: nil is the immediate 1, cons is [0, byte, tail]
function byteList(p) {
  const into = [];
  while (!(p & 1)) { into.push(ld(p, 1) >> 1); p = ld(p, 2); }
  return into;
}

async function boot(wasmPath) {
  const buffer = readFileSync(wasmPath);
  const { instance } = await WebAssembly.instantiate(buffer, { env: {} });
  ex = instance.exports;
  names = Object.keys(ex);
  ex.main_function();
  if (ex.out_of_mem.value === 1) throw new Error("setting up the module ran out of memory");
  const rec = ex.result.value;
  const clos = (i) => { const c = ld(rec, i); return { fidx: ld(c, 1), env: ld(c, 2) }; };
  api = { render: clos(1), prepare: clos(2), header: clos(3) };
  baseMem = ex.mem_ptr.value;
}

// --- the knobs -------------------------------------------------------------

// Scene.default_knobs: the book's camera, and its centre sphere (glass).
// The weekend scene reads only the camera fields, which are the book's and
// the Lean original's: lookfrom (13,2,3), 20 degrees, aperture 0.1, focus 10.
const defaultKnobs = {
  cam: [13, 2, 3],
  vfov: 20,
  aperture: 0.1,
  focus: 10,
  obj: [0, 1, 0],
  radius: 1,
  mat: 2,
  param: 1.5,
  albedo: [0.8, 0.3, 0.3],
};

// --- the render ------------------------------------------------------------

function renderImage(opts, onRow) {
  ex.mem_ptr.value = baseMem;
  const cfg = mkConfig(opts);

  const tPrepare = process.hrtime.bigint();
  const scene = call(api.prepare, cfg);
  const prepareMs = Number(process.hrtime.bigint() - tPrepare) / 1e6;

  const memBase = ex.mem_ptr.value;
  const sceneBytes = memBase - baseMem;   // the world and the camera: the only
                                          // data that outlives a span
  const rewind = () => { ex.mem_ptr.value = memBase; };

  // Price a middle pixel, then fit a span to the budget -- the same
  // chunking src/index.js does, for the same reason: without a garbage
  // collector a job's allocations live until mem_ptr is reset.
  rewind();
  call(api.render, mkPair(scene, mkJob(cfg, opts.height >> 1, opts.width >> 1, 1)));
  const cost = ex.mem_ptr.value - memBase;
  rewind();
  let chunk = Math.max(1, Math.min(opts.width,
    Math.floor(opts.budget / (2 * Math.max(cost, 1)))));

  const rgb = Buffer.alloc(3 * opts.width * opts.height);
  const tRender = process.hrtime.bigint();
  let calls = 0, allocated = 0;   // allocated: every byte a span asks for,
                                  // which the rewind then takes back
  for (let y = 0; y < opts.height; y++) {
    for (let x0 = 0; x0 < opts.width; x0 += chunk) {
      const count = Math.min(chunk, opts.width - x0);
      rewind();
      const bytes = byteList(call(api.render, mkPair(scene, mkJob(cfg, y, x0, count))));
      calls++;
      allocated += ex.mem_ptr.value - memBase;
      if (bytes.length !== 3 * count) {
        throw new Error(`the module returned ${bytes.length} bytes for ${count} pixels`);
      }
      if (ex.mem_ptr.value - memBase > opts.budget && chunk > 1) chunk >>= 1;
      for (let i = 0; i < 3 * count; i++) rgb[3 * (opts.width * y + x0) + i] = bytes[i];
    }
    onRow?.(y);
  }
  const renderMs = Number(process.hrtime.bigint() - tRender) / 1e6;

  const header = Buffer.from(byteList(call(api.header, cfg)));
  return { rgb, header, prepareMs, renderMs, calls, allocated, sceneBytes,
           memoryMB: ex.memory.buffer.byteLength / (1024 * 1024) };
}

// --- the command line ------------------------------------------------------

function parseArgs(argv) {
  const o = {
    name: "render",
    wasm: join(root, "Raytracing.extraction.raytracer_wasm_api.wasm"),
    out: join(root, "bench/results"),
    scene: 1, width: 200, samples: 8, depth: 30, seed: 1,
    budget: 256 * 1024 * 1024,
    quiet: false,
    knobs: defaultKnobs,
  };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].replace(/^--/, "");
    if (key === "quiet") { o.quiet = true; continue; }
    const value = argv[++i];
    if (value === undefined) throw new Error("--" + key + " wants a value");
    o[key] = ["name", "wasm", "out"].includes(key) ? value : Number(value);
  }
  o.height ??= Math.max(1, Math.floor((o.width * 2) / 3));
  o.samples = Math.max(1, o.samples);
  o.depth = Math.max(1, o.depth);
  return o;
}

const opts = parseArgs(process.argv.slice(2));
await boot(opts.wasm);
mkdirSync(opts.out, { recursive: true });

const progress = opts.quiet ? null : (y) => {
  if (y % 16 === 15 || y === opts.height - 1) {
    process.stderr.write(`\r  rocq ${opts.name}: row ${y + 1} / ${opts.height}   `);
  }
};
const r = renderImage(opts, progress);
if (!opts.quiet) process.stderr.write("\n");

const stem = join(opts.out, opts.name + ".rocq");
writeFileSync(stem + ".ppm", Buffer.concat([r.header, r.rgb]));
writeFileSync(stem + ".png", encodePNG(r.rgb, opts.width, opts.height));

console.log(JSON.stringify({
  name: opts.name, impl: "rocq",
  scene: opts.scene, width: opts.width, height: opts.height,
  samples: opts.samples, depth: opts.depth, seed: opts.seed,
  prepare_s: +(r.prepareMs / 1000).toFixed(3),
  render_s: +(r.renderMs / 1000).toFixed(3),
  total_s: +((r.prepareMs + r.renderMs) / 1000).toFixed(3),
  calls: r.calls,
  memory_mb: +r.memoryMB.toFixed(1),
  allocated_mb: +(r.allocated / (1024 * 1024)).toFixed(1),
  scene_kb: +(r.sceneBytes / 1024).toFixed(1),
  bytes_per_sample: Math.round(r.allocated /
    (opts.width * opts.height * (opts.scene === 0 ? 1 : opts.samples))),
  image: stem + ".png",
}));

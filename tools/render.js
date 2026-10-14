#!/usr/bin/env node
// Renders an image with the Wasm module CertiRocq compiled from theories/,
// and writes it as a binary (P6) PPM file.
//
// Usage: node tools/render.js [out.ppm] [--scene 0|1] [--width N] [--height N]
//                            [--samples N] [--depth N] [--seed N] [--chunk N]
//
// The module exports (see the CertiRocq Wasm backend):
//   main_function  computes raytracer_wasm_api into `result`
//   result         global, the value returned by the last call
//   mem_ptr        global, next free address in linear memory (the host may
//                  bump it, and does: see rewind below)
//   out_of_mem     global, 1 when an allocation failed
//   memory         the linear memory
//   ...            every compiled function, under a mangled name; a
//                  closure's function index indexes the export list
//
// Value representation:
//   immediate  (n << 1) | 1       nullary constructor n -- nil, and every
//                                 byte, whose constructors are x00..xff in
//                                 order, so a byte is 2 * value + 1
//   block      [tag, fields...]   i32 words at an even address
//   uint63     an 8-byte little-endian i64 cell, passed as an i32 pointer
//   Fixed.t    a uint63 holding round(x * 2^24), two's complement
//   record     one block, tag 0, the fields in declaration order
//   closure    [tag, fidx, env]
//
// Calling convention (CertiRocq 0.9.1): f(env, arg) for a one-argument
// function, returning nothing; the result is read from `result` afterwards.

const fs = require("fs");
const path = require("path");

// ---- arguments -------------------------------------------------------------

const argv = process.argv.slice(2);
const opts = {
  out: "out.ppm",
  scene: 1,      // 0: one sphere, normals only; 1: the weekend scene; 2: adjustable
  width: 200,
  height: 0,     // 0: width * 2 / 3, the aspect ratio of the original
  samples: 8,
  depth: 16,
  seed: 1,
  chunk: 0,      // pixels per call; 0: as many as fit the budget
  budget: 256,   // MB of linear memory a single call may allocate
  // the knobs: the camera, and the sphere scene 2 lets you move
  cam: "13,2,3",
  vfov: 20,
  aperture: 0.1,
  focus: 10,
  obj: "0,1,0",
  radius: 1,
  mat: 2,        // 0 diffuse, 1 metal, 2 glass
  param: 1.5,    // the metal's fuzz, or the glass's refractive index
  albedo: "0.8,0.3,0.3",
  wasm: "",      // the module; by default whichever of the two below exists
};

// in the source tree the module is what CertiRocq left in the root; in the
// installed bundle it sits next to this script, under its short name
const defaultWasm = () =>
  [path.join(__dirname, "..", "Raytracing.extraction.raytracer_wasm_api.wasm"),
   path.join(__dirname, "raytracer.wasm")].find(fs.existsSync);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith("--")) {
    const key = a.slice(2);
    if (!(key in opts)) { console.error("unknown option: " + a); process.exit(2); }
    const v = argv[++i];
    opts[key] = (typeof opts[key] === "string") ? v : Number(v);
  } else {
    opts.out = a;
  }
}
if (!opts.height) opts.height = Math.max(1, Math.floor((opts.width * 2) / 3));
if (!opts.wasm) opts.wasm = defaultWasm();
if (!opts.wasm) {
  console.error("no Wasm module found; run make, or pass --wasm <file>");
  process.exit(2);
}

// ---- the module ------------------------------------------------------------

const ex = new WebAssembly.Instance(
  new WebAssembly.Module(fs.readFileSync(opts.wasm)), { env: {} }
).exports;
const names = Object.keys(ex);

let dataView = null;
const view = () =>
  dataView?.buffer === ex.memory.buffer ? dataView
                                        : (dataView = new DataView(ex.memory.buffer));
const ld = (addr, i) => view().getInt32(addr + 4 * i, true);

function alloc(words) {
  const addr = ex.mem_ptr.value;
  const end = addr + words.length * 4;
  if (end > ex.memory.buffer.byteLength) {
    ex.memory.grow(Math.ceil((end - ex.memory.buffer.byteLength) / 65536));
  }
  for (let i = 0; i < words.length; i++) view().setInt32(addr + 4 * i, words[i], true);
  ex.mem_ptr.value = end;
  return addr;
}

// a uint63 is an i64 cell; the host passes a pointer to it
function mkUint63(n) {
  const v = BigInt(n);
  if (v < 0n || 2n ** 63n <= v) throw new Error("not a 63-bit unsigned integer: " + n);
  return alloc([Number(v % 2n ** 32n), Number(v / 2n ** 32n)]);
}

// a fixed-point value is that same cell, holding round(x * 2^24); negative
// values are the two's complement, which is how Fixed.v reads the word
const Q = 16777216;
function mkFixed(x) {
  let raw = BigInt(Math.round(x * Q));
  if (raw < 0n) raw += 2n ** 63n;
  return mkUint63(raw);
}

const triple = (s) => String(s).split(",").map(Number);
const mkVec3 = ([x, y, z]) => alloc([0, mkFixed(x), mkFixed(y), mkFixed(z)]);

const mkKnobs = (c) => alloc([0,
  mkVec3(triple(c.cam)), mkFixed(c.vfov), mkFixed(c.aperture), mkFixed(c.focus),
  mkVec3(triple(c.obj)), mkFixed(c.radius), mkUint63(c.mat), mkFixed(c.param),
  mkVec3(triple(c.albedo))]);

const mkConfig = (c) => alloc([0,
  mkUint63(c.width), mkUint63(c.height), mkUint63(c.samples),
  mkUint63(c.depth), mkUint63(c.seed), mkUint63(c.scene), mkKnobs(c)]);

const mkPair = (a, b) => alloc([0, a, b]);

const mkJob = (cfgPtr, y, x0, count) =>
  alloc([0, cfgPtr, mkUint63(y), mkUint63(x0), mkUint63(count)]);

function call(clos, arg) {
  const f = ex[names[clos.fidx]];
  if (typeof f !== "function") throw new Error("closure did not resolve to a function");
  if (f.length === 1) f(arg); else f(clos.env, arg);
  if (ex.out_of_mem.value === 1) throw new Error("the module ran out of memory");
  return ex.result.value;
}

// list byte -> the bytes; nil is the immediate 1, cons is [0, byte, tail]
function byteList(p, into) {
  while (!(p & 1)) {
    into.push(ld(p, 1) >> 1);
    p = ld(p, 2);
  }
  return into;
}

// ---- rendering -------------------------------------------------------------

ex.main_function();
if (ex.out_of_mem.value === 1) throw new Error("setting up the module ran out of memory");

const rec = ex.result.value;
const closure = (i) => { const c = ld(rec, i); return { fidx: ld(c, 1), env: ld(c, 2) }; };
const api = { render: closure(1), prepare: closure(2), header: closure(3) };

// The header, the configuration and the prepared scene are built once and
// have to outlive the jobs, so the watermark is taken after them: a job's
// allocations go above it and are dropped by resetting mem_ptr, which is
// all the freeing there is without a garbage collector.
const cfg = mkConfig(opts);
const header = Buffer.from(byteList(call(api.header, cfg), []));
const scene = call(api.prepare, cfg);
const setup = ex.mem_ptr.value;

const memBase = ex.mem_ptr.value;
const rewind = () => { ex.mem_ptr.value = memBase; };
const pixels = Buffer.alloc(opts.width * opts.height * 3);

// How many pixels a call may cover.  A job's allocations are only freed by
// the rewind that follows it, so the peak is per call: a pixel in the
// middle of the image is priced first (a corner one sees only sky and would
// price the scene far too cheaply), and the budget then fixes the span.
// The loop below still halves it if a call turns out to cost more.
const budgetBytes = opts.budget * 1024 * 1024;
function chooseChunk() {
  if (opts.chunk) return opts.chunk;
  rewind();
  call(api.render, mkPair(scene, mkJob(cfg, opts.height >> 1, opts.width >> 1, 1)));
  const cost = ex.mem_ptr.value - memBase;
  rewind();
  const n = Math.floor(budgetBytes / (2 * Math.max(cost, 1)));
  return Math.max(1, Math.min(n, opts.width));
}
opts.chunk = chooseChunk();

const t0 = Date.now();
let at = 0;
let peakSpan = 0;   // most bytes one call allocated
for (let y = 0; y < opts.height; y++) {
  for (let x0 = 0; x0 < opts.width; x0 += opts.chunk) {
    const count = Math.min(opts.chunk, opts.width - x0);
    rewind();
    const bytes = byteList(call(api.render, mkPair(scene, mkJob(cfg, y, x0, count))), []);
    if (bytes.length !== 3 * count) {
      throw new Error(`row ${y}: expected ${3 * count} bytes, got ${bytes.length}`);
    }
    const used = ex.mem_ptr.value - memBase;
    peakSpan = Math.max(peakSpan, used);
    // a span that cost more than the budget shrinks the next ones
    if (used > budgetBytes && opts.chunk > 1) opts.chunk = Math.max(1, opts.chunk >> 1);
    for (const b of bytes) pixels[at++] = b;
  }
  const done = y + 1;
  const elapsed = (Date.now() - t0) / 1000;
  process.stderr.write(
    `\rrow ${done}/${opts.height}  ${elapsed.toFixed(1)}s` +
    `  eta ${((elapsed / done) * (opts.height - done)).toFixed(1)}s   `);
}
process.stderr.write("\n");

fs.writeFileSync(opts.out, Buffer.concat([header, pixels]));
const MB = (b) => (b / (1024 * 1024)).toFixed(2) + " MB";
console.error(`wrote ${opts.out} (${opts.width}x${opts.height}, scene ${opts.scene}, ` +
  `${opts.samples} samples, depth ${opts.depth}) in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
console.error(`memory: setup ${MB(setup)}, peak per call ${MB(peakSpan)} ` +
  `(${opts.chunk} px/call), linear memory ${MB(ex.memory.buffer.byteLength)}`);

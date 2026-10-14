// Front end for the Rocq raytracer: drives the Wasm module CertiRocq
// compiled from theories/ and paints its pixels onto a canvas.
//
// The module exports (CertiRocq Wasm backend):
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

// Tail-call feature detection, adapted from
// https://github.com/GoogleChromeLabs/wasm-feature-detect (Apache-2.0)
const tailCall = async () =>
  WebAssembly.validate(new Uint8Array([
    0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 6, 1, 4, 0, 18, 0, 11,
  ]));

const $ = (id) => document.getElementById(id);

let ex, names, api;
let running = false, cancel = false, queued = null, liveTimer = 0;

const fail = (msg, fatal = false) => {
  const el = $("err");
  el.textContent = msg;
  el.style.display = "block";
  if (fatal) $("controls").style.display = "none";
};

// A grow detaches the old ArrayBuffer, so the view is checked rather than
// cached: the identity test is O(1) and can never miss.
let dataView = null;
const view = () =>
  dataView?.buffer === ex.memory.buffer ? dataView
                                        : (dataView = new DataView(ex.memory.buffer));
const ld = (addr, i) => view().getInt32(addr + 4 * i, true);

function outOfMemory() {
  throw Object.assign(new Error("out of memory"), { oom: true });
}

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

// a fixed-point value is that same cell, holding round(x * 2^24); negative
// values are the two's complement, which is how Fixed.v reads the word
function mkFixed(x) {
  let raw = BigInt(Math.round(x * 16777216));
  if (raw < 0n) raw += 2n ** 63n;
  return mkUint63(raw);
}

const mkVec3 = (v) => alloc([0, mkFixed(v[0]), mkFixed(v[1]), mkFixed(v[2])]);

const mkKnobs = (k) => alloc([0,
  mkVec3(k.cam), mkFixed(k.vfov), mkFixed(k.aperture), mkFixed(k.focus),
  mkVec3(k.obj), mkFixed(k.radius), mkUint63(k.mat), mkFixed(k.param),
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

// --- the controls ----------------------------------------------------------

const num = (id) => Number($(id).value);

// The colour picker is sRGB-ish and the albedo is a reflectance, so the
// channels are squared -- the renderer's gamma step takes the square root
// back out, which makes the swatch and the sphere agree.
function albedo() {
  const h = $("albedo").value;
  return [1, 3, 5].map((i) => (parseInt(h.slice(i, i + 2), 16) / 255) ** 2);
}

function readOpts(preview) {
  const scene = num("scene");
  const az = (num("azimuth") * Math.PI) / 180;
  const d = num("distance");
  const o = {
    scene,
    width: num("width"),
    samples: Math.max(1, num("samples")),
    depth: Math.max(1, num("depth")),
    seed: num("seed") || 1,
    budget: 256 * 1024 * 1024,     // linear memory one call may allocate
    knobs: {
      cam: [d * Math.cos(az), num("elevation"), d * Math.sin(az)],
      vfov: num("vfov"),
      aperture: num("aperture"),
      focus: num("focus"),
      obj: [num("objx"), num("objy"), num("objz")],
      radius: num("radius"),
      mat: num("mat"),
      param: num("param"),
      albedo: albedo(),
    },
  };
  if (preview) {                   // cheap enough to follow a slider
    o.width = Math.min(o.width, 140);
    o.samples = 1;
    o.depth = Math.min(o.depth, 8);
  }
  o.height = Math.max(1, Math.floor((o.width * 2) / 3));
  return o;
}

// Only the small scenes are fast enough to redraw while a slider moves; the
// weekend scene's 488 spheres are about eighty times the work per ray.
const isLive = () => num("scene") !== 1;

function requestRender(preview) {
  queued = { preview };
  if (running) { cancel = true; return; }
  pump();
}

async function pump() {
  while (queued) {
    const { preview } = queued;
    queued = null;
    await render(preview);
  }
}

function slid(e) {
  const l = e.target.closest("label")?.querySelector(".v");
  if (l) l.textContent = fmt(e.target);
  if (!isLive()) { $("hint").textContent = "press Render to apply"; return; }
  clearTimeout(liveTimer);
  liveTimer = setTimeout(() => requestRender(true), 60);
}

const units = { azimuth: "\u00b0", vfov: "\u00b0" };
const fmt = (el) => el.value + (units[el.id] || "");

// --- rendering --------------------------------------------------------------

const sleep = () => new Promise((r) => setTimeout(r, 0));

async function render(preview) {
  running = true; cancel = false;
  $("go").textContent = "Stop";
  $("err").style.display = "none";

  const opts = readOpts(preview);
  const canvas = $("canvas");
  canvas.width = opts.width;
  canvas.height = opts.height;
  const ctx = canvas.getContext("2d");
  const image = ctx.createImageData(opts.width, 1);

  const t0 = performance.now();
  try {
    // The configuration and the prepared scene outlive the jobs, so the
    // watermark is taken after them; everything a job allocates sits above
    // it and is dropped by resetting mem_ptr -- the only freeing there is
    // without a garbage collector.
    ex.mem_ptr.value = baseMem;
    const cfg = mkConfig(opts);
    const scene = call(api.prepare, cfg);
    const memBase = ex.mem_ptr.value;
    const rewind = () => { ex.mem_ptr.value = memBase; };

    // Price a pixel in the middle of the image (a corner one sees only sky
    // and would price the scene far too cheaply), then fit the span to the
    // budget; a span that still costs more halves the next ones.
    rewind();
    call(api.render, mkPair(scene, mkJob(cfg, opts.height >> 1, opts.width >> 1, 1)));
    const cost = ex.mem_ptr.value - memBase;
    rewind();
    let chunk = Math.max(1, Math.min(opts.width,
      Math.floor(opts.budget / (2 * Math.max(cost, 1)))));

    for (let y = 0; y < opts.height; y++) {
      for (let x0 = 0; x0 < opts.width; x0 += chunk) {
        const count = Math.min(chunk, opts.width - x0);
        rewind();
        const bytes = byteList(call(api.render, mkPair(scene, mkJob(cfg, y, x0, count))));
        if (bytes.length !== 3 * count) throw new Error("the module returned " +
          bytes.length + " bytes for " + count + " pixels");
        if (ex.mem_ptr.value - memBase > opts.budget && chunk > 1) chunk >>= 1;
        for (let i = 0; i < count; i++) {
          image.data[4 * (x0 + i) + 0] = bytes[3 * i];
          image.data[4 * (x0 + i) + 1] = bytes[3 * i + 1];
          image.data[4 * (x0 + i) + 2] = bytes[3 * i + 2];
          image.data[4 * (x0 + i) + 3] = 255;
        }
      }
      ctx.putImageData(image, 0, y);
      const secs = (performance.now() - t0) / 1000;
      $("status").textContent = (preview ? "preview " : "") +
        `row ${y + 1} / ${opts.height}   ${secs.toFixed(1)} s` +
        `   ${(ex.memory.buffer.byteLength / (1024 * 1024)).toFixed(0)} MB`;
      await sleep();                       // let the page paint
      if (cancel || queued) break;         // a newer request supersedes this one
    }
    const secs = ((performance.now() - t0) / 1000).toFixed(1);
    const mem = (ex.memory.buffer.byteLength / (1024 * 1024)).toFixed(0);
    $("status").textContent =
      cancel && !queued ? `stopped after ${secs} s`
      : queued ? `${secs} s`
      : preview ? `preview in ${secs} s   ${mem} MB   -- press Render for ` +
                  `${$("samples").value} samples at full size`
      : `done in ${secs} s   ${mem} MB of linear memory`;
  } catch (e) {
    fail(e.oom
      ? "Out of memory: the module's linear memory could not grow. Try fewer " +
        "samples, less depth, or a smaller image."
      : "Rendering failed: " + e);
  } finally {
    running = false;
    $("go").textContent = "Render";
  }
}

let baseMem;   // what main_function left behind

// --- wiring -----------------------------------------------------------------

function sceneChanged() {
  const scene = num("scene");
  $("object-panel").style.display = scene === 2 ? "" : "none";
  $("camera-panel").style.display = scene === 0 ? "none" : "";
  $("hint").textContent = isLive() ? "the controls redraw a preview as you drag"
                                   : "488 spheres: the controls apply on Render";
}

function matChanged() {
  const mat = num("mat");
  const label = $("param-label");
  label.firstChild.textContent =
    mat === 1 ? "Fuzz " : mat === 2 ? "Refractive index " : "Unused ";
  label.style.opacity = mat === 0 ? ".4" : "";
  $("param").value = mat === 1 ? 0.3 : 1.5;
  label.querySelector(".v").textContent = $("param").value;
}

function wire() {
  for (const el of document.querySelectorAll("input[type=range]")) {
    const l = el.closest("label").querySelector(".v");
    if (l) l.textContent = fmt(el);
    el.addEventListener("input", slid);
    el.addEventListener("change", () => { if (isLive()) requestRender(false); });
  }
  for (const id of ["mat", "albedo"]) {
    $(id).addEventListener("input", (e) => {
      if (id === "mat") matChanged();
      slid(e);
    });
  }
  $("scene").addEventListener("change", () => { sceneChanged(); requestRender(false); });
  for (const id of ["width", "samples", "depth", "seed"]) {
    $(id).addEventListener("change", () => requestRender(false));
  }
  $("go").addEventListener("click", () => {
    if (running) { cancel = true; queued = null; return; }
    requestRender(false);
  });
  $("save").addEventListener("click", () => {
    $("canvas").toBlob((b) => {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(b);
      a.download = "raytracer.png";
      a.click();
      URL.revokeObjectURL(a.href);
    });
  });
  sceneChanged();
  matChanged();
}

async function boot() {
  if (typeof WebAssembly === "undefined") {
    return fail("This browser has WebAssembly disabled, and the renderer is a " +
      "Wasm module. On iPhone, iPad and Mac that is what Lockdown Mode does; " +
      "otherwise a browser policy or an extension has switched it off.", true);
  }
  if (!await tailCall()) {
    return fail("This browser does not support Wasm tail calls, which the " +
      "CertiRocq-compiled module needs. Please use a recent Firefox, Chrome " +
      "or Safari (see webassembly.org/features).", true);
  }
  try {
    const buffer = await (await fetch("raytracer.wasm")).arrayBuffer();
    const { instance } = await WebAssembly.instantiate(buffer, { env: {} });
    ex = instance.exports;
    names = Object.keys(ex);
    ex.main_function();
    if (ex.out_of_mem.value === 1) return fail("Setting up the module ran out of memory.", true);
    const rec = ex.result.value;
    const clos = (i) => { const c = ld(rec, i); return { fidx: ld(c, 1), env: ld(c, 2) }; };
    api = { render: clos(1), prepare: clos(2), header: clos(3) };
    baseMem = ex.mem_ptr.value;
    wire();
    $("status").textContent = "ready";
    requestRender(false);
  } catch (e) {
    fail("Failed to load the renderer: " + e, true);
  }
}

boot();

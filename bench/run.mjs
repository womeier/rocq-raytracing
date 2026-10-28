// Renders every example in bench/examples.json with each implementation
// available, times them, compares the images and writes the results.
//
// Three implementations, two of them the same Rocq source:
//   wasm   theories/ compiled by CertiRocq's Wasm backend, driven by node
//   ocaml  theories/ through Rocq's own OCaml extraction (bench/ocaml/)
//   lean   the two Lean programs this project was ported from
//
//   node bench/run.mjs                  everything that is built
//   node bench/run.mjs --only first-light --only weekend-wide
//   node bench/run.mjs --skip-lean      only the Rocq sides
//   node bench/run.mjs --skip-wasm      the OCaml extraction against Lean
//
// Any implementation whose binary is missing is skipped with a note rather
// than being an error, since the three are built by three different
// commands and the Wasm one does not build at all until CertiRocq accepts
// primitive floats.
//
// Output, in bench/results/ by default:
//   <name>.rocq.png / .ppm     what the Wasm module rendered
//   <name>.ocaml.png / .ppm    what the OCaml extraction rendered
//   <name>.lean.png / .ppm     what the Lean program rendered
//   <name>.diff.png            the per-channel difference, amplified 4x
//   results.json               every timing and every comparison
//   results.md                 the table
//
// The Lean binaries come from bench/setup.sh, the Wasm module from `make`,
// the OCaml one from `make ocaml`.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const bench = dirname(fileURLToPath(import.meta.url));
const root = join(bench, "..");

const WASM = join(root, "Raytracing.extraction.raytracer_wasm_api.wasm");
const WASM_ALT = join(root, "result", "raytracer.wasm");
const OCAML = join(bench, "ocaml/rocq-render");
const KMILL = join(bench, "vendor/lean4-raytracer/.lake/build/bin/render");
const TOTBWF = join(bench, "vendor/lean4-raytrace/.lake/build/bin/trace");

// --- arguments -------------------------------------------------------------

const argv = process.argv.slice(2);
const only = [];
let out = join(bench, "results");
let skipLean = false, skipWasm = false, skipOcaml = false;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--only") only.push(argv[++i]);
  else if (argv[i] === "--out") out = argv[++i];
  else if (argv[i] === "--skip-lean") skipLean = true;
  else if (argv[i] === "--skip-wasm") skipWasm = true;
  else if (argv[i] === "--skip-ocaml") skipOcaml = true;
  // the old name, from when the Wasm module was the only Rocq side
  else if (argv[i] === "--skip-rocq") { skipWasm = true; skipOcaml = true; }
  else { console.error("unknown option " + argv[i]); process.exit(2); }
}

const examples = JSON.parse(readFileSync(join(bench, "examples.json"), "utf8"))
  .filter((e) => only.length === 0 || only.includes(e.name));
if (examples.length === 0) { console.error("no example matched"); process.exit(2); }

// Missing is not an error: say so and carry on with the rest.  Running one
// implementation on its own is the normal case while the other two are
// unavailable.
const wasm = existsSync(WASM) ? WASM : WASM_ALT;
if (!skipWasm && !existsSync(wasm)) {
  console.error(`no Wasm module at ${WASM}: skipping it (build it with 'make')`);
  skipWasm = true;
}
if (!skipOcaml && !existsSync(OCAML)) {
  console.error(`no ${OCAML}: skipping it (build it with 'make ocaml')`);
  skipOcaml = true;
}
if (!skipLean && !(existsSync(KMILL) && existsSync(TOTBWF))) {
  console.error("the Lean binaries are missing: skipping them (bench/setup.sh)");
  skipLean = true;
}
if (skipWasm && skipOcaml && skipLean) {
  console.error("nothing to run");
  process.exit(1);
}
mkdirSync(out, { recursive: true });

// --- running ---------------------------------------------------------------

// Every renderer prints one JSON object on its last line of stdout.
function run(cmd, args, label) {
  process.stderr.write(`\n[${label}]\n`);
  const r = spawnSync(cmd, args.map(String), { stdio: ["ignore", "pipe", "inherit"] });
  if (r.status !== 0) throw new Error(`${label} exited with ${r.status ?? r.signal}`);
  const lines = r.stdout.toString().trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
}

const node = process.execPath;
const results = [];

for (const e of examples) {
  const height = e.height ?? Math.max(1, Math.floor((e.width * 2) / 3));
  const row = { ...e, height, rocq: null, ocaml: null, lean: null,
                leanMT: null, diff: null, diffOcaml: null, diffBackends: null };

  if (!skipWasm) {
    row.rocq = run(node, [join(bench, "rocq-render.mjs"),
      "--name", e.name, "--wasm", wasm, "--out", out,
      "--scene", e.scene, "--width", e.width, "--height", height,
      "--samples", e.samples, "--depth", e.depth, "--seed", e.seed ?? 1],
      `rocq ${e.name}`);
  }

  // The same theories/, the same arguments, a different backend.
  if (!skipOcaml) {
    row.ocaml = run(OCAML, ["--name", e.name, "--out", out, "--quiet",
      "--scene", e.scene, "--width", e.width, "--height", height,
      "--samples", e.samples, "--depth", e.depth, "--seed", e.seed ?? 1],
      `ocaml ${e.name}`);
    spawnSync(node, [join(bench, "ppm.mjs"), "png",
                     join(out, e.name + ".ocaml.ppm"),
                     join(out, e.name + ".ocaml.png")], { stdio: "inherit" });
  }

  if (!skipLean) {
    const ppm = join(out, e.name + ".lean.ppm");
    row.lean = e.lean === "totbwf"
      ? run(TOTBWF, [ppm, e.name], `lean ${e.name}`)
      : run(KMILL, ["--name", e.name, "--out", ppm, "--scene", e.scene,
                    "--width", e.width, "--height", height,
                    "--samples", e.samples, "--depth", e.depth,
                    "--threads", 1], `lean ${e.name}`);
    spawnSync(node, [join(bench, "ppm.mjs"), "png", ppm, join(out, e.name + ".lean.png")],
              { stdio: "inherit" });

    // The same image again, with the original's concurrency: `threads` tasks
    // each rendering the whole frame at samples/threads, averaged, so the
    // samples per pixel -- and so the work -- are the ones in the row above.
    if (e.threads > 1 && e.lean !== "totbwf" && e.samples % e.threads === 0) {
      const mt = join(out, e.name + ".lean-mt.ppm");
      row.leanMT = run(KMILL, ["--name", e.name, "--out", mt, "--scene", e.scene,
                               "--width", e.width, "--height", height,
                               "--samples", e.samples / e.threads, "--depth", e.depth,
                               "--threads", e.threads], `lean ${e.name} x${e.threads}`);
      spawnSync(node, [join(bench, "ppm.mjs"), "png", mt,
                       join(out, e.name + ".lean-mt.png")], { stdio: "inherit" });
    }
  }

  if (row.rocq && row.lean) {
    row.diff = run(node, [join(bench, "ppm.mjs"), "diff",
      join(out, e.name + ".rocq.ppm"), join(out, e.name + ".lean.ppm"),
      join(out, e.name + ".diff.png")], `diff ${e.name}`);
  }
  if (row.ocaml && row.lean) {
    row.diffOcaml = run(node, [join(bench, "ppm.mjs"), "diff",
      join(out, e.name + ".ocaml.ppm"), join(out, e.name + ".lean.ppm"),
      join(out, e.name + ".ocaml-diff.png")], `diff ocaml/lean ${e.name}`);
  }
  // The two backends off one source.  This one should be all zeros once the
  // Wasm module is a float build -- it is the same program compiled twice --
  // so any difference here is a backend bug rather than a rounding story.
  if (row.rocq && row.ocaml) {
    row.diffBackends = run(node, [join(bench, "ppm.mjs"), "diff",
      join(out, e.name + ".rocq.ppm"), join(out, e.name + ".ocaml.ppm"),
      join(out, e.name + ".backends-diff.png")], `diff wasm/ocaml ${e.name}`);
  }
  results.push(row);
}

// --- the report ------------------------------------------------------------

const meta = {
  when: new Date().toISOString(),
  node: process.version,
  platform: `${process.platform} ${process.arch}`,
  cpu: (() => {
    try {
      return readFileSync("/proc/cpuinfo", "utf8")
        .split("\n").find((l) => l.startsWith("model name"))?.split(":")[1].trim();
    } catch { return null; }
  })(),
  wasm: skipWasm ? null : wasm,
  ocaml: skipOcaml ? null : OCAML,
};
writeFileSync(join(out, "results.json"), JSON.stringify({ meta, results }, null, 2) + "\n");

const n = (x) => (x === null || x === undefined ? "--" : x.toFixed(x < 10 ? 2 : 1));
const lines = [
  "# Rocq vs Lean: four renders",
  "",
  `${meta.cpu ?? meta.platform}, one core, node ${meta.node}, ${meta.when.slice(0, 10)}.`,
  "",
  "| example | scene | size | spp | depth | Rocq (Wasm) | Rocq (OCaml) | Lean, 1 core | Lean, N cores | Wasm / OCaml | OCaml / Lean |",
  "|---|---|---|---|---|---|---|---|---|---|---|",
];
for (const r of results) {
  const ws = r.rocq?.render_s, os = r.ocaml?.render_s, ls = r.lean?.render_s;
  lines.push("| " + [
    r.name,
    { 0: "first light", 1: "weekend", 2: "four spheres" }[r.scene] ?? r.scene,
    `${r.width}x${r.height}`,
    r.samples, r.depth,
    ws === undefined ? "--" : n(ws) + " s",
    os === undefined ? "--" : n(os) + " s",
    ls === undefined ? "--" : n(ls) + " s",
    r.leanMT ? `${n(r.leanMT.render_s)} s (x${r.threads})` : "--",
    ws && os ? (ws / os).toFixed(1) + "x" : "--",
    os && ls ? (os / ls).toFixed(1) + "x" : "--",
  ].join(" | ") + " |");
}

// The image comparisons, which say three unrelated things and so get their
// own table rather than more columns on the one above.
lines.push("",
  "## How much the images differ",
  "",
  "Per channel, out of 255.",
  "",
  "| example | OCaml vs Lean | Wasm vs Lean | Wasm vs OCaml |",
  "|---|---|---|---|");
const d = (x) => (x ? `${x.mean_abs_diff.toFixed(2)} mean, ${x.max_abs_diff} max` : "--");
for (const r of results) {
  lines.push("| " + [r.name, d(r.diffOcaml), d(r.diff), d(r.diffBackends)].join(" | ") + " |");
}

lines.push("",
  "Times are the render alone: building the scene and writing the file are",
  "excluded everywhere. Neither Rocq side has threads -- the Wasm module",
  "because it has one linear memory and no garbage collector, the OCaml one",
  "because the renderer is a pure function and nothing here splits it -- so",
  "both are compared with the Lean renderer run inline on one core. The",
  "\"N cores\" column is the original's own task parallelism, the samples split",
  "across the tasks so that every row renders the same samples per pixel.",
  "",
  "\"Wasm / OCaml\" is the interesting ratio: the same theories/ through two",
  "backends, so it is the cost of CertiRocq's calling convention, boxing and",
  "rewound allocator rather than anything about the renderer. \"Wasm vs OCaml\"",
  "in the second table should be zero throughout -- one program compiled",
  "twice -- and any nonzero entry is a backend bug, not a rounding story.",
  "",
  "The other two difference columns cannot be zero: the Rocq renderer draws",
  "from a SplitMix generator (theories/Random.v) and the Lean one from Lean's",
  "stdGen, so a sampled image is the same picture with different noise. The",
  "arithmetic is IEEE binary64 on both sides.",
  "");
writeFileSync(join(out, "results.md"), lines.join("\n"));

process.stderr.write("\n");
console.log(lines.join("\n"));
console.log(`\nwritten to ${out}/`);

// Renders every example in bench/examples.json with both implementations,
// times them, compares the two images and writes the results.
//
//   node bench/run.mjs                  all four examples
//   node bench/run.mjs --only first-light --only weekend-wide
//   node bench/run.mjs --skip-lean      only the Rocq side
//
// Output, in bench/results/ by default:
//   <name>.rocq.png / .ppm     what the Wasm module rendered
//   <name>.lean.png / .ppm     what the Lean program rendered
//   <name>.diff.png            the per-channel difference, amplified 4x
//   results.json               every timing and every comparison
//   results.md                 the table
//
// The Lean binaries come from bench/setup.sh; the Wasm module from `make`.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const bench = dirname(fileURLToPath(import.meta.url));
const root = join(bench, "..");

const WASM = join(root, "Raytracing.extraction.raytracer_wasm_api.wasm");
const WASM_ALT = join(root, "result", "raytracer.wasm");
const KMILL = join(bench, "vendor/lean4-raytracer/.lake/build/bin/render");
const TOTBWF = join(bench, "vendor/lean4-raytrace/.lake/build/bin/trace");

// --- arguments -------------------------------------------------------------

const argv = process.argv.slice(2);
const only = [];
let out = join(bench, "results"), skipLean = false, skipRocq = false;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--only") only.push(argv[++i]);
  else if (argv[i] === "--out") out = argv[++i];
  else if (argv[i] === "--skip-lean") skipLean = true;
  else if (argv[i] === "--skip-rocq") skipRocq = true;
  else { console.error("unknown option " + argv[i]); process.exit(2); }
}

const examples = JSON.parse(readFileSync(join(bench, "examples.json"), "utf8"))
  .filter((e) => only.length === 0 || only.includes(e.name));
if (examples.length === 0) { console.error("no example matched"); process.exit(2); }

const wasm = existsSync(WASM) ? WASM : WASM_ALT;
if (!skipRocq && !existsSync(wasm)) {
  console.error(`no Wasm module at ${WASM}; run 'make' or 'nix build' first`);
  process.exit(1);
}
if (!skipLean && !(existsSync(KMILL) && existsSync(TOTBWF))) {
  console.error("the Lean binaries are missing; run bench/setup.sh first");
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
  const row = { ...e, height, rocq: null, lean: null, leanMT: null, diff: null };

  if (!skipRocq) {
    row.rocq = run(node, [join(bench, "rocq-render.mjs"),
      "--name", e.name, "--wasm", wasm, "--out", out,
      "--scene", e.scene, "--width", e.width, "--height", height,
      "--samples", e.samples, "--depth", e.depth, "--seed", e.seed ?? 1],
      `rocq ${e.name}`);
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
  wasm,
};
writeFileSync(join(out, "results.json"), JSON.stringify({ meta, results }, null, 2) + "\n");

const n = (x) => (x === null || x === undefined ? "--" : x.toFixed(x < 10 ? 2 : 1));
const lines = [
  "# Rocq vs Lean: four renders",
  "",
  `${meta.cpu ?? meta.platform}, one core, node ${meta.node}, ${meta.when.slice(0, 10)}.`,
  "",
  "| example | scene | size | spp | depth | Rocq (Wasm) | Lean, 1 core | Lean, N cores | Rocq / Lean | mean diff | max diff |",
  "|---|---|---|---|---|---|---|---|---|---|---|",
];
for (const r of results) {
  const rs = r.rocq?.render_s, ls = r.lean?.render_s;
  lines.push("| " + [
    r.name,
    { 0: "first light", 1: "weekend", 2: "four spheres" }[r.scene] ?? r.scene,
    `${r.width}x${r.height}`,
    r.samples, r.depth,
    rs === undefined ? "--" : n(rs) + " s",
    ls === undefined ? "--" : n(ls) + " s",
    r.leanMT ? `${n(r.leanMT.render_s)} s (x${r.threads})` : "--",
    rs && ls ? (rs / ls).toFixed(1) + "x" : "--",
    r.diff ? r.diff.mean_abs_diff.toFixed(2) : "--",
    r.diff ? String(r.diff.max_abs_diff) : "--",
  ].join(" | ") + " |");
}
lines.push("",
  "Times are the render alone: building the scene and writing the file are",
  "excluded on both sides. The Rocq module has no threads at all; the Lean",
  "renderer is timed both inline on one core and with the original's task",
  "parallelism, the samples split across the tasks so that both render the same",
  "number of samples per pixel. The differences are per channel, out of 255;",
  "the two cannot agree exactly, since the Rocq renderer computes in Q38.24",
  "fixed point with a SplitMix generator and the Lean one in IEEE doubles with",
  "Lean's stdGen.",
  "");
writeFileSync(join(out, "results.md"), lines.join("\n"));

process.stderr.write("\n");
console.log(lines.join("\n"));
console.log(`\nwritten to ${out}/`);

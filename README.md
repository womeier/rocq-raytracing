# A raytracer in Rocq, compiled to WebAssembly by CertiRocq

Live demo at [https://womeier.github.io/rocq-raytracing](https://womeier.github.io/rocq-raytracing).

## About

Raytracing in [Rocq](https://rocq-prover.org/) and compiled to a single Wasm module by [CertiRocq](https://github.com/CertiCoq/certicoq).
Inspired by the book *Ray Tracing in One Weekend*,
based on [kmill/lean4-raytracer](https://github.com/kmill/lean4-raytracer) (the scene, the materials and the camera) and
[TOTBWF/lean4-raytrace](https://github.com/TOTBWF/lean4-raytrace).

There are no floats in the Wasm module: CertiRocq's Wasm backend does not compile
primitive floats, so the arithmetic is done on primitive 63-bit integers.


## Building and running
### Local webserver (recommended)
```sh
nix run .#serve
# then open the page on localhost:8000
```

### Command line
```sh
nix develop                 # rocq 9.1 + CertiRocq + node
make                        # -> Raytracing.extraction.raytracer_wasm_api.wasm

node tools/render.js out.ppm --scene 1 --width 200 --samples 8 --depth 16
node tools/render.js out.ppm --scene 2 --mat 1 --param 0.25 --radius 1.7

# or directly
nix run . -- out.ppm --scene 2
```

## Scenes and options

There are three scenes. `--scene 0` is one sphere shaded by its normal,
`--scene 1` is the book's final image (488 spheres), and `--scene 2` is three
spheres whose middle one the remaining options move and re-surface.

`tools/render.js` options: `--scene 0|1|2`, `--width`, `--height`, `--samples`,
`--depth`, `--seed`, `--chunk` (pixels per call, default: as many as the budget
allows), `--budget` (MB of linear memory one call may allocate, default 256),
`--wasm` (which module to run), and the knobs `--cam x,y,z`, `--vfov`,
`--aperture`, `--focus`, `--obj x,y,z`, `--radius`, `--mat 0|1|2` (diffuse,
metal, glass), `--param` (the metal's fuzz, or the glass's refractive index)
and `--albedo r,g,b`.

## File Layout

| | |
|---|---|
| `theories/Fixed.v` | Q38.24 fixed point on `int63`, including decimal literals |
| `theories/Trig.v` | sine, cosine and tangent, for the camera's field of view |
| `theories/Vec3.v` | vectors and colours (`Render/Vec3.lean`) |
| `theories/Random.v` | SplitMix, replacing the Lean original's `IO` randomness |
| `theories/Scene.v` | rays, camera, materials, spheres, `ray_color` (`Main.lean`), and the three scenes |
| `theories/Render.v` | sampling, gamma, PPM output, jobs |
| `theories/Proofs.v` | the output-shape theorem, and the arithmetic specs |
| `theories/Tests.v` | expectations checked by conversion at build time |
| `theories/extraction.v` | the three entry points, and `CertiRocq Compile Wasm` |
| `tools/render.js` | the node driver: renders a PPM file |
| `src/` | the browser front end: renders onto a canvas, with controls |

Everything the controls set is a field of `Scene.knobs`, which `prepare` reads;
the host writes those fields as fixed-point words (`round(x * 2^24)`), so the
JavaScript never has to agree with the module about anything but the layout of
a record.


## Why fixed point
The backend rejects primitive floats outright:

```coq
| AstCommon.primFloat => Err "Extraction of floats to Wasm not yet supported"
```
(`CertiRocq/CodegenWasm/LambdaANF_to_Wasm.v`)

Primitive 63-bit integers are supported, so `Fixed.t` is an `int63` read as a
two's-complement signed integer scaled by 2^24: resolution 6e-8, range +-2.7e11.

Rocq *does* have a signed reading of that word, `Sint63` — but its operations
(`asr`, `divs`, `mods`, `ltsb`, `lesb`, `compares`) are themselves primitives, and
the backend's table has unsigned ones only; anything outside it fails with
`Err ("Unsupported primitive operator: " ++ kername)`. So `Fixed.v` derives the
signed operations from the unsigned primitives, and uses `Sint63.to_Z` — a
definition, not a primitive — only in the specifications.

Multiplication and division each have two paths: a single-word one for the
magnitudes the scenes actually use (|x| < 128), and a general one through `mulc`
and `diveucl_21`. The fast path matters because the pair those two return is a
heap allocation, and there is no garbage collector to take it back.

`Fixed.v` also registers a `Number Notation`, so the port reads like the Lean
original — `0.5`, `13`, `1.5`, `-0.001` are fixed-point literals, and results
print back as exact decimals (every value is k/2^24, which is a finite decimal):

```coq
Eval vm_compute in Fixed.sqrt 2.
     = 1.41421353816986083984375
```

## The host interface

The module exposes three entry points in one record, so that a single Wasm module
holds everything and shares one linear memory:

```coq
api_header  : config -> list byte                 (* the PPM header *)
api_prepare : config -> scene_data                (* the world and the camera *)
api_render  : scene_data * job -> list byte       (* a span of a row *)
```

## Memory and speed

Measured with `tools/render.js`, which prints these numbers itself. The
weekend scene is the book's final one: 488 spheres, every one of them tested
for every ray, as in the Lean original.

| | per call | linear memory |
|---|---|---|
| first-light scene, 200x100, whole rows | 0.8 MB | 0.9 MB |
| weekend scene, 10 px/call, 4 samples, depth 8 | 166 MB | 167 MB |
| weekend scene, 1 px/call, 8 samples, depth 16 | 27 MB | 29 MB |
| weekend scene, 1 px/call, 24 samples, depth 16 | 270 MB | 272 MB |
| three spheres, 214 px/call, 16 samples, depth 12 | 127 MB | 127 MB |

Preparing the scene costs 1.7 MB, once. Per ray bounce through the 488-sphere
world it is about 210 KB, i.e. ~440 bytes per sphere intersection test: every
intermediate 63-bit integer is a heap cell of its own. One pixel is the smallest
job there is, so a pixel that needs more than the 256 MB budget — the weekend
scene at 24 samples and depth 16 — simply gets it; the budget bounds the span,
not the pixel.

Speed, on one core of a laptop:

| | |
|---|---|
| first-light, 200x100, 4 samples, depth 8 | 0.1 s |
| weekend, 200x133, 4 samples, depth 8 | 144 s |
| weekend, 150x100, 24 samples, depth 16 | 505 s |
| three spheres, 200x133, 4 samples, depth 8 | 1.8 s |
| three spheres, 240x160, 16 samples, depth 12 | 12.6 s |

On the weekend scene that is ~700 camera rays per second, or 1.4 ms per ray
path; the three-sphere scene runs at ~49000, the cost of a ray being linear in
the number of spheres. Either way it is linear in width x height x samples, and
roughly linear in depth until the rays start being absorbed.

## What is proved

`theories/Proofs.v` proves that a job returns exactly three bytes per pixel —

```coq
Theorem render_length (sd : scene_data) (j : job) :
  List.length (render (sd, j)) = 3 * nat_of_int (job_count j).
```

— which is the invariant both drivers check at run time, along with the
two's-complement reading of the word (`to_Z_cases`, `is_neg_spec`).

The rest of the file *states* what the derived signed operations mean —
`ltb_spec`, `neg_spec`, `abs_spec`, `add_spec`, `mul_spec` as a `Z.quot`,
`div_spec`, `sqrt_spec` to within one unit in the last place — and admits them.
They are specifications, not theorems; the numbers they claim are the ones
`theories/Tests.v` checks by computation. Nothing in the renderer depends on
them: `extraction.v` does not import `Proofs.v`, so no admitted lemma reaches
the extracted code.

What the pipeline does give for free is CertiRocq's own correctness theorem: the
Wasm module is the compiled image of these definitions.

## Differences from the Lean original

- Floats become Q38.24 fixed point.
- `IO` randomness becomes an explicit SplitMix state threaded through sampling;
  a function returning `a` in Lean returns `(a, state)` here.
- Lean renders the whole image in one go, in parallel `Task`s; here a call
  renders a span of a row, and the host drives the loop (see above).
- Output is binary PPM (P6) rather than ASCII (P3).
- `vfov` reaches the camera through `Trig.tan_deg` rather than `Float.tan`.

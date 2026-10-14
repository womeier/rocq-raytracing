# A raytracer in Rocq, compiled to WebAssembly by CertiRocq

Live demo at [https://womeier.github.io/rocq-raytracing](https://womeier.github.io/rocq-raytracing).

## About

Raytracing in [Rocq](https://rocq-prover.org/) ported from [kmill/lean4-raytracer](https://github.com/kmill/lean4-raytracer) (the scene, the materials and the camera) and [TOTBWF/lean4-raytrace](https://github.com/TOTBWF/lean4-raytrace).
These are inspired by the book *Ray Tracing in One Weekend*.

The project is compiled to a single Wasm module by [CertiRocq](https://github.com/CertiCoq/certicoq).

## Running locally

```sh
nix run
```

## File Layout

| | |
|---|---|
| `theories/Fixed.v` | Q38.24 fixed point on `int63`, including decimal literals |
| `theories/Trig.v` | sine, cosine and tangent, for the camera's field of view |
| `theories/Vec3.v` | vectors and colours |
| `theories/Random.v` | SplitMix, replacing the Lean original's `IO` randomness |
| `theories/Scene.v` | rays, camera, materials, spheres, `ray_color`, and the three scenes |
| `theories/Render.v` | sampling, gamma, PPM output, jobs |
| `theories/Proofs.v` | the output-shape theorem, and the arithmetic specs |
| `theories/Tests.v` | expectations checked by conversion at build time |
| `theories/extraction.v` | the three entry points, and `CertiRocq Compile Wasm` |
| `src/` | the browser front end: renders onto a canvas, with controls |

Everything the controls set is a field of `Scene.knobs`, which `prepare` reads;
the host writes those fields as fixed-point words (`round(x * 2^24)`), so the
JavaScript never has to agree with the module about anything but the layout of
a record.


## Float representation
The CertiRocq's Wasm backend doesn't support primitive floats.
Primitive 63-bit integers are supported, so `Fixed.t` is an `int63` read as a
two's-complement signed integer scaled by 2^24: resolution 6e-8, range +-2.7e11.
See the number format [Q38.24](https://en.wikipedia.org/wiki/Q_(number_format)).

## The host interface
The module exposes three entry points in one record, so that a single Wasm module
holds everything and shares one linear memory:

```coq
api_header  : config -> list byte                 (* the PPM header *)
api_prepare : config -> scene_data                (* the world and the camera *)
api_render  : scene_data * job -> list byte       (* a span of a row *)
```

## Memory and speed

Measured on the page, which prints these numbers itself.
The weekend scene is the book's final one: 488 spheres.

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

## What is proved

`theories/Proofs.v` proves that a job returns exactly three bytes per pixel —

```coq
Theorem render_length (sd : scene_data) (j : job) :
  List.length (render (sd, j)) = 3 * nat_of_int (job_count j).
```

— which is the invariant the host checks at run time, along with the
two's-complement reading of the word (`to_Z_cases`, `is_neg_spec`).

The rest of the file *states* what the derived signed operations mean —
`ltb_spec`, `neg_spec`, `abs_spec`, `add_spec`, `mul_spec` as a `Z.quot`,
`div_spec`, `sqrt_spec` to within one unit in the last place — and admits them.
They are specifications, not theorems; the numbers they claim are the ones
`theories/Tests.v` checks by computation.

What the pipeline does give for free is CertiRocq's own correctness theorem: the
Wasm module is the compiled image of these definitions.

## Differences from the Lean original

- Floats become Q38.24 fixed point.
- `IO` randomness becomes an explicit SplitMix state threaded through sampling;
  a function returning `a` in Lean returns `(a, state)` here.
- Lean renders the whole image in one go, in parallel `Task`s; here a call
  renders a span of a row, and the host drives the loop (see above).

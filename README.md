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

## Memory
Since computing the whole image needs more than 2GB available for a Wasm module,
the image is split into `jobs` (groups of pixels, typically multiple jobs per row).
JavaScript glue code merges the pixels from each job to the final image.
The displayed linear memory usage is the maximum (across all jobs) required to compute a single job.


## What is proved
`theories/Proofs.v` proves a job returns exactly three bytes per pixel.

```coq
Theorem render_length (sd : scene_data) (j : job) :
  List.length (render (sd, j)) = 3 * nat_of_int (job_count j).
```
Further, there are a few admitted statements about the custom float.


## Differences from the Lean original
- Floats become Q38.24 fixed point.
- `IO` randomness becomes an explicit SplitMix state threaded through sampling;
  a function returning `a` in Lean returns `(a, state)` here.
- Lean renders the whole image in one go, in parallel `Task`s; here a call
  renders a span of a row, and the host drives the loop (see above).

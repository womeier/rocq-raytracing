# Raytracing in Rocq

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
| `bench/` | four examples rendered by both this project and the Lean originals, side by side in [`bench/IMAGES.md`](bench/IMAGES.md) |
| `FUTURE.md` | what it would take to close the performance gap, and what that is worth |

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

[`FUTURE.md`](FUTURE.md) collects what remains: primitive float support in the
backend, with the operation table the port would need; not boxing primitive
intermediates; and what each is estimated to be worth.


## Testing

Compiling `theories/Tests.v` is the test suite: its examples are checked by
conversion, so a build that succeeds is a build whose arithmetic, sampling and
PPM output still produce the expected values.

On top of that, `bench/` renders four examples with this project and with the
two Lean programs it was ported from, times both and compares the images
(`bench/README.md`):

```sh
make bench-setup     # clone and build the Lean originals (needs the network)
make bench           # render, time, compare -- about a minute and a half
```

| example | scene | size | spp | depth | Rocq (Wasm) | Lean, 1 core | Lean, N cores | mean diff |
|---|---|---|---|---|---|---|---|---|
| `first-light` | normal-shaded sphere | 512x256 | 1 | 1 | 0.38 s | 0.25 s | -- | 0.55 |
| `spheres-preview` | four spheres | 320x213 | 16 | 30 | 16.9 s | 4.11 s | 1.77 s (x8) | 3.17 |
| `spheres-quality` | four spheres | 200x133 | 64 | 50 | 25.6 s | 6.25 s | 2.77 s (x8) | 1.67 |
| `weekend-small` | the book's 488 spheres | 100x66 | 4 | 30 | 26.5 s | 0.53 s | 3.15 s (x4) | 31.92 |

On a Ryzen 5 PRO 7540U. The Wasm module has no threads at all, so the
comparison is with the single-core Lean run, which the patch renders inline
rather than in a task; the last column is the original's own parallelism
(`IO.asTask`, every task rendering the whole frame, averaged), with the samples
split across the tasks so the image is the same. It helps the small scene and
hurts the book's one -- the world is shared with the tasks, so every sphere a
ray sweep touches is reference-counted atomically, which `bench/RESULTS.md`
measures. The "mean diff" is the average per-channel distance out of 255
between the two images. On `first-light`, which does no sampling, no channel
anywhere is off by more than **one**: that is the check that Q38.24 fixed point
lands where the doubles do. The sampled scenes draw from different generators,
so they differ as two seeds of one scene do -- and the weekend scene *builds*
its 488 spheres from the generator, so there the two are not even the same
world. The numbers, and where the time goes, are in
[`bench/RESULTS.md`](bench/RESULTS.md).


## Differences from the Lean original
- Floats become Q38.24 fixed point.
- `IO` randomness becomes an explicit SplitMix state threaded through sampling;
  a function returning `a` in Lean returns `(a, state)` here.
- Lean renders the whole image in one go, in parallel `Task`s; here a call
  renders a span of a row, and the host drives the loop (see above).

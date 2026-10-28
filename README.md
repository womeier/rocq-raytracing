# Raytracing in Rocq

Live demo at [https://womeier.github.io/rocq-raytracing](https://womeier.github.io/rocq-raytracing).

## About

Raytracing in [Rocq](https://rocq-prover.org/) ported from [kmill/lean4-raytracer](https://github.com/kmill/lean4-raytracer) (the scene, the materials and the camera) and [TOTBWF/lean4-raytrace](https://github.com/TOTBWF/lean4-raytrace).
These are inspired by the book *Ray Tracing in One Weekend*.

The project is compiled to a single Wasm module by [CertiRocq](https://github.com/CertiCoq/certicoq), through a backend that accepts primitive floats (see below).

## Status: the float port compiles to Wasm

The renderer computes in primitive floats -- `Corelib.Floats.PrimFloat`, IEEE
754 binary64, the same arithmetic as the Lean original -- and the Wasm backend
now compiles them, so `nix build` and `nix run` produce a module from these
sources and the Pages workflow deploys it.

That support is not in a CertiRocq release yet. Against the release the last
step stops at

```
theories/extraction.v: Could not compile:
  Unsupported primitive operator: Corelib.Floats.PrimFloat.ltb
```

and what adds the eighteen PrimFloat operations and float literals the backend
was missing is the `wasm-prim-floats` branch of
[womeier/certirocq](https://github.com/womeier/certirocq). A float there is
boxed exactly as a `uint63` already was -- an 8-byte payload at an even
address, the value being that address, the payload holding the IEEE 754 bit
pattern -- so the memory layout, the invariant and the instantiation proof are
untouched, and one `setFloat64` per value is the whole host-side encoding. The
branch admits three float-only obligations; the structural parts of the
correctness proof cover the new case. `flake.nix` pins the revision, so nothing
has to be installed by hand.

[`FUTURE.md`](FUTURE.md) has the operation table that branch implements, and
what the rest of the gap to Lean is still made of.

The same `theories/` also goes through Rocq's own extraction, which is what
separates the renderer's own cost from the backend's:

```sh
make ocaml          # theories/ -> bench/ocaml/rocq-render, a native binary
make check-ocaml    # renders Tests.v's corner and checks the bytes
make bench-ocaml    # the four benchmark examples, timed
```

The two backends agree exactly: on all four benchmark examples the Wasm and the
OCaml render are the same bytes (0.00 mean and 0 max per-channel difference),
which is the check worth having on a new backend path -- it is one program
compiled twice, so anything else would be a backend bug rather than a rounding
story. See [`bench/README.md`](bench/README.md).

Replacing Q38.24 fixed point with binary64 also made the Wasm module faster,
by 1.2x on `first-light` up to 2.5x on the 488-sphere scene (26.5 s to 10.4 s);
those are two separate benchmark runs, two weeks apart, with the Lean times
within a few percent across them. `FUTURE.md` predicted ~2x there from static
operation counts.

## Running locally

```sh
nix run
```

## File Layout

| | |
|---|---|
| `theories/Flt.v` | the scalar layer: the `PrimFloat` primitives the renderer uses, `min`/`max`, and the one float-to-int conversion |
| `theories/Trig.v` | sine, cosine and tangent, for the camera's field of view |
| `theories/Vec3.v` | vectors and colours |
| `theories/Random.v` | SplitMix, replacing the Lean original's `IO` randomness |
| `theories/Scene.v` | rays, camera, materials, spheres, `ray_color`, and the three scenes |
| `theories/Render.v` | sampling, gamma, PPM output, jobs |
| `theories/Proofs.v` | the output-shape theorem, and what `Flt.v`'s own three operations mean |
| `theories/Tests.v` | expectations checked by conversion at build time |
| `theories/extraction.v` | the three entry points, and `CertiRocq Compile Wasm` |
| `theories/extraction_ocaml.v` | the same three, through Rocq's OCaml extraction, for benchmarking |
| `src/` | the browser front end: renders onto a canvas, with controls |
| `bench/` | four examples rendered by this project (both backends) and by the Lean originals, side by side in [`bench/IMAGES.md`](bench/IMAGES.md) |
| `bench/ocaml/` | the OCaml extraction: two primitive shims, a driver, a build script |
| `FUTURE.md` | what it would take to close the performance gap, and what that is worth |

Everything the controls set is a field of `Scene.knobs`, which `prepare` reads;
the host writes those fields with `setFloat64`, so the JavaScript never has to
agree with the module about anything but the layout of a record.


## Float representation
`Flt.t` is `Corelib.Floats.PrimFloat.float`: IEEE 754 binary64, the kernel's
own primitive, represented at run time as the same 8-byte heap cell as an
`int63`. `theories/Flt.v` adds only what PrimFloat lacks and the renderer
needs: `min` and `max`, and `trunc_byte`, the single place a float becomes an
integer. Everything else is the primitive itself, reached through the decimal
literals and infix operators of `float_scope`.

PrimFloat has no transcendental function, so `theories/Trig.v` still computes
the camera's `tan(vfov/2)` from a Taylor series; it now carries enough terms
to land within an ulp of `libm` on the interval it is used over.

The first port of this renderer computed in
[Q38.24](https://en.wikipedia.org/wiki/Q_(number_format)) fixed point on
`int63` instead -- resolution 6e-8, range +-2.7e11 -- because at the time the
backend had no code generation for floats. Several of the tests in `theories/Tests.v` are the equations
that port made, now landing exactly: a normalised vector is of unit length,
`sqrt 1e-4` is `0.01`, `1/1000000` is `1e-6`.

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
It also proves that `Flt.trunc_byte` -- the renderer's one float-to-int
conversion, a binary search on the eight bits of a clamped colour channel --
only ever sets those eight, so the byte it produces loses nothing, and that
`Flt.min` and `Flt.max` return one of their arguments (the property that
rules out compiling them to Wasm's `f64.min`/`f64.max`, which canonicalise
NaN).

The fourteen admitted statements the fixed-point port needed here are gone
with it. They said what each signed operation derived from the unsigned
`int63` primitives computed; the float port takes that from the kernel, where
`Stdlib.Floats.FloatAxioms` specifies `add`, `sub`, `mul`, `div`, `sqrt` and
the comparisons.

What is there instead is a set of **statements, Admitted**, of what would be
worth proving about this renderer rather than about its arithmetic -- grouped
by what each needs, with the reasoning in the comments. Three things worth
knowing from having written them down:

* `spans_compose` -- that cutting a row into jobs does not change the row --
  is the property both hosts rely on when they size a span to a memory
  budget, and it needs no float reasoning at all. `Tests.v` and
  `bench/ocaml/rocq-render --check` check one instance of it by computation.
* `Render.channel_byte` is total, and **because** of the argument order in
  `Flt.min` and `Flt.max`: a NaN channel survives the `max` and is caught by
  the `min`. Swap either branch and a NaN reaches `trunc_byte`, which is
  specified only on `[0, 256)`. NaN comes out 255, `+inf` 255, `-inf` 0.
* the obvious claim that `ray_color` returns a colour in gamut is **false**,
  twice, and the comments name both escapes -- the sky gradient's parameter
  can slip an ulp outside `[0, 1]`, and `Vec3.normalized` of the zero vector
  is `0 / 0`, which `Vec3.near_zero` does not catch. So the clamp is
  load-bearing, which is the opposite of what one sets out to prove.

The real-valued accuracy of `Trig.v`'s series is stated in Flocq's terms
(`Prim2B`, `ulp`), since Flocq is already in the dependency closure. That
group is a project rather than an afternoon, and the one `Admitted` the port
inherited -- that `trunc_byte` is the floor -- is not: it is
`Flocq.Prop.Sterbenz.sterbenz` applied to the invariant `Flt.v` already
states in prose.

[`FUTURE.md`](FUTURE.md) collects what remains, and what each part is
estimated to be worth. Its first item -- primitive floats in the backend -- is
the one now done, and its operation table is what the fork implements; the
largest of the rest is not boxing primitive intermediates.


## Testing

Compiling `theories/Tests.v` is the test suite: its examples are checked by
conversion, so a build that succeeds is a build whose arithmetic, sampling and
PPM output still produce the expected values.

`make check-ocaml` runs the same expectations through the OCaml extraction,
which is also what checks the two primitive shims in `bench/ocaml/` against
the kernel operations they stand in for: if `of_uint63` rounded differently,
or if a comparison ordered NaN rather than returning false, the corner would
come out somewhere else.

On top of that, `bench/` renders four examples with this project -- through
both backends -- and with the two Lean programs it was ported from, times them
and compares the images (`bench/README.md`). Every column below is the current
sources:

```sh
make bench-setup     # clone and build the Lean originals (needs the network)
make bench-ocaml     # the OCaml extraction against nothing but itself -- seconds
make bench           # everything that is built -- about a minute and a half
```

| example | scene | size | spp | depth | Rocq (Wasm) | Rocq (OCaml) | Lean, 1 core | Lean, N cores | mean diff |
|---|---|---|---|---|---|---|---|---|---|
| `first-light` | normal-shaded sphere | 512x256 | 1 | 1 | 0.33 s | 0.03 s | 0.24 s | -- | 0.55 |
| `spheres-preview` | four spheres | 320x213 | 16 | 30 | 9.56 s | 0.94 s | 3.95 s | 1.95 s (x8) | 3.17 |
| `spheres-quality` | four spheres | 200x133 | 64 | 50 | 15.9 s | 1.59 s | 6.40 s | 3.05 s (x8) | 1.67 |
| `weekend-small` | the book's 488 spheres | 100x66 | 4 | 30 | 10.4 s | 1.11 s | 0.55 s | 3.21 s (x4) | 31.92 |

On a Ryzen 5 PRO 7540U, node v24.21.0, 2026-10-28; both Rocq columns and the
Lean ones come from one run, so the ratios are not across runs. Neither Rocq
backend has threads, so the comparison is with the single-core Lean run, which
the patch renders inline rather than in a task; the last column is the original's own parallelism
(`IO.asTask`, every task rendering the whole frame, averaged), with the samples
split across the tasks so the image is the same. It helps the small scene and
hurts the book's one -- the world is shared with the tasks, so every sphere a
ray sweep touches is reference-counted atomically, which `bench/RESULTS.md`
measures. The "mean diff" is the average per-channel distance out of 255
between this project's image and the Lean one; it is a single column because
the Wasm and OCaml renders are identical, so both compare to Lean the same
way. On `first-light`, which does no sampling, no channel anywhere is off by
more than **one** -- and now that both sides compute in binary64, the
arithmetic is not what the remaining level is. The sampled scenes draw from
different generators, so they differ as two seeds of one scene do -- and
the weekend scene *builds* its 488 spheres from the generator, so there the two
are not even the same world. The numbers, and where the time goes, are in
[`bench/RESULTS.md`](bench/RESULTS.md).


## Differences from the Lean original
- `IO` randomness becomes an explicit SplitMix state threaded through sampling;
  a function returning `a` in Lean returns `(a, state)` here.
- Lean renders the whole image in one go, in parallel `Task`s; here a call
  renders a span of a row, and the host drives the loop (see above).

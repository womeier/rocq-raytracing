# Four examples, two implementations

This directory renders four fixed examples with the Rocq renderer (the
CertiRocq-compiled Wasm module, driven by node) and with the Lean programs
this project was ported from, times both, and compares the images.

```sh
make                 # or nix build: produces the Wasm module
bench/setup.sh       # clones and builds the two Lean originals  (make bench-setup)
node bench/run.mjs   # renders everything, writes bench/results/ (make bench)
```

The four examples together take about a minute and a half, nearly all of it
the Rocq side.

`bench/setup.sh` needs network access the first time (the clones and, through
elan, the Lean toolchain each one pins).

## The examples

| name | scene | size | samples | depth | measures |
|---|---|---|---|---|---|
| `first-light` | normal-shaded sphere | 512x256 | 1 | 1 | one primary ray per pixel: the sphere test and the colour conversion, no sampling and no bounces |
| `spheres-preview` | four spheres | 320x213 | 16 | 30 | a full image at the page's default size: the everyday case |
| `spheres-quality` | four spheres | 200x133 | 64 | 50 | deep recursion -- the glass sphere keeps rays alive longest |
| `weekend-small` | the book's 488 spheres | 100x66 | 4 | 30 | what the sphere count costs: every ray is tested against all 488 |

`first-light` is the scene the Rocq port takes from TOTBWF/lean4-raytrace, and
it is rendered at exactly that program's size and camera. The four-sphere scene
is the port's own adjustable one (`Scene.scene_knobs` at its defaults: ground,
glass, diffuse, metal), carried over to the Lean side by the patch so that the
two can be compared on something cheaper than the book's image; it costs about
a thirtieth of the weekend scene per sample, which is what keeps the suite
short. `weekend-small` is kmill/lean4-raytracer's own scene, kept small.

The examples are defined in `examples.json`, and adding one is a matter of
adding an object there -- `scene` is the renderer's own scene number (0 first
light, 1 weekend, 2 four spheres), `width`, `samples` and `depth` are the
page's controls, and `height` defaults to two thirds of the width as in both
originals.

## What is measured

Both sides report the render alone: building the scene (488 spheres, and the
random draws behind them) is timed separately, and writing the file is outside
the measurement on both sides.

The Wasm module cannot use concurrency: one linear memory, no garbage
collector, an allocator the host rewinds. So the comparison is against the Lean
renderer on one core, which at `--threads 1` renders inline -- no `IO.asTask`,
no thread pool -- and produces byte for byte the image the tasked version did.

Every example that sets `threads` in `examples.json` is then rendered a second
time with that many tasks, the samples divided among them so that the samples
per pixel, and the image, stay the same. That is the `Lean, N cores` column.
It is worth reading next to the single-core one: tasks help the four-sphere
scene and cost a factor of six on the book's, which `RESULTS.md` takes apart.

The Rocq side is driven the way the browser drives it: one `api_render` call
per span of a row, with the allocation pointer rewound between calls, since the
compiled module has no garbage collector. `calls` in `results.json` is how many
spans a render took, and `memory_mb` the high-water mark of linear memory.

The last run's numbers are in [`RESULTS.md`](RESULTS.md), and
[`IMAGES.md`](IMAGES.md) puts the renders side by side.

## What comes out

In `bench/results/` (git-ignored):

| | |
|---|---|
| `<name>.rocq.ppm` / `.png` | what the Wasm module rendered |
| `<name>.lean.ppm` / `.png` | what the Lean program rendered |
| `<name>.diff.png` | the per-channel difference, multiplied by 4 to be visible |
| `<name>.lean-mt.png` | the same, rendered with `threads` tasks |
| `results.json` | every timing, the allocation totals, the comparison statistics |
| `results.md` | the table |

The PNGs are committed; the PPMs they are made from are not. Both they and
every number here come from the Q38.24 fixed-point build: the benchmark needs
a Wasm module, and the float port cannot be compiled to one until CertiRocq's
backend accepts floats (see the repository README).

Both sides now compute in IEEE doubles -- `theories/Flt.v` is
`Corelib.Floats.PrimFloat` -- but the Rocq renderer draws from SplitMix
(`theories/Random.v`) where Lean uses `IO.stdGenRef`, so a sampled image still
cannot match. The comparison says three different things depending on the
example:

* `first-light` does no sampling, so nothing but the arithmetic separates the
  two, and they differ by at most **one level in 255** over the whole image.
  That was the check that Q38.24 fixed point landed where the doubles do;
  what is worth noticing is that the float port did not improve it. The
  residual is the order of evaluation, not the number format -- the two
  programs associate the same expressions differently and round at different
  points -- and one level out of 255 is what that costs.
* the `spheres-` examples are the same four spheres seen through the same
  camera, but sampled along different random sequences, so they differ the way
  two renders of one scene with different seeds do -- the same picture,
  different noise, which more samples drives down (3.17 mean at 16 samples,
  1.67 at 64).
* `weekend-small` is not the same world at all: the 488 small spheres are
  *drawn* from the generator, so the two implementations place and colour them
  differently. The difference there (about 32) measures nothing about the
  arithmetic; the images are two instances of the same recipe.

## The patches

The Lean programs are upstream, pinned by commit, with one small patch each,
in `bench/lean/`:

* `kmill-cli.patch` -- options for scene, size, samples, depth and thread
  count, the timing line on stdout and progress on stderr, one thread by
  default and rendering inline when there is one, the four-sphere scene of the
  Rocq port's `Scene.scene_knobs`, and `--limit N`, which keeps only the first
  N spheres (what the scaling table in `RESULTS.md` is measured with).
* `totbwf-cli.patch` -- a `lakefile.lean` (the repository predates lake and
  ships a `leanpkg.toml`), an output path, the same timing line, and a fix for
  an off-by-one in `iterate_`/`iterateRev_` that made the 512x256 render come
  out as 511x255.

## The files here

| | |
|---|---|
| `examples.json` | the four examples |
| `setup.sh` | clone, patch and build the Lean originals |
| `run.mjs` | render everything, time it, write the report |
| `rocq-render.mjs` | one render through the Wasm module (usable on its own) |
| `ppm.mjs` | PPM to PNG, and the comparison of two renders |
| `png.mjs` | a minimal PNG encoder, so that nothing has to be installed |

`rocq-render.mjs` takes the same options as the page's controls:

```sh
node bench/rocq-render.mjs --name try --scene 1 --width 160 \
     --samples 4 --depth 30 --out /tmp
```

# Results

AMD Ryzen 5 PRO 7540U (12 threads), node v24.21.0, 2026-10-15. Reproduce with
`make bench-setup && make bench` -- about two minutes.

| example | scene | size | spp | depth | Rocq (Wasm) | Lean, 1 core | Lean, N cores | Rocq / Lean | allocated | mean diff | max diff |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `first-light` | normal-shaded sphere | 512x256 | 1 | 1 | 0.38 s | 0.25 s | -- | 1.5x | 0.5 GB | 0.55 | **1** |
| `spheres-preview` | four spheres | 320x213 | 16 | 30 | 16.9 s | 4.11 s | 1.77 s (x8) | 4.1x | 20.3 GB | 3.17 | 95 |
| `spheres-quality` | four spheres | 200x133 | 64 | 50 | 25.6 s | 6.25 s | 2.77 s (x8) | 4.1x | 31.3 GB | 1.67 | 40 |
| `weekend-small` | the book's 488 spheres | 100x66 | 4 | 30 | 26.5 s | 0.53 s | 3.15 s (x4) | 50.1x | 25.2 GB | 31.92 | 223 |

The Wasm module has no threads at all -- one linear memory, no garbage
collector, an allocator the host rewinds -- so "Rocq / Lean" compares it with
the single-core Lean run. The "N cores" column is the original's own
parallelism (`IO.asTask`, every task rendering the whole frame, the results
averaged) with the samples split across the tasks, so the samples per pixel,
and the image, are the ones in the row. `first-light` has no entry: that
renderer (TOTBWF/lean4-raytrace) has no threading to turn on.

Times are the render alone: building the scene and writing the file are
excluded everywhere. "Allocated" is every byte the Wasm module asked for over
the whole render -- the allocation pointer is rewound between spans, so peak
linear memory stays at 2-250 MB.

The images are in `bench/results/` (`<name>.rocq.png`, `<name>.lean.png`,
`<name>.lean-mt.png`, and `<name>.diff.png`, the per-channel difference
multiplied by 4). [`IMAGES.md`](IMAGES.md) shows them side by side.

## What the differences mean

The two cannot agree bit for bit -- Q38.24 fixed point against IEEE doubles,
SplitMix against Lean's `stdGen` -- so the column says something different in
each row:

* `first-light` does no sampling, so both are deterministic: **no channel
  anywhere is off by more than one level in 255**. That is the check on
  `theories/Fixed.v`.
* the `spheres-` rows are the same four spheres and the same camera along
  different random sequences: the same picture, different noise, which more
  samples drives down (3.17 at 16 samples, 1.67 at 64).
* `weekend-small` is not the same world -- the 488 small spheres are *drawn*
  from the generator, so the two implementations place and colour them
  differently. The 31.92 measures nothing about the arithmetic.

## Where the time goes

The gap tracks the number of spheres, not the arithmetic: 1.5x on one sphere,
4x on four, 50x on 488. Per sample, the Wasm module allocates 20 KB in the
four-sphere scene and 1.0 MB in the weekend one -- about 2 KB per sphere per
sample, because `hit_list` walks a cons list and every intermediate `Fixed.t`
is its own heap cell, where Lean scans an `Array` with its floats unboxed. At
20 GB of bump allocation in 17 s, that traffic is the cost, more than the
fixed-point arithmetic itself: `Fixed.mul` is a widening multiply and a shift
and `Fixed.sqrt` six Newton steps each with a 128/64 division, but
`first-light` -- which does that arithmetic and nothing else -- is only 1.5x
off native.

## What the threads do

Threads help the four-sphere scene and wreck the weekend one: 8 tasks take
4.11 s down to 1.77 s, while 4 tasks take 0.53 s up to 3.15 s. The cost is in
sharing the world, and it grows with how much of it a ray sweep touches.

A *sweep* is one pass of a ray over the whole world: the `hitList` loop (Lean)
or `hit_list` fold (`theories/Scene.v`) that tests every sphere and keeps the
nearest hit. There is no acceleration structure, so each bounce of each ray
costs one -- in `weekend-small`, 26,400 rays at about three bounces each, 488
sphere tests to a sweep.

Same
100x66 image, same 4 samples per pixel in total, only the sphere count
changing (`--limit N`, which keeps the first N spheres of the scene):

| spheres | 1 core | 2 cores |
|---|---|---|
| 4 | 0.086 s | 0.073 s |
| 32 | 0.103 s | 0.118 s |
| 128 | 0.153 s | 0.496 s |
| 488 | 0.537 s | 4.613 s |

On one core the scene costs 6x more at 488 spheres than at 4; on two it costs
63x more. The counters say what is happening. Every column below is the same
100x66 image at 4 samples per pixel, the two-core ones splitting those samples
over two tasks; `perf_event_paranoid` has to be 2 or less to read them.

```sh
perf stat -e cycles:u,instructions:u,cache-references:u,cache-misses:u \
  bench/vendor/lean4-raytracer/.lake/build/bin/render \
  --scene 1 --width 100 --samples 4 --depth 30 --threads 1 --out /tmp/p.ppm
```

| | 488 spheres, inline | 488 spheres, 2 tasks | 4 spheres, inline | 4 spheres, 2 tasks |
|---|---|---|---|---|
| wall | 0.53 s | 5.04 s | 0.109 s | 0.076 s |
| cycles | 2.36 G | 45.92 G | 0.45 G | 0.59 G |
| instructions | 12.57 G | 19.38 G | 1.68 G | 1.73 G |
| instructions per cycle | 5.33 | 0.42 | 3.77 | 2.93 |
| cache references | 125 M | 1,121 M | 2.9 M | 7.5 M |
| cache misses | 75 K (0.06%) | 428 M (38%) | 45 K (1.6%) | 2.2 M (30%) |

In the 488-sphere pair the work barely grows -- half again as many
instructions, which is the atomic increments themselves and the second task's
merge -- while the cycles grow twentyfold and the core falls from retiring 5.3
instructions a cycle to 0.42. That is stalling, not computing: a world
captured by a task is shared, so every sphere the sweep touches has its
reference count written atomically, and with two cores sweeping the same 488
spheres each of those counts ping-pongs between their caches. Hence 428
million misses where one core had 75 thousand.

### Why 428 million

They are not misses in the ordinary sense: nothing here is too big for the
cache. The 488 spheres are about 30 KB of objects, and the single-core run
sweeps all of them for every ray at a miss rate of 0.06%. Pinning both tasks
to one core with `taskset -c 0` shows what the second core is actually paying
for -- the same two tasks, the same 19.37 G instructions, the same data:

| | 2 tasks, 2 cores | 2 tasks, 1 core |
|---|---|---|
| wall | 5.04 s | 1.10 s |
| cycles | 45.92 G | 4.96 G |
| instructions | 19.38 G | 19.37 G |
| cache misses | 428 M | 137 K |

Three thousand times fewer misses for identical work. So every one of those
428 million is a line the other core had taken: `lean_inc`/`lean_dec` on a
shared object is a lock-prefixed read-modify-write of the object header, which
has to hold the line exclusively, and both cores are doing that to the same
488 spheres end to end.

The count follows from the sweep. At `--depth 1` each sample does exactly one
sweep, and 26,400 samples cost 143 M misses: 5,400 per sweep, about 11 per
sphere tested -- roughly an increment and a decrement on each of the three
objects a sphere is made of (the `Hittable`, its centre `Vec3`, its
`Material`), plus the array the loop walks. Raising the depth multiplies that
by how many sweeps a ray lives for: 1.97x at depth 2, 2.63x at depth 4, 2.98x
at depth 30, which is also the measurement that the average ray bounces about
three times before it reaches the sky. Three sweeps a sample over 488 spheres
is 38 M sphere tests, and at 11 misses each that is the 428 M.

The four-sphere pair is the control, and it fails in exactly the same way
except that it does not matter: the miss *rate* climbs just as sharply, 1.6%
to 30%, because the mechanism is identical, but with four spheres to fight
over the count stays at 2.2 M against 428 M, the cycles rise by a third rather
than twentyfold, and the wall time still improves. What makes the book's scene
pathological is not the threads, it is how much shared structure each ray
touches.

The practical reading: upstream's default of ten tasks is a good deal on small
scenes and a bad one on the book's scene it ships with. A renderer that
parallelised over pixels with a per-pixel seed -- which is what the Rocq port's
`Random.seed_at` already does -- would not share the world this way.

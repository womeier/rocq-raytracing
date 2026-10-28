# Results

AMD Ryzen 5 PRO 7540U (12 threads), node v24.21.0, 2026-10-28. Reproduce with
`make bench-setup && make bench` -- about a minute and a half.

Both Rocq columns are one `theories/`, computing in primitive floats, through
two backends: CertiRocq's verified Wasm backend and Rocq's own OCaml
extraction. They render the same bytes, so one difference column covers both.

| example | scene | size | spp | depth | Rocq (Wasm) | Rocq (OCaml) | Lean, 1 core | Lean, N cores | Wasm / Lean | Wasm allocated | mean diff | max diff |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `first-light` | normal-shaded sphere | 512x256 | 1 | 1 | 0.33 s | 0.03 s | 0.24 s | -- | 1.4x | 0.6 GB | 0.55 | **1** |
| `spheres-preview` | four spheres | 320x213 | 16 | 30 | 9.56 s | 0.94 s | 3.95 s | 1.95 s (x8) | 2.4x | 17.4 GB | 3.17 | 95 |
| `spheres-quality` | four spheres | 200x133 | 64 | 50 | 15.9 s | 1.59 s | 6.40 s | 3.05 s (x8) | 2.5x | 21.9 GB | 1.67 | 40 |
| `weekend-small` | the book's 488 spheres | 100x66 | 4 | 30 | 10.4 s | 1.11 s | 0.55 s | 3.21 s (x4) | 19.0x | 15.9 GB | 31.92 | 223 |

The Wasm-against-OCaml difference is **0.00 mean, 0 max** on all four: one
program compiled twice, so anything else would be a backend bug rather than a
rounding story.

### Against the fixed-point build it replaced

The same four examples on the same machine, 2026-10-15, when `theories/`
computed in Q38.24 fixed point on `int63` and that was what the Wasm backend
would take:

| example | Rocq (Wasm), Q38.24 | now | allocated, then | now |
|---|---|---|---|---|
| `first-light` | 0.38 s | 0.33 s | 0.5 GB | 0.6 GB |
| `spheres-preview` | 16.9 s | 9.56 s | 20.3 GB | 17.4 GB |
| `spheres-quality` | 25.6 s | 15.9 s | 31.3 GB | 21.9 GB |
| `weekend-small` | 26.5 s | 10.4 s | 25.2 GB | 15.9 GB |

1.2x to 2.5x, against the ~2x on the 488-sphere scene that
[`FUTURE.md`](../FUTURE.md) predicted from static operation counts. The Lean
times moved by a few percent between the two runs, so the comparison is
across runs but not across machines.

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

## What the second backend says

The OCaml column is `theories/` through Rocq's own extraction
(`bench/ocaml/`) -- the same `Fixpoint`s, the same unary `nat` counters, the
same cons-list output as the Wasm module, with a mature backend and a
generational GC under it. Its allocation figures: 0.4, 14.0, 21.6 and 17.1 GB,
against a top heap of 1.0-1.5 MB throughout, which the GC recycles and the
Wasm allocator can only rewind.

Three things come out of having both that neither column says alone.

Three things come out of this that the Wasm column could not say.

**The renderer is not the slow part.** Extracted to OCaml it is four to
six times *faster* than the single-core Lean original on three of the four
examples, and faster than Lean's eight-task run on both sphere scenes
(0.94 s against 1.95 s, 1.59 s against 3.05 s). So the 2.4x and 2.5x in the
table above are the Wasm backend's cost, not the algorithm's: the same source
through a conventional compiler wins, by a factor of 10 here -- that ratio,
Wasm over OCaml, is the cleanest measure of the calling convention, the boxing
and the allocation traffic, since everything else about the two is the same.

**`weekend-small` is the exception, and it is the sphere list.** 488
spheres, every ray tested against all of them, and `Scene.hit_list` folds
a cons list where the Lean original indexes an array. At four samples the
2.0x the OCaml backend still gives up there is almost entirely that traversal; it is the one place where the data
structure, rather than the backend, is what costs. `Proofs.v`'s
`hit_list_app` is the statement that would let a bounding structure be
slotted in without changing what `hit_list` means.

**The float port did not close the `first-light` gap, and that is
informative.** That example does no sampling, so nothing but the
arithmetic separates the two programs -- and the difference is still at
most one level in 255, exactly what Q38.24 fixed point gave. Both sides
now compute in binary64, so the residual is the order of evaluation: the
two associate the same expressions differently and round at different
points. One level out of 255 is what that costs, and no change of number
format will remove it.

## What the differences mean

The two cannot agree bit for bit -- SplitMix against Lean's `stdGen`, and the
same binary64 expressions associated differently -- so the column says
something different in each row:

* `first-light` does no sampling, so both are deterministic: **no channel
  anywhere is off by more than one level in 255**. That is the check on
  `theories/Flt.v`, and on both backends: the Wasm and OCaml renders of it are
  the same bytes.
* the `spheres-` rows are the same four spheres and the same camera along
  different random sequences: the same picture, different noise, which more
  samples drives down (3.17 at 16 samples, 1.67 at 64).
* `weekend-small` is not the same world -- the 488 small spheres are *drawn*
  from the generator, so the two implementations place and colour them
  differently. The 31.92 measures nothing about the arithmetic.

## Where the time goes

The gap tracks the number of spheres, not the arithmetic: 1.4x on one sphere,
2.4x on four, 19x on 488. Per sample, the Wasm module allocates 17 KB in the
four-sphere scene and 0.65 MB in the weekend one -- about 1.3 KB per sphere
per sample, because `hit_list` walks a cons list and every intermediate
`Flt.t` is its own heap cell, where Lean scans an `Array` with its floats
unboxed. At 17 GB of bump allocation in 9.6 s, that traffic is the cost, and
now plainly more than the arithmetic: going from Q38.24 to single hardware
instructions took the 488-sphere scene 2.5x faster while `first-light` --
which does that arithmetic and nothing else -- barely moved, because it was
already only 1.4x off native. The remaining order of magnitude is the boxing,
not the operations ([`FUTURE.md`](../FUTURE.md) item 2).

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

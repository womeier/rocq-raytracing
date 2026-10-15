# Future work

What it would take to close the performance gap, and what each part is worth.
Measurements: [`bench/RESULTS.md`](bench/RESULTS.md). Attempt these in the
order of the summary table at the end.

## The one fact everything follows from

The renderer spends a near-constant **0.8 us per KB it allocates**, over a
260-fold range of per-sample cost. Its time *is* its allocation volume: ~700 B
per sphere test, 25.2 GB over one 100x66 image, against a live scene of
1.2 MB. Hence the gap tracks sphere count, not arithmetic -- 1.5x on one
sphere, 4.1x on four, 50x on 488. Every `Fixed.t` intermediate is an 8-byte
heap cell, a `vec3` a block plus three, and nothing is freed inside a call.

## 1. Primitive floats in the backend

Today the backend stops at

```coq
| AstCommon.primFloat => Err "Extraction of floats to Wasm not yet supported"
    (* LambdaANF_to_Wasm.v:238 *)
```

which is why `theories/Fixed.v` exists. What follows is what the backend would
have to accept for the port that drops `Fixed.v` for
`Corelib.Floats.PrimFloat`, leaving `Vec3`/`Trig`/`Scene`/`Render`/`Random`
otherwise unchanged. Taken from the call sites, not the interface: of
PrimFloat's 19 primitives 11 are reached, 2 more are free, 6 are not needed.
Wasm constructor names are WasmCert's, since that is what the backend emits.

**Required.**

| PrimFloat | kernel tag | Wasm | sites |
|---|---|---|---|
| `add` | `#float64_add` | `BOF_add` | many |
| `sub` | `#float64_sub` | `BOF_sub` | many |
| `mul` | `#float64_mul` | `BOF_mul` | many |
| `div` | `#float64_div` | `BOF_div` | many |
| `opp` | `#float64_opp` | `UOF_neg` | many |
| `abs` | `#float64_abs` | `UOF_abs` | 2 |
| `sqrt` | `#float64_sqrt` | `UOF_sqrt` | 5 |
| `ltb` | `#float64_lt` | `ROF_lt` | 16 |
| `of_uint63` | `#float64_of_uint63` | `CVO_convert` (i64_u) | 12 |
| float constants | `AstCommon.primFloat` | `f64.const` | many |

`add`/`sub`/`mul`/`div`/`opp` arrive through the infix notations of
`fixed_scope`, so their count is every arithmetic line in `theories/`: Vec3's
operations, Trig's two Taylor series, Scene's discriminant and scatter,
Render's accumulation. `abs` is `Vec3.v:62` (refract) and `Trig.v:41`
(`tan_deg`); `sqrt` is `Vec3.v:44`, `Vec3.v:62`, `Scene.v:119`, `Scene.v:153`,
`Render.v:100`; `ltb` is every hit test and clamp, the rejection sampling of
`Random.v:61,74`, the scene choices of `Scene.v:201,205`, `Vec3.near_zero` and
`Fixed.min`/`max`; `of_uint63` is `Render.v:132,133,135,140,141,155` (pixel
coordinates, width/height, sample count, aspect) and `Random.unit_fx`, which
turns the generator word into a float in [0,1). Every literal of the port is a
constant: Trig's coefficients, Scene's geometry and colours, Render's `256`
and `0.999999`, `near_zero`'s epsilon. `PrimFloat.infinity`, `.nan`, `.one`,
`.zero`, `.two` are `Eval compute in` definitions, so they also arrive as
constants rather than calls -- which is how the `Fixed.max_val` sentinel of
`Scene.v:184,302` would be written.

**Required for the one float-to-int conversion.** `Render.v:101` is the only
place a float becomes an integer:

```coq
byte_of_int (Fixed.floor_to_int (256 * clamp s))
```

PrimFloat has no float-to-int primitive -- `of_uint63` goes one way only -- so
truncation must be built from `frshiftexp` (`#float64_frshiftexp`, the
[0.5,1) mantissa and the exponent) and `normfr_mantissa`
(`#float64_normfr_mantissa`, that mantissa as a 53-bit int63), then an int63
shift. The gap is on the Rocq side, not the Wasm one:
`i64.trunc_sat_f64_s` (`CVO_trunc_sat`) would do it in one instruction if
there were a primitive to compile from. The alternative needs neither: the
value is in [0,256), so eight `ltb` comparisons pick the byte by binary
search -- ugly, but it keeps the required set to the table above.

**Free, one instruction each, not currently reached.** `leb`
(`#float64_le`, `ROF_le`) and `eqb` (`#float64_eq`, `ROF_eq`). `Fixed.leb` is
used only inside `Fixed.sqrt`, which the primitive replaces, and the renderer
compares with uint63 `eqb`, never a float one. Both are worth having: any
clamp written with `<=?` needs `leb`, and `eqb` is what `is_nan`, `is_zero`,
`is_infinity` and `get_sign` are *defined* from, so supporting it supports all
four.

**Not needed.** `compare` (`#float64_compare`, three-way; `ltb` and `leb`
cover every comparison here), `classify` (`#float64_classify`, only
`FloatClass` users), `Leibniz.eqb` (`#float64_equal`, not reached),
`ldshiftexp` (`#float64_ldshiftexp`; `Random.unit_fx` can scale by a constant
instead), `next_up` (`#float64_next_up`) and `next_down`
(`#float64_next_down`), neither reached.

**Work beyond the operation table.**

1. **Constants need a wider result type.** `translate_primitive_value`
   (`LambdaANF_to_Wasm.v:235`) returns `error Wasm_int.Int64.int`, so the
   `primFloat` case has nowhere to put an f64; the signature must carry a
   `value_num`, or the bit pattern plus its type. This is the one change that
   is not just a new case.
2. **The operations go in the existing table**, the `primop` inductive and
   `primop_map` of `LambdaANF_to_Wasm_primints.v:48,74`, keyed by kername. The module path is
   `MPfile ["PrimFloat"; "Floats"; "Corelib"]`, mirroring `primInt63ModPath`;
   every primitive above sits at that module's root (only `Leibniz.eqb` is
   nested, and it is not needed).
3. **Representation** is the same 8-byte heap cell as int63, so
   `apply_binop_and_store_i64` (`primints.v:113`) carries over with `T_f64`
   and, unlike int63, no bitmask -- a float uses all 64 bits, there is no
   63-bit MSB to clear. Both hosts get simpler: `src/index.js:81`'s
   `round(x * 2^24)` with a two's-complement fixup becomes a `setFloat64`.
4. **NaN payloads are the sharp edge of the proof.** Rocq's model has a single
   NaN (`Prim2SF f = S754_nan`); Wasm arithmetic may produce one with an
   arbitrary payload. That is invisible to every operation above except
   `frshiftexp` and `normfr_mantissa`, whose natural implementation
   reinterprets the bits -- so those two must branch on the
   nan/infinity/zero/subnormal cases per their specifications rather than mask
   bits blindly. `is_nan` is `negb (f =? f)`, correct for any payload.
5. **Do not map `Fixed.min`/`max` onto `BOF_min`/`BOF_max`.** Wasm's `f64.min`
   and `f64.max` return a canonical NaN when either argument is NaN and have
   their own rule for +-0; `Fixed.min`/`max` are `if ltb`, and the port should
   keep them that way -- `ROF_lt` and a select.
6. **Rounding needs no work.** Wasm f64 arithmetic is IEEE 754 binary64,
   round-to-nearest-ties-to-even, with no rounding-mode flag, which is exactly
   what `FloatAxioms` specifies. `f64.sqrt` is correctly rounded and
   `f64.convert_i64_u` rounds the same way, so `add`, `sub`, `mul`, `div`,
   `sqrt` and `of_uint63` are sound one-to-one mappings.
7. **The correctness proofs are the bulk of it**: the float cases need the
   treatment `primints_correct.v` (5,209 lines) gives the int63 ones, against
   `FloatAxioms` rather than `Uint63Axioms`.

**What this is worth.** Comparisons allocate nothing (booleans are i32
immediates, `primints.v:191`); every arithmetic operation and every shift
stores an 8-byte cell and bumps `mem_ptr` (`primints.v:113,240`). So the
allocation count is the primitive-operation count, and both can be read off
`Fixed.v`:

| | today | with floats | |
|---|---|---|---|
| `add`, `sub` | 1 op | 1 | unchanged |
| `mul` | ~4 ops | 1 | two abs, mul, shift, sign |
| `div` | ~4 ops | 1 | two abs, shift, div, sign |
| `sqrt` | ~29 ops | 1 | head0, setup, 6 Newton steps |
| `ltb`, `min`, `max` | 3 compares | 1 | no allocation either way |

The hot path is the miss branch of `hit` (`Scene.v:147-153`): 488 spheres per
bounce, almost all missing, and `ltb discr 0` returns before the square root
is reached. Per sphere test that is 3 sub, 9 mul, 4 add, 2 sub -- about 45
operations and 360 bytes today, plus three vec3 blocks, so ~408 B; with floats
the same shape is 18 operations and ~192 B. **2.5x fewer instructions, 2.1x
less memory.**

That agrees with measurement. The host reports the most any single call
allocated, so the soundest figure is a forced full-row call, averaging a whole
row of real pixels: at 48 wide, 4 samples, depth 8, that peaked at 255.46 MB,
i.e. 5.32 MB per pixel. Against 408 B per sphere test and 488 spheres that is
7.0 bounces per sample with the depth limit at 8 -- rays in this scene seldom
escape before the limit, which is also why the worst single pixel at depth 16
comes out around 9.

So the win is the multiply, four to one, ~4,400 times per bounce. Not the
square root: its 29-to-1 is the largest ratio here but it is under 1% of the
work, since the sphere loop never calls it and only `normalized`, `refract`,
`sin_theta` and the hit path do.

**What it would not fix.** A value is still a heap cell, every vec3 still a
four-word block, nothing is freed inside a call (the span logic of
`src/index.js:222-232`), and the eight instructions of `mem_ptr` juggling that
wrap every operation stay. Floats are a factor of two; the remaining order of
magnitude is item 2, or a collector.

## 2. Not boxing intermediates -- as a pass after `LambdaANF_to_Wasm`

Within one primitive the backend is already unboxed (i64 on the stack and in
`glob_tmp1..4`); what is boxed is the seam between operations. The emitted
idiom is uniform (`primints.v:113`) and every *use* of a primitive is already
`local.get x; i64.load offset=0`:

```wat
global.get $mem_ptr                      ;; before: the store address
local.get $y i64.load  local.get $z i64.load  i64.binop
i64.store  global.get $mem_ptr  ;; + bump 8
local.set $x                             ;; x : i32, a pointer

local.get $y'  local.get $z'  i64.binop  local.set $x'   ;; after: x' : i64
```

Done as a `module -> module` pass at `Compiler/pipeline.v:184`
(`binary_of_module (unbox p)`), its theorem is Wasm-to-Wasm -- *every
behaviour of `m` is a behaviour of `unbox m`* -- and composes with
`LambdaANF_Wasm_related` (`toplevel_theorem.v:37`) by transitivity. **No
existing proof is edited**: `repr_val_LambdaANF_Wasm` and its 122 references
do not move, `wasm_value` gains no case, `INV_locals_all_i32` stands. The
in-translation version instead threads a new invariant through 129 lemmas of
`correct.v`. Also:

* The analysis is a syntactic def-use scan of one function body -- Wasm
  locals cannot be aliased. A local is unboxable when every def is the idiom
  and every use is the load; passed to a call, stored in a constructor field
  or written to `glob_result` are escapes. No interprocedural information, no
  change to the calling convention.
* Append fresh i64 locals, never renumber. Then typing is perturbed only at
  the matched fragments, and each is stack-effect-neutral. The emitted code
  already has i64 block results (`BI_if (BT_valtype (Some (T_num T_i64)))`).
* Allocating less needs no restatement: `result_val_LambdaANF_Wasm`
  (`correct.v:979`) is already "correct *or* `glob_out_of_mem` is set", and
  fewer allocations can only turn the second disjunct into the first.
* Keep the site search in unverified OCaml; verify only a checker that the
  given sites match the idiom. The pass fails closed -- an unmatched pattern
  leaves the code alone, so brittleness costs speed, never correctness.
* `wasm-opt -O3` cannot do this: it cannot prove the freshly bumped address
  is unaliased. That `glob_mem_ptr` only moves forward is the backend-specific
  fact that makes the pass sound.

The cost: it is a new *kind* of proof here -- every existing proof relates
LambdaANF to Wasm, none relates Wasm to Wasm -- so no template to copy, and
the WasmCert reduction machinery has to be driven directly. 3-6 months, with
the leverage in one fragment-replacement lemma via `r_label`.

**Worth ~2-2.5x**, and it does **not** multiply with floats: only the returned
cell of each `Fixed.mul` escapes, so the pass also takes 45 cells to 18 --
the same intermediates floats remove by a different route. Together ~3-4x.

**Cheapest lever in this document:** since a returned value always escapes,
the win is bounded by how much arithmetic the inliner put in one body. So
inline `Fixed` and `Vec3` harder -- no proof cost, the inliner is already
verified -- which grows the window from inside one multiply to a whole dot
product. Aggressive inlining plus the *unverified* pass is a two-day
experiment that bounds the whole design space.

## 3. Wider object words -- not recommended

64-bit object words would make `int63` a tagged immediate (63 bits plus one
tag, exactly), cutting allocation 7-10x with no analysis. But they double
every block for every program, including symbolic ones with nothing to unbox,
and halve the effective heap inside Wasm's 32-bit address space. Item 2 buys
the same thing locally and costs other programs nothing.

## 4. An array world

`hit_list` folds a cons list: 488 pointer chases a sweep where an array scan
would be contiguous. 1.1-1.2x today, relatively more once allocation is gone.

## 5. Parallelism

`api_render` is pure and `Random.seed_at` makes a pixel depend only on
`(seed, x, y)`, so N module instances in Web Workers, each with its own linear
memory and a slice of the image, share nothing. Contrast the Lean original,
which parallelises over samples because it has a GC: handing its world to
tasks makes the book's scene **6x slower**, measured, because every sphere a
sweep touches is then reference-counted atomically.

## 6. Proofs

`render_length` is proved. The 15 arithmetic specs in `theories/Proofs.v`
are `Admitted`; `theories/Tests.v` pins them at concrete values by
conversion, and `first-light` agreeing with the float original to within one
level in 255 is the empirical check. Item 1 would delete most of `Fixed.v`
and most of those admits.

## Summary

| change | speedup, 488-sphere scene | memory | effort | confidence |
|---|---|---|---|---|
| inline `Fixed`/`Vec3` harder | small alone | small | a pipeline flag, no proof | low, but free to measure |
| unboxing pass, unverified | ~2-2.5x | ~2.5x less | days | medium |
| the same pass, verified | as above | as above | 3-6 months, one new lemma | medium |
| primitive floats | ~2x | ~2.1x less | large, mostly proofs | high -- static count and measurement agree |
| floats *and* unboxing | ~3-4x | ~4x less | the sum of the two | low-medium |
| unboxed across calls | 6-10x | ~7-10x less | +4-7 months, new calling convention | low |
| wider object words | 5-8x | better here, worse elsewhere | large | medium, not recommended |
| array world | 1.1-1.2x | none | small | medium |
| workers | near-linear in cores | N instances | small, host-side only | high |

Floats and unboxing do not multiply -- they delete the same intermediates.
Every row stops being reliable past ~4-5x from here, where allocation stops
being the bottleneck and the 1.5x `first-light` already shows for pure
arithmetic becomes the floor. The figures are the 0.8 us/KB law plus static
counting, which accounts for 150-400 B of the measured ~700 B per sphere
test -- the rest is closure and calling-convention overhead none of these
touch -- so treat them as +-2x. To sharpen: instrument `glob_mem_ptr` around
a single `hit` call; the ratio of scalar cells to structural blocks decides
the unboxing win directly.

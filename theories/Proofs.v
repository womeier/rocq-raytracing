(*****************************************************************************)
(*  What is proved about the renderer, and what is only stated               *)
(*                                                                           *)
(*  Proved (no float reasoning needed):                                      *)
(*                                                                           *)
(*   - the shape of the output: a job returns exactly three bytes per        *)
(*     pixel, which is the invariant the host checks at run time;            *)
(*   - that [Flt.trunc_byte] lands in [0, 256), so the byte it is turned     *)
(*     into drops nothing;                                                   *)
(*   - that [Flt.min] and [Flt.max] return one of their arguments.           *)
(*                                                                           *)
(*  Stated and Admitted: everything else below.  They are written down       *)
(*  here because a statement is most of the work -- several of the           *)
(*  plausible ones turn out to be false, and the comments say which and      *)
(*  why.  Three groups, by what they need:                                   *)
(*                                                                           *)
(*   - int63, list and nat facts only.  [spans_compose] is the one the       *)
(*     hosts actually depend on; nothing in this group touches a float.      *)
(*   - the IEEE semantics of the primitives, through                         *)
(*     [Stdlib.Floats.FloatAxioms] or Flocq's [Prim2B] bridge.  Mostly       *)
(*     about totality: which operations can produce a NaN, and what the      *)
(*     renderer then does with it.                                           *)
(*   - the real-valued accuracy of the series in [Trig.v], which needs       *)
(*     Flocq and [Reals].  This is the only group that is a project          *)
(*     rather than an afternoon.                                             *)
(*                                                                           *)
(*  The fixed-point port had fourteen admitted statements here for a         *)
(*  different reason: it built every signed operation out of the unsigned    *)
(*  int63 primitives and had to say what each one computed.  The float       *)
(*  port inherits all of that from the kernel -- FloatAxioms specifies       *)
(*  add, sub, mul, div, sqrt and the comparisons -- so what is left is       *)
(*  about this renderer rather than about its arithmetic.                    *)
(*****************************************************************************)

From Stdlib Require Import ZArith Uint63 List Lia Permutation Strings.Byte.
From Raytracing Require Import Flt Trig Vec3 Random Scene Render.

Import ListNotations.
Open Scope Z_scope.

(** ** The output has three bytes per pixel *)

Lemma color_bytes_length (g : bool) (c : color) :
  List.length (Render.color_bytes g c) = 3%nat.
Proof. reflexivity. Qed.

Lemma span_loop_length (f : int -> list Byte.byte) (n : nat) :
  (forall z, List.length (f z) = 3%nat) ->
  forall x, List.length (Render.span_loop n f x) = (3 * n)%nat.
Proof.
  intros Hf; induction n as [|n IH]; intros x; [reflexivity|].
  simpl; rewrite length_app, Hf, IH; lia.
Qed.

Lemma pixel_trace_length (cfg : config) (w : list hittable) (x y : int) :
  List.length (Render.pixel_trace cfg w x y) = 3%nat.
Proof. reflexivity. Qed.

Lemma pixel_weekend_length (cfg : config) (w : list hittable) (cam : camera)
                           (x y : int) :
  List.length (Render.pixel_weekend cfg w cam x y) = 3%nat.
Proof.
  unfold Render.pixel_weekend.
  destruct (Render.sample_loop _ _ _ _ _ _ _ _ _ _); reflexivity.
Qed.

Theorem render_length (sd : scene_data) (j : job) :
  List.length (Render.render (sd, j)) = (3 * Render.nat_of_int (Render.job_count j))%nat.
Proof.
  unfold Render.render.
  destruct (Uint63.eqb _ _); apply span_loop_length; intros z;
    [apply pixel_trace_length | apply pixel_weekend_length].
Qed.

(** ** Cutting a row into jobs does not change the row

    The property both drivers rely on, and the reason they may size a span
    to whatever memory budget they have: [src/index.js] rewinds the
    allocation pointer between calls, so a row has to come out the same
    however it was split.  It does, because [Render.pixel_weekend] draws
    its stream from [Random.seed_at (cfg_seed cfg) x y] and so depends on
    the pixel alone, not on the job that asked for it.

    [Tests.v:197] checks one instance of this by computation.  The general
    statement needs no float reasoning at all: it is induction on
    [span_loop], and the side condition is only that the two counts fit
    the fuel of [Render.nat_of_int] (4096, [Render.max_count]) and do not
    wrap. *)

Lemma nat_of_int_add (n m : int) :
  to_Z n + to_Z m < Z.of_nat Render.max_count ->
  Render.nat_of_int (n + m) = (Render.nat_of_int n + Render.nat_of_int m)%nat.
Admitted.

Lemma span_loop_add (f : int -> list Byte.byte) (n m : nat) (x : int) :
  to_Z x + Z.of_nat n < wB ->
  Render.span_loop (n + m) f x
  = Render.span_loop n f x ++ Render.span_loop m f (x + Uint63.of_Z (Z.of_nat n)).
Admitted.

Theorem spans_compose (sd : scene_data) (cfg : config) (y x0 n m : int) :
  to_Z n + to_Z m < Z.of_nat Render.max_count ->
  to_Z x0 + to_Z n < wB ->
  Render.render (sd, Render.MkJob cfg y x0 (n + m))
  = Render.render (sd, Render.MkJob cfg y x0 n)
    ++ Render.render (sd, Render.MkJob cfg y (x0 + n) m).
Admitted.

(** ** The header

    "P6\n<width> <height>\n255\n".  [Render.digits] is the only part with
    any content: the fuel is 24, which is more decimal places than int63
    has, so it never truncates.  Rather than write a parser, read the
    digits back as a number. *)

Definition digit_value (b : Byte.byte) : Z := Z.of_N (Byte.to_N b) - 48.

Definition decimal_value (ds : list Byte.byte) : Z :=
  List.fold_left (fun acc b => 10 * acc + digit_value b) ds 0.

Lemma digits_roundtrip (n : int) : decimal_value (Render.digits n) = to_Z n.
Admitted.

(** Each of them really is a digit, so the header cannot be misread: the
    only separators in it are the space and the newline that
    [Render.ppm_header] puts there. *)
Lemma digits_are_digits (n : int) (b : Byte.byte) :
  List.In b (Render.digits n) -> 0 <= digit_value b < 10.
Admitted.

Lemma digits_nonempty (n : int) : Render.digits n <> [].
Admitted.

(** ** Bytes

    [Render.byte_of_int] takes the bottom eight bits.  Together with
    [trunc_byte_is_a_byte] below, this is what says nothing is lost
    between the clamp in [Render.channel_byte] and the byte it writes. *)

Lemma byte_of_int_spec (n : int) :
  Z.of_N (Byte.to_N (Render.byte_of_int n)) = to_Z n mod 256.
Admitted.

(** ** Minimum and maximum

    The property that separates these from Wasm's [f64.min] and [f64.max],
    which the port must not be compiled to: they return one of their two
    arguments, and so cannot turn a pair of numbers into a NaN or settle a
    tie between [+0] and [-0] by a rule of their own. *)

Lemma min_is_arg (x y : Flt.t) : Flt.min x y = x \/ Flt.min x y = y.
Proof. unfold Flt.min; destruct (Flt.ltb x y); auto. Qed.

Lemma max_is_arg (x y : Flt.t) : Flt.max x y = x \/ Flt.max x y = y.
Proof. unfold Flt.max; destruct (Flt.ltb x y); auto. Qed.

(** And that on numbers they are the minimum and the maximum.  The
    hypotheses are how "not a NaN" is spelled with the primitives: [leb]
    is false whenever either side is a NaN, so [leb x x = true] says
    exactly that [x] is a number.  Both lemmas are false without them --
    [Flt.min nan y = y], and [Flt.leb y nan] is false. *)

Lemma min_is_least (x y : Flt.t) :
  Flt.leb x x = true -> Flt.leb y y = true ->
  Flt.leb (Flt.min x y) x = true /\ Flt.leb (Flt.min x y) y = true.
Admitted.

Lemma max_is_greatest (x y : Flt.t) :
  Flt.leb x x = true -> Flt.leb y y = true ->
  Flt.leb x (Flt.max x y) = true /\ Flt.leb y (Flt.max x y) = true.
Admitted.

(** ** The float-to-int conversion

    [Flt.trunc_byte] is a binary search on the eight bits of a value known
    to lie in [0, 256) (Flt.v).  Two things are wanted of it: that the
    result is a byte, so that [Render.byte_of_int] drops nothing; and that
    it is the floor. *)

(** Only the bottom eight bits are ever set, whatever the float is: the
    search ORs in [k], which starts at 128 and halves. *)

Lemma lor_below (a b : int) :
  Uint63.to_Z a < 256 -> Uint63.to_Z b < 256 ->
  Uint63.to_Z (Uint63.lor a b) < 256.
Proof.
  intros Ha Hb.
  assert (Aa := Uint63.to_Z_bounded a); assert (Ab := Uint63.to_Z_bounded b).
  rewrite Uint63.lor_spec'.
  assert (H : Z.lor (Uint63.to_Z a) (Uint63.to_Z b) / 2 ^ 8 = 0).
  { rewrite <- Z.shiftr_div_pow2 by lia.
    rewrite Z.shiftr_lor, !Z.shiftr_div_pow2 by lia.
    rewrite (Z.div_small (Uint63.to_Z a)), (Z.div_small (Uint63.to_Z b)) by lia.
    reflexivity. }
  apply Z.div_small_iff in H; [|lia].
  change (2 ^ 8) with 256 in H.
  assert (0 <= Z.lor (Uint63.to_Z a) (Uint63.to_Z b)) by (apply Z.lor_nonneg; lia).
  lia.
Qed.

Lemma peel_below (n : nat) : forall p k r acc,
  Uint63.to_Z k < 256 -> Uint63.to_Z acc < 256 ->
  Uint63.to_Z (Flt.peel n p k r acc) < 256.
Proof.
  induction n as [|n IH]; intros p k r acc Hk Hacc; [exact Hacc|].
  assert (Hk' : Uint63.to_Z (Uint63.lsr k 1) < 256).
  { rewrite Uint63.lsr_spec, Uint63.to_Z_1, Z.pow_1_r.
    assert (A := Uint63.to_Z_bounded k).
    apply Z.div_lt_upper_bound; lia. }
  simpl; destruct (Flt.ltb r p); apply IH; auto using lor_below.
Qed.

Theorem trunc_byte_is_a_byte (x : Flt.t) : Uint63.to_Z (Flt.trunc_byte x) < 256.
Proof. apply peel_below; reflexivity. Qed.

(** And it is the floor, on the range it is built for: the eight
    subtractions are exact (Flt.v), so what comes out is the integer part
    and what is left in the residual is the fraction.

    The route is Flocq, which is already in the dependency closure:
    [Flocq.IEEE754.PrimFloat.sub_equiv] and [ltb_equiv] down to
    [BinarySingleNaN], then [Bminus_correct], then
    [Flocq.Prop.Sterbenz.sterbenz] -- whose statement is literally
    [y / 2 <= x <= 2 * y -> format (x - y)], which is the invariant
    [Flt.v] states in prose.  The loop invariant to carry through [peel]
    is that [r] is exactly [x] minus what [acc] has accumulated, and that
    [0 <= r < 2 * p]. *)

Lemma trunc_byte_spec (x : Flt.t) :
  Flt.leb 0 x = true -> Flt.ltb x 256 = true ->
  Flt.leb (Flt.of_int (Flt.trunc_byte x)) x = true
  /\ Flt.ltb x (Flt.add (Flt.of_int (Flt.trunc_byte x)) 1) = true.
Admitted.

(** ** The clamp is load-bearing

    [Render.channel_byte] is total, and not by accident: it is total
    because of the argument order in [Flt.min] and [Flt.max].  A NaN
    channel survives the [max] -- [Flt.ltb nan 0] is false, so
    [Flt.max nan 0] returns its first argument, the NaN -- and is then
    caught by the [min], because [Flt.ltb nan 0.999999] is also false and
    [Flt.min] returns its second.  Swap either branch and a NaN reaches
    [Flt.trunc_byte], which is specified only on [0, 256).

    So this lemma holds for every input, with no hypothesis at all, and it
    is the one that makes [trunc_byte_spec]'s hypotheses dischargeable at
    the call site. *)

Lemma clamp_in_range (s : Flt.t) :
  Flt.leb 0 (Flt.min (Flt.max s 0) 0.999999) = true
  /\ Flt.ltb (Flt.min (Flt.max s 0) 0.999999) 1 = true.
Admitted.

(** What the clamp does to the three values the renderer can actually
    manufacture.  These are computed, not assumed: [Flt.sqrt (-1)] is the
    witness, and the table is nan -> 255, +inf -> 255, -inf -> 0. *)

Lemma channel_byte_nan (g : bool) (v : Flt.t) :
  Flt.eqb v v = false -> Render.channel_byte g v = "255"%byte.
Admitted.

Lemma channel_byte_neg (v : Flt.t) :
  Flt.ltb v 0 = true -> Render.channel_byte false v = "000"%byte.
Admitted.

(** A negative channel through the gamma path is a NaN, not a zero, since
    [Flt.sqrt] of a negative is a NaN -- so it comes out white.  Worth
    deciding whether that is wanted before it is proved. *)

Lemma channel_byte_neg_gamma (v : Flt.t) :
  Flt.ltb v 0 = true -> Render.channel_byte true v = "255"%byte.
Admitted.

(** And the end-to-end statement: the byte is the floor of the scaled
    clamp, with nothing lost in [Render.byte_of_int]. *)

Theorem channel_byte_is_floor (g : bool) (v : Flt.t) :
  let s := if g then Flt.sqrt v else v in
  Z.of_N (Byte.to_N (Render.channel_byte g v))
  = to_Z (Flt.trunc_byte (256 * Flt.min (Flt.max s 0) 0.999999)).
Admitted.

(** ** Vectors

    [Vec3.length_squared] is a sum of three squares with no subtraction
    anywhere, so it cannot be negative and cannot be an [inf - inf].  It
    can still be a NaN, if a component is one; the [ltb] form below is
    true even then, since [ltb] is false whenever either side is a NaN.
    That is what makes [Vec3.length] safe to call unguarded. *)

Lemma length_squared_not_negative (v : vec3) :
  Flt.ltb (Vec3.length_squared v) 0 = false.
Admitted.

Lemma length_squared_nonneg (v : vec3) :
  Flt.leb (vx v) (vx v) = true -> Flt.leb (vy v) (vy v) = true ->
  Flt.leb (vz v) (vz v) = true ->
  Flt.leb 0 (Vec3.length_squared v) = true.
Admitted.

(** [Vec3.normalized] divides by [Vec3.length], so it is a NaN exactly
    when the length is zero: [0 / 0].  This is not hypothetical -- see the
    note on [ray_color] below -- and it is the one place in the renderer
    where a NaN is manufactured from finite inputs. *)

Lemma normalized_of_zero : Flt.eqb (vx (Vec3.normalized Vec3.zero))
                                   (vx (Vec3.normalized Vec3.zero)) = false.
Admitted.

(** [Vec3.near_zero] is the guard that is supposed to catch that case in
    [Scene.scatter], and it does not: [Flt.ltb nan 1e-16] is false, so a
    NaN direction is not "near zero" and is used as it stands. *)

Lemma near_zero_misses_nan (v : vec3) :
  Flt.eqb (Vec3.length_squared v) (Vec3.length_squared v) = false ->
  Vec3.near_zero v = false.
Admitted.

(** ** The sphere tests

    [Scene.hit] keeps the closest hit so far in its [hit_record] argument,
    so its specification is not "the intersection is at [t]" but "the
    record it returns is either the one it was given or a nearer hit
    inside the window".  That half is pure comparison bookkeeping and
    needs nothing about the geometry. *)

Lemma hit_narrows (obj : hittable) (r : ray) (a tmin : Flt.t) (h : hit_record) :
  Scene.hit obj r a tmin h = h
  \/ (Flt.ltb (hit_t (Scene.hit obj r a tmin h)) tmin = false
      /\ Flt.ltb (hit_t h) (hit_t (Scene.hit obj r a tmin h)) = false).
Admitted.

Lemma hit_list_nil (r : ray) (tmin tmax : Flt.t) :
  Scene.hit_list [] r tmin tmax
  = Scene.MkHit Vec3.zero tmax Scene.Sky Vec3.zero true.
Proof. reflexivity. Qed.

(** Either nothing was hit, and [hit_t] is still the sentinel the fold
    started from, or it is inside the window.  Induction on the world with
    [hit_narrows]. *)

Lemma hit_list_bounded (world : list hittable) (r : ray) (tmin tmax : Flt.t) :
  hit_t (Scene.hit_list world r tmin tmax) = tmax
  \/ (Flt.ltb (hit_t (Scene.hit_list world r tmin tmax)) tmin = false
      /\ Flt.ltb tmax (hit_t (Scene.hit_list world r tmin tmax)) = false).
Admitted.

(** The world may be split, which is what would let a bounding structure
    be slotted in later: [fold_left_app] and nothing else. *)

Lemma hit_list_app (w1 w2 : list hittable) (r : ray) (tmin tmax : Flt.t) :
  Scene.hit_list (w1 ++ w2) r tmin tmax
  = List.fold_left
      (fun h obj => Scene.hit obj r (Vec3.length_squared (ray_dir r)) tmin h)
      w2 (Scene.hit_list w1 r tmin tmax).
Admitted.

(** Scene order does not matter.  Stated for the distance only, because
    the full record cannot be order-independent: two spheres at exactly
    the same [t] are settled by which came first, [Scene.hit] keeping the
    incumbent on a tie ([Flt.ltb (hit_t h) root] is false when they are
    equal).  Even this weaker form should be approached as a conjecture
    rather than a lemma -- a NaN [root], from a NaN ray direction, is
    rejected by both guards and so is order-independent, but the argument
    has to be made rather than assumed. *)

Lemma hit_list_t_permutation (w1 w2 : list hittable) (r : ray) (tmin tmax : Flt.t) :
  Permutation w1 w2 ->
  hit_t (Scene.hit_list w1 r tmin tmax) = hit_t (Scene.hit_list w2 r tmin tmax).
Admitted.

(** ** Colour: what is *not* true

    The statement one wants is that [Scene.ray_color] returns a colour in
    gamut, which would make the clamp in [Render.channel_byte] a no-op.
    It is false twice over, and both failures are worth recording because
    each one is a reason the clamp has to stay:

    - the Sky branch computes [t = 0.5 * (vy unit + 1)] and takes the
      convex combination of two colours at [t].  That is in gamut only if
      [vy unit] is in [-1, 1], and [unit] is [Vec3.normalized] of a
      direction, so it is a unit vector only to within a rounding error.
      [t] can land an ulp or two outside [0, 1], and the colour an ulp or
      two outside gamut.

    - [Scene.scatter]'s Lambertian branch calls [Vec3.normalized] on a
      point drawn from [Random.in_unit_sphere], which accepts the zero
      vector (its test is [length_squared < 1]).  That is [0 / 0], a NaN
      direction, and [Vec3.near_zero] does not catch it
      ([near_zero_misses_nan]).  The NaN then propagates: the next bounce
      has a NaN [a], misses everything, reaches Sky, and the colour comes
      back NaN.  The draw is three of 2^53 values at once, so about
      2^-159 per sample -- but "never" is not what the type says, and
      [channel_byte_nan] is the backstop.

    So the honest statement is the Sky branch's, under its hypothesis. *)

Definition in_gamut (c : color) : Prop :=
  Flt.leb 0 (vx c) = true /\ Flt.leb (vx c) 1 = true /\
  Flt.leb 0 (vy c) = true /\ Flt.leb (vy c) 1 = true /\
  Flt.leb 0 (vz c) = true /\ Flt.leb (vz c) 1 = true.

Lemma sky_in_gamut (r : ray) (g : int) (h : hit_record) :
  hit_material h = Scene.Sky ->
  Flt.leb (Flt.neg 1) (vy (Vec3.normalized (ray_dir r))) = true ->
  Flt.leb (vy (Vec3.normalized (ray_dir r))) 1 = true ->
  match fst (Scene.scatter h r g) with
  | Scene.Emit c => in_gamut c
  | Scene.Scatter _ _ => True
  end.
Admitted.

(** Every material's attenuation is in gamut, which is the induction
    hypothesis the gamut claim for [ray_color] would need, and is true
    without qualification: the albedos are literals of the scene and
    [Scene.Dielectric] scatters [Vec3.white]. *)

Lemma scatter_albedo_in_gamut (h : hit_record) (r : ray) (g : int) :
  (match hit_material h with
   | Scene.Lambertian a => in_gamut a
   | Scene.Metal a _ => in_gamut a
   | _ => True
   end) ->
  match fst (Scene.scatter h r g) with
  | Scene.Scatter a _ => in_gamut a
  | Scene.Emit _ => True
  end.
Admitted.

(** ** The generator

    SplitMix's [mix] is a bijection on int63: [fun x => x lxor (x >> k)]
    is unitriangular over GF(2) and so invertible for any [k], and the two
    multipliers are odd, so multiplication by them is invertible mod 2^63.
    [Random.mix1] is 4564476756301768121 and [Random.mix2] is
    1499779743744070123; both are odd. *)

Lemma mix_injective (x y : int) : Random.mix x = Random.mix y -> x = y.
Admitted.

(** Hence neighbouring pixels of a row never share a stream, which is what
    [Tests.v:104] checks at one point and what keeps the noise from being
    visibly correlated along a row.  Addition on int63 is cancellative, so
    this follows from [mix_injective] alone.

    It does *not* generalise to pairs: [Random.seed_at] combines the
    coordinates as [x + mix y], so two different pixels in two different
    rows can collide.  Making it injective in both would mean changing
    [seed_at] to mix [x] and [y] separately. *)

Lemma seed_at_row_injective (seed y x x' : int) :
  Random.seed_at seed x y = Random.seed_at seed x' y -> x = x'.
Admitted.

(** A sample is in [0, 1).  [r >> 10] is below 2^53, which [Flt.of_int]
    carries exactly, and [Random.scale53] is exactly 2^-53, so the product
    is exact too -- there is no rounding anywhere in [unit_flt] and the
    bound is not an approximation. *)

Lemma unit_flt_in_range (s : int) :
  Flt.leb 0 (fst (Random.unit_flt s)) = true
  /\ Flt.ltb (fst (Random.unit_flt s)) 1 = true.
Admitted.

Lemma scale53_is_two_pow_53 :
  Random.scale53 = Flt.div 1 (Flt.of_int (1 << 53)%uint63).
Proof. reflexivity. Qed.

(** [Random.in_unit_sphere] either returns a point in the sphere or runs
    out of fuel after 32 rejections and returns the last draw, which is
    the only reason the bound is not unconditional.  Each round rejects
    with probability about 1 - pi/6, so 32 of them fail together about
    once in 2^48. *)

Lemma in_unit_sphere_in_range (s : int) :
  Flt.ltb (Vec3.length_squared (fst (Random.in_unit_sphere s))) 1 = true
  \/ Random.in_unit_sphere_fuel 32 s = Random.in_unit_sphere_fuel 1 s.
Admitted.

(*****************************************************************************)
(*  The series of Trig.v, in the reals                                       *)
(*                                                                           *)
(*  The one group that needs Flocq and [Reals] rather than just the          *)
(*  primitives.  Flocq is already in the closure (CompCert pulls it), and    *)
(*  [Flocq.IEEE754.PrimFloat] is the bridge: [Prim2B] maps a                 *)
(*  [PrimFloat.float] to a [BinarySingleNaN.binary_float], with             *)
(*  [add_equiv], [sub_equiv], [mul_equiv], [div_equiv], [sqrt_equiv],        *)
(*  [ltb_equiv] and [of_int63_equiv] relating every primitive the renderer   *)
(*  uses to its Flocq counterpart.                                           *)
(*                                                                           *)
(*  Each bound below is two independent pieces: the truncation error of the  *)
(*  Taylor polynomial, which is real analysis against [Stdlib]'s [sin] and   *)
(*  [cos]; and the rounding error of evaluating it in Horner form, which is  *)
(*  Flocq's [relative_error_N_FLX] accumulated over the terms.  Without      *)
(*  Gappa or Interval -- neither is in the closure -- the second piece is    *)
(*  done by hand, which is why this is the expensive group.                  *)
(*                                                                           *)
(*  The constants are what the port measures against libm rather than what   *)
(*  has been derived: 1 ulp for sin and cos over [-pi/4, pi/4], and          *)
(*  [Trig.tan_deg 10] agreeing with libm to the last two bits (Tests.v).     *)
(*  Proving them may well need the stated bounds loosened.                   *)
(*****************************************************************************)

From Stdlib Require Import Reals.
From Flocq Require Import Core.Core Core.Ulp IEEE754.BinarySingleNaN
                          IEEE754.PrimFloat.

Local Open Scope R_scope.

(** The real number a float denotes, and the format the renderer computes
    in: binary64 is [FLT_exp (-1074) 53]. *)

Definition R_of (x : Flt.t) : R := B2R (Prim2B x).
Definition binary64 : Z -> Z := FLT_exp (-1074) 53.
Definition is_num (x : Flt.t) : Prop := is_finite (Prim2B x) = true.

Lemma sin_accurate (x : Flt.t) :
  is_num x -> Rabs (R_of x) <= PI / 4 ->
  Rabs (R_of (Trig.sin x) - sin (R_of x)) <= ulp radix2 binary64 (R_of x).
Admitted.

Lemma cos_accurate (x : Flt.t) :
  is_num x -> Rabs (R_of x) <= PI / 4 ->
  Rabs (R_of (Trig.cos x) - cos (R_of x)) <= ulp radix2 binary64 (R_of x).
Admitted.

(** [Trig.pi] is the nearest binary64 to PI, which is the only sense in
    which a float literal can be it, and [Trig.deg_to_rad] is then one
    multiplication by a rounded [pi / 180]: two roundings, and the error
    of the first is what sets the floor on [tan_deg]. *)

Lemma pi_is_nearest : Rabs (R_of Trig.pi - PI) <= ulp radix2 binary64 PI / 2.
Admitted.

Lemma deg_to_rad_accurate (d : Flt.t) :
  is_num d -> Rabs (R_of d) <= 180 ->
  Rabs (R_of (Trig.deg_to_rad d) - R_of d * PI / 180)
  <= 2 * ulp radix2 binary64 (R_of d * PI / 180).
Admitted.

(** [Trig.tan] divides, so its error is the two series' errors plus the
    division's, amplified by [1 / cos^2].  The bound is only useful away
    from the pole; the renderer calls it at [kn_vfov / 2], which the
    camera keeps well inside. *)

Lemma tan_deg_accurate (d : Flt.t) :
  is_num d -> Rabs (R_of d) <= 45 ->
  Rabs (R_of (Trig.tan_deg d) - tan (R_of d * PI / 180))
  <= 4 * ulp radix2 binary64 (tan (R_of d * PI / 180)).
Admitted.

(** With the series specified, the geometry becomes statable: this is the
    half of [Scene.hit] that [hit_narrows] above deliberately leaves out.
    The bound is bad and honestly so -- [half_b * half_b - a * c] cancels
    catastrophically for a grazing ray, and no amount of care in the proof
    removes that.  The useful reading of this statement is as the argument
    for reformulating the discriminant, not as a property to establish
    about the current one. *)

Lemma hit_is_on_the_sphere (center : vec3) (radius : Flt.t) (m : Scene.material)
                           (r : ray) (a tmin : Flt.t) (h : hit_record) (eps : R) :
  let h' := Scene.hit (Scene.Sphere center radius m) r a tmin h in
  h' <> h ->
  Rabs (R_of (Vec3.length_squared (Vec3.sub (hit_p h') center))
        - R_of radius * R_of radius) <= eps.
Admitted.

(*****************************************************************************)
(*  Not stated here: the backend                                             *)
(*                                                                           *)
(*  The statement that matters most for getting this module to run is not    *)
(*  about the renderer at all -- it is that CertiRocq's Wasm backend         *)
(*  compiles each primitive to an instruction with the same meaning.  It     *)
(*  belongs in CertiRocq, and stating it here would make this file depend    *)
(*  on WasmCert.  The shape, for the record:                                 *)
(*                                                                           *)
(*  WasmCert-Coq's [Wasm_float.Float64.T] is [Flocq.IEEE754.Binary.          *)
(*  binary_float] (wasm/numerics.v:1149) -- the development *with* NaN       *)
(*  payloads, and with [default_nan] an axiomatised Parameter.  [Prim2B]     *)
(*  lands in [BinarySingleNaN.binary_float], which has one NaN.  Flocq       *)
(*  bridges the two: [Binary.B2BSN] and [Binary.BSN2B] (the latter taking    *)
(*  the NaN as a parameter, which lines up with WasmCert's), with            *)
(*  [B2R_B2BSN], [is_nan_B2BSN] and [B2BSN_BSN2B].  So                       *)
(*                                                                           *)
(*    B2BSN (Wasm_float.Float64.fadd (to_wasm x) (to_wasm y))                *)
(*    = Prim2B (PrimFloat.add x y)                                           *)
(*                                                                           *)
(*  and the same for fsub, fmul, fdiv, fneg, fabs, fsqrt, flt and the        *)
(*  conversion.  Everything agrees on finite values; the whole content is    *)
(*  which NaN comes out.  [min_is_arg] and [max_is_arg] above are in this    *)
(*  file because [BOF_min] and [BOF_max] are the one pair for which no such  *)
(*  lemma can be had, which is why Flt.v builds min and max from [ltb].      *)
(*****************************************************************************)

(*****************************************************************************)
(*  What is proved about the renderer                                        *)
(*                                                                           *)
(*  Two groups:                                                              *)
(*                                                                           *)
(*   - the shape of the output: a job returns exactly three bytes per        *)
(*     pixel, which is the invariant the host checks at run time.  Proved.   *)
(*                                                                           *)
(*   - what the signed operations of Fixed.v mean.  They are built out of    *)
(*     the unsigned primitives, since CertiRocq's Wasm backend implements    *)
(*     no signed one, and Sint63.to_Z -- a definition, not a primitive --    *)
(*     is the reading they are meant to have.  These are statements only:    *)
(*     everything from ltb_spec on is Admitted, and the numbers they claim   *)
(*     are the ones the tests in Tests.v check by computation.               *)
(*****************************************************************************)

From Stdlib Require Import ZArith Uint63 Sint63 List Lia.
From Raytracing Require Import Fixed Vec3 Random Scene Render.

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

(** ** The signed operations

    Statements only.  Nothing in the renderer depends on them: the Wasm
    module is compiled from extraction.v, which does not import this file,
    so no admitted lemma reaches the extracted code. *)

Local Notation toZ := Sint63.to_Z.

Lemma wB_value : wB = 2 ^ 63.
Proof. reflexivity. Qed.

Lemma phi_sign_bit : Uint63.to_Z Fixed.sign_bit = 2 ^ 62.
Proof. reflexivity. Qed.

(** The two's-complement reading, as a case split. *)
Lemma to_Z_cases (x : int) :
  toZ x = if Uint63.to_Z x <? 2 ^ 62 then Uint63.to_Z x else Uint63.to_Z x - 2 ^ 63.
Proof.
  rewrite Sint63.to_Z_cmodwB; unfold Sint63.cmod.
  assert (B := Uint63.to_Z_bounded x); rewrite wB_value in *.
  change (2 ^ 63 / 2) with (2 ^ 62).
  destruct (Z.ltb_spec (Uint63.to_Z x) (2 ^ 62)).
  - rewrite Z.mod_small; lia.
  - replace (Uint63.to_Z x + 2 ^ 62) with (Uint63.to_Z x - 2 ^ 62 + 1 * 2 ^ 63) by lia.
    rewrite Z_mod_plus_full, Z.mod_small; lia.
Qed.

Lemma is_neg_spec (x : int) : Fixed.is_neg x = true <-> toZ x < 0.
Proof.
  unfold Fixed.is_neg.
  assert (B := Uint63.to_Z_bounded x); rewrite wB_value in B.
  rewrite to_Z_cases.
  split.
  - intros Hle%Uint63.leb_spec; rewrite phi_sign_bit in Hle.
    destruct (Z.ltb_spec (Uint63.to_Z x) (2 ^ 62)) as [Hc|Hc]; lia.
  - intros Hneg; apply Uint63.leb_spec; rewrite phi_sign_bit.
    destruct (Z.ltb_spec (Uint63.to_Z x) (2 ^ 62)) as [Hc|Hc]; lia.
Qed.

(** Comparison is the signed one. *)
Lemma ltb_spec (x y : int) : Fixed.ltb x y = true <-> toZ x < toZ y.
Admitted.

Lemma leb_spec (x y : int) : Fixed.leb x y = true <-> toZ x <= toZ y.
Admitted.

(** Negation and absolute value, away from the one value that has no
    positive counterpart. *)
Lemma neg_spec (x : int) :
  toZ x <> toZ Fixed.min_val -> toZ (Fixed.neg x) = - toZ x.
Admitted.

Lemma abs_spec (x : int) :
  toZ x <> toZ Fixed.min_val -> toZ (Fixed.abs x) = Z.abs (toZ x).
Admitted.

(** Addition and subtraction are exact as long as they do not leave the
    range; outside it they wrap, like the machine word they are. *)
Lemma add_spec (x y : int) :
  - (2 ^ 62) <= toZ x + toZ y < 2 ^ 62 -> toZ (Fixed.add x y) = toZ x + toZ y.
Admitted.

Lemma sub_spec (x y : int) :
  - (2 ^ 62) <= toZ x - toZ y < 2 ^ 62 -> toZ (Fixed.sub x y) = toZ x - toZ y.
Admitted.

(** Multiplication is the product of the two scaled integers, divided by
    the scale, truncated towards zero (Z.quot).  The bound is the one that
    sends umulq down its single-word path, which is where every value of
    the scenes lives: |x| < 2^31 / 2^24 = 128. *)
Lemma mul_spec (x y : int) :
  Z.abs (toZ x) < 2 ^ 31 -> Z.abs (toZ y) < 2 ^ 31 ->
  toZ (Fixed.mul x y) = Z.quot (toZ x * toZ y) (2 ^ 24).
Admitted.

(** Division likewise, on the path where the shifted dividend still fits
    in a word; a zero divisor saturates instead, which is what keeps the
    operation total. *)
Lemma div_spec (x y : int) :
  toZ y <> 0 -> Z.abs (toZ x) < 2 ^ 38 ->
  Z.abs (Z.quot (toZ x * 2 ^ 24) (toZ y)) < 2 ^ 62 ->
  toZ (Fixed.div x y) = Z.quot (toZ x * 2 ^ 24) (toZ y).
Admitted.

Lemma div_zero_spec (x : int) :
  0 <= toZ x -> toZ (Fixed.div x 0%uint63) = toZ Fixed.max_val.
Admitted.

(** The square root is correct to within one unit in the last place: the
    six Newton steps land next to the integer square root of x * 2^24. *)
Lemma sqrt_spec (x : int) :
  0 < toZ x ->
  (toZ (Fixed.sqrt x) - 1) ^ 2 <= toZ x * 2 ^ 24
  /\ toZ x * 2 ^ 24 <= (toZ (Fixed.sqrt x) + 1) ^ 2.
Admitted.

Lemma sqrt_nonpos (x : int) : toZ x <= 0 -> Fixed.sqrt x = 0%uint63.
Admitted.

(** The shift that stands in for the missing arithmetic one rounds down. *)
Lemma sar_spec (x : int) (k : int) :
  Uint63.to_Z k < 63 -> toZ (Fixed.sar x k) = toZ x / 2 ^ Uint63.to_Z k.
Admitted.

(** Conversion in and out of the integers. *)
Lemma of_int_spec (n : int) :
  Z.abs (toZ n) < 2 ^ 38 -> toZ (Fixed.of_int n) = toZ n * 2 ^ 24.
Admitted.

Lemma floor_to_int_spec (x : int) :
  toZ (Fixed.floor_to_int x) = toZ x / 2 ^ 24.
Admitted.

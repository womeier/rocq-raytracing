(*****************************************************************************)
(*  Computational tests                                                      *)
(*                                                                           *)
(*  Everything here is checked by conversion when the file is compiled, so   *)
(*  a failing expectation breaks the build.  The reference values are the    *)
(*  IEEE ones, and the comparisons are exact: a decimal literal denotes the  *)
(*  binary64 value it rounds to, so these equations pin down the             *)
(*  arithmetic to the last bit.                                              *)
(*                                                                           *)
(*  Several of them are the same equations the fixed-point port made, now    *)
(*  landing on the exact answer rather than near it -- the normalised        *)
(*  vector, the root of 1e-4, the quotient 1/1000000.                        *)
(*****************************************************************************)

From Stdlib Require Import Uint63 List Strings.Byte.
From Raytracing Require Import Flt Trig Vec3 Random Scene Render.

Import ListNotations.
Open Scope float_scope.

(** ** Float arithmetic *)

Example one_times_one : 1 * 1 = 1. Proof. reflexivity. Qed.
Example half_squared : 0.5 * 0.5 = 0.25. Proof. reflexivity. Qed.
Example signs_multiply : -4 * 0.25 = -1. Proof. reflexivity. Qed.
Example signs_divide : 13 / -4 = -3.25. Proof. reflexivity. Qed.

(* Division rounds to nearest, where the fixed point truncated: a third is
   just above 0.3333333333333333 rather than just below. *)
Example thirds_round_to_nearest : 1 / 3 = 0.33333333333333331.
Proof. reflexivity. Qed.

(* Ties go to even, which is the rounding Wasm's f64 arithmetic does and
   the rounding FloatAxioms specifies.  2^-53 above 1 is exactly halfway
   to the next float and rounds back down; twice that is the next float. *)
Example ties_round_to_even : 1 + 1.1102230246251565e-16 = 1.
Proof. reflexivity. Qed.
Example one_ulp_above_one : 1 + 2.220446049250313e-16 = 1.0000000000000002.
Proof. reflexivity. Qed.

(* Neither of these traps, which is what keeps every operation total: the
   fixed point saturated at max_val and clamped a negative root to zero,
   the float has values for both.  NaN is its own witness -- it is the one
   value not equal to itself. *)
Example div_zero_is_infinity : 1 / 0 = Flt.infinity. Proof. reflexivity. Qed.
Example sqrt_of_negative_is_nan :
  Flt.eqb (Flt.sqrt (-1)) (Flt.sqrt (-1)) = false.
Proof. reflexivity. Qed.

Example sqrt_two : Flt.sqrt 2 = 1.4142135623730951. Proof. reflexivity. Qed.
Example sqrt_exact : Flt.sqrt 100 = 10. Proof. reflexivity. Qed.
Example sqrt_quarter : Flt.sqrt 0.25 = 0.5. Proof. reflexivity. Qed.

(* Q38.24 held +-2.7e11 to a resolution of 6e-8, so neither the range nor
   the small end of these was reachable before. *)
Example huge_times_tiny : 1e300 * 1e-300 = 1. Proof. reflexivity. Qed.
Example small_sqrt : Flt.sqrt 0.0001 = 0.01. Proof. reflexivity. Qed.
Example small_quotient : 1 / 1000000 = 0.000001. Proof. reflexivity. Qed.

Example compares_signed : Flt.ltb (-1) 0 = true. Proof. reflexivity. Qed.
Example compares_signed' : Flt.ltb 0 (-1) = false. Proof. reflexivity. Qed.

(** ** The one float-to-int conversion

    [Flt.trunc_byte] is the floor on [0, 256), the range [channel_byte]
    clamps to; the result is a plain machine word, so the right-hand sides
    are written in uint63. *)

Example trunc_floor : Flt.trunc_byte 37.75 = 37%uint63. Proof. reflexivity. Qed.
Example trunc_exact : Flt.trunc_byte 128 = 128%uint63. Proof. reflexivity. Qed.
Example trunc_bottom : Flt.trunc_byte 0.999999 = 0%uint63. Proof. reflexivity. Qed.
(* the top of the clamp, which must stay a byte *)
Example trunc_top : Flt.trunc_byte (256 * 0.999999) = 255%uint63.
Proof. reflexivity. Qed.

(** ** Trigonometry (tan 10 degrees = 0.17632698070846498)

    The series of Trig.v now agrees with libm to the last two bits, where
    the fixed point could only reach 0.1763265. *)

Example tan_ten : Trig.tan_deg 10 = 0.176326980708465. Proof. reflexivity. Qed.
Example tan_odd : Trig.tan_deg (-10) = -0.176326980708465. Proof. reflexivity. Qed.

(** ** Randomness

    The generator is SplitMix, and the stream of a pixel is derived from its
    coordinates, so these values are what the renderer actually samples.
    They are not the fixed-point port's: a sample is now the top 53 bits of
    the generator's word rather than the top 24. *)

Example random_unit : fst (Random.unit_flt 1%uint63) = 0.11899029095837987.
Proof. reflexivity. Qed.
Example random_unit' : fst (Random.unit_flt 2%uint63) = 0.7523070158382239.
Proof. reflexivity. Qed.

Example rejection_sampling_lands_inside :
  Flt.ltb (Vec3.length_squared (fst (Random.in_unit_sphere 7%uint63))) 1 = true.
Proof. reflexivity. Qed.
Example the_disk_is_flat : vz (fst (Random.in_unit_disk 7%uint63)) = 0.
Proof. reflexivity. Qed.

(* neighbouring pixels must not share a stream, or the noise would be
   visibly correlated along the row *)
Example pixels_get_their_own_stream :
  Uint63.eqb (Random.seed_at 1 0 0) (Random.seed_at 1 1 0) = false.
Proof. reflexivity. Qed.

(** ** Vectors *)

Example dot_product : Vec3.dot (V3 1 2 3) (V3 4 5 6) = 32. Proof. reflexivity. Qed.
Example cross_product : Vec3.cross (V3 1 0 0) (V3 0 1 0) = V3 0 0 1.
Proof. reflexivity. Qed.
Example length_of_345 : Vec3.length (V3 3 4 0) = 5. Proof. reflexivity. Qed.
(* a normalised vector is of unit length exactly here; the fixed point was
   2^-23 short, which was the accuracy the whole renderer worked at *)
Example normalized_is_unit : Vec3.length (Vec3.normalized (V3 1 2 3)) = 1.
Proof. reflexivity. Qed.

(** ** Geometry: a ray down the y axis meets the ground sphere of the
       weekend scene at t = 2, with the normal pointing up *)

Definition ground : hittable :=
  Sphere (V3 0 (-1000) 0) 1000 (Lambertian (Vec3.rgb 0.5 0.5 0.5)).

Example hits_the_ground :
  hit_list [ground] (MkRay (V3 0 2 0) (V3 0 (-1) 0)) 0.001 Flt.infinity
  = MkHit (V3 0 0 0) 2 (Lambertian (Vec3.rgb 0.5 0.5 0.5)) (V3 0 1 0) true.
Proof. reflexivity. Qed.

(* straight up is sky, which is the gradient's far end *)
Example sky_straight_up :
  fst (ray_color [ground] 4 (MkRay (V3 0 2 0) (V3 0 1 0)) Vec3.white 1%uint63)
  = Vec3.rgb 0.5 0.7 1.
Proof. reflexivity. Qed.

(* and the ground is that gradient at half albedo *)
Example ground_is_half_the_sky :
  fst (ray_color [ground] 2 (MkRay (V3 0 2 0) (V3 0 (-1) 0)) Vec3.white 12345%uint63)
  = Vec3.rgb 0.33855810083611493 0.40313486050166891 0.5.
Proof. reflexivity. Qed.

(** ** The adjustable scene *)

Example the_scene_has_four_spheres :
  List.length (scene_knobs default_knobs) = 4%nat.
Proof. reflexivity. Qed.

(* the second one is the sphere the controls move, glass by default *)
Example the_middle_sphere_is_glass :
  List.nth_error (scene_knobs default_knobs) 1
  = Some (Sphere (V3 0 1 0) 1 (Dielectric 1.5)).
Proof. reflexivity. Qed.

Example the_material_knob_selects :
  knob_material (MkKnobs (V3 13 2 3) 20 0.1 10 (V3 0 1 0) 1 1%uint63 0.3
                         (Vec3.rgb 1 0 0))
  = Metal (Vec3.rgb 1 0 0) 0.3.
Proof. reflexivity. Qed.

(* a 90 degree field of view puts the viewport at unit distance, to within
   the two bits the series and the reciprocal cost *)
Example the_field_of_view_is_a_tangent :
  Trig.tan_deg (kn_vfov (MkKnobs (V3 0 0 1) 90 0 1 (V3 0 0 0) 1 0%uint63 0 Vec3.white)
                / 2) = 1.0000000000000002.
Proof. reflexivity. Qed.

(** ** Output *)

Open Scope uint63_scope.

Definition cfg4x2 : config := MkConfig 4 2 1 1 1 0 Scene.default_knobs.

Example header_is_p6 :
  ppm_header cfg4x2 = ["P"; "6"; "010"; "4"; " "; "2"; "010"; "2"; "5"; "5"; "010"]%byte.
Proof. reflexivity. Qed.

Example header_of_wider :
  ppm_header (MkConfig 1024 768 1 1 1 0 Scene.default_knobs)
  = ["P"; "6"; "010"; "1"; "0"; "2"; "4"; " "; "7"; "6"; "8"; "010";
     "2"; "5"; "5"; "010"]%byte.
Proof. reflexivity. Qed.

(* three bytes per pixel, and the first-light scene's top-left corner is
   sky -- the same byte triple the fixed point produced, which is the
   check that the two formats agree on the image *)
Example span_is_three_bytes_per_pixel :
  List.length (render (prepare cfg4x2, MkJob cfg4x2 0 0 4)) = 12%nat.
Proof. reflexivity. Qed.

Example corner_is_sky :
  render (prepare cfg4x2, MkJob cfg4x2 0 0 1) = ["192"; "217"; "255"]%byte.
Proof. reflexivity. Qed.

(* Cutting a row into jobs does not change it: the sampling stream is
   derived from the pixel's coordinates, not from where the job began.
   This is what lets the drivers size their chunks to a memory budget. *)
Example spans_compose :
  render (prepare cfg4x2, MkJob cfg4x2 0 0 4)
  = render (prepare cfg4x2, MkJob cfg4x2 0 0 1)
    ++ render (prepare cfg4x2, MkJob cfg4x2 0 1 3).
Proof. vm_compute. reflexivity. Qed.

Example an_empty_span_is_empty : render (prepare cfg4x2, MkJob cfg4x2 0 2 0) = [].
Proof. reflexivity. Qed.

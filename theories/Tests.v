(*****************************************************************************)
(*  Computational tests                                                      *)
(*                                                                           *)
(*  Everything here is checked by conversion when the file is compiled, so   *)
(*  a failing expectation breaks the build.  The reference values are the    *)
(*  IEEE ones rounded to the format, and the comparisons are exact: a        *)
(*  decimal literal denotes the fixed-point value it rounds to, so these     *)
(*  equations pin down the arithmetic to the last bit.                       *)
(*****************************************************************************)

From Stdlib Require Import Uint63 List Strings.Byte.
From Raytracing Require Import Fixed Trig Vec3 Random Scene Render.

Import ListNotations.
Import Fixed.FixedNotations.
Open Scope fixed_scope.

(** ** Fixed-point arithmetic *)

Example one_times_one : 1 * 1 = 1. Proof. reflexivity. Qed.
Example half_squared : 0.5 * 0.5 = 0.25. Proof. reflexivity. Qed.
Example signs_multiply : -4 * 0.25 = -1. Proof. reflexivity. Qed.
Example signs_divide : 13 / -4 = -3.25. Proof. reflexivity. Qed.
Example truncates_towards_zero : 1 / 3 = 0.333333313465118408203125.
Proof. reflexivity. Qed.

(* 2^-24, the resolution of the format *)
Example resolution : 0.000000059604644775390625 = Fixed.of_int 1 / 16777216.
Proof. reflexivity. Qed.

(* division by zero saturates rather than trapping, which is what keeps
   every operation total *)
Example div_zero_saturates : 1 / 0 = Fixed.max_val. Proof. reflexivity. Qed.
Example sqrt_of_negative : Fixed.sqrt (-1) = 0. Proof. reflexivity. Qed.

(* sqrt 2 = 1.4142135623..., and the format holds 1.41421353816986083984375 *)
Example sqrt_two : Fixed.sqrt 2 = 1.41421353816986083984375.
Proof. reflexivity. Qed.
Example sqrt_exact : Fixed.sqrt 100 = 10. Proof. reflexivity. Qed.
Example sqrt_quarter : Fixed.sqrt 0.25 = 0.5. Proof. reflexivity. Qed.

(* Above 128 a product leaves the single-word path and goes through mulc,
   and above 16384 a quotient goes through diveucl_21; these are the only
   tests that exercise those paths. *)
Example wide_multiply : 1000 * 1000 = 1000000. Proof. reflexivity. Qed.
Example wide_multiply_signed : -1000 * 1000 = -1000000. Proof. reflexivity. Qed.
Example wide_multiply_mixed : 1000.5 * 2 = 2001. Proof. reflexivity. Qed.
Example wide_divide : 20000 / 4 = 5000. Proof. reflexivity. Qed.
Example wide_sqrt : Fixed.sqrt 1000000 = 1000. Proof. reflexivity. Qed.

(* at the bottom of the range the input is what loses the precision:
   0.0001 is held as 1677/2^24, and this is that value's root *)
Example small_sqrt : Fixed.sqrt 0.0001 = 0.009997844696044921875.
Proof. reflexivity. Qed.
Example small_quotient : 1 / 1000000 = 0.00000095367431640625.
Proof. reflexivity. Qed.

Example compares_signed : Fixed.ltb (-1) 0 = true. Proof. reflexivity. Qed.
Example compares_signed' : Fixed.ltb 0 (-1) = false. Proof. reflexivity. Qed.
(* the result is a plain integer, -2 as a machine word, not a fixed-point
   value, so the right-hand side is written in uint63 *)
Example floor_rounds_down : Fixed.floor_to_int (-1.5) = (0 - 2)%uint63.
Proof. reflexivity. Qed.

(** ** Trigonometry (tan 10 degrees = 0.17632698070846498) *)

Example tan_ten : Trig.tan_deg 10 = 0.1763265132904052734375. Proof. reflexivity. Qed.
Example tan_odd : Trig.tan_deg (-10) = -0.1763265132904052734375. Proof. reflexivity. Qed.

(** ** Randomness

    The generator is SplitMix, and the stream of a pixel is derived from its
    coordinates, so these values are what the renderer actually samples. *)

Example random_unit : fst (Random.unit_fx 1%uint63) = 0.118990242481231689453125.
Proof. reflexivity. Qed.
Example random_unit' : fst (Random.unit_fx 2%uint63) = 0.752306997776031494140625.
Proof. reflexivity. Qed.

Example rejection_sampling_lands_inside :
  Fixed.ltb (Vec3.length_squared (fst (Random.in_unit_sphere 7%uint63))) 1 = true.
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
(* a normalised vector is of unit length to within the two truncations
   that produced it -- 2^-23 short here, which is the accuracy the whole
   renderer works at *)
Example normalized_is_nearly_unit :
  Vec3.length (Vec3.normalized (V3 1 2 3)) = 0.99999988079071044921875.
Proof. reflexivity. Qed.

(** ** Geometry: a ray down the y axis meets the ground sphere of the
       weekend scene at t = 2, with the normal pointing up *)

Definition ground : hittable :=
  Sphere (V3 0 (-1000) 0) 1000 (Lambertian (Vec3.rgb 0.5 0.5 0.5)).

Example hits_the_ground :
  hit_list [ground] (MkRay (V3 0 2 0) (V3 0 (-1) 0)) 0.001 Fixed.max_val
  = MkHit (V3 0 0 0) 2 (Lambertian (Vec3.rgb 0.5 0.5 0.5)) (V3 0 1 0) true.
Proof. reflexivity. Qed.

(* straight up is sky, which is the gradient's far end *)
Example sky_straight_up :
  fst (ray_color [ground] 4 (MkRay (V3 0 2 0) (V3 0 1 0)) Vec3.white 1%uint63)
  = Vec3.rgb 0.5 0.699999988079071044921875 1.
Proof. reflexivity. Qed.

(* and the ground is that gradient at half albedo *)
Example ground_is_half_the_sky :
  fst (ray_color [ground] 2 (MkRay (V3 0 2 0) (V3 0 (-1) 0)) Vec3.white 12345%uint63)
  = Vec3.rgb 0.33855807781219482421875 0.403134822845458984375 0.5.
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

(* a 90 degree field of view puts the viewport at unit distance *)
Example the_field_of_view_is_a_tangent :
  Trig.tan_deg (kn_vfov (MkKnobs (V3 0 0 1) 90 0 1 (V3 0 0 0) 1 0%uint63 0 Vec3.white)
                / 2) = 0.99999904632568359375.
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
   sky *)
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

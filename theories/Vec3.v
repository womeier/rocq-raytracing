(*****************************************************************************)
(*  Three-dimensional vectors over the fixed-point numbers of Fixed.v        *)
(*                                                                           *)
(*  A port of Render/Vec3.lean from kmill/lean4-raytracer.  The Lean         *)
(*  original is generic in the component type and gets its operations from   *)
(*  Add/Sub/Mul/Div instances; here everything is specialised to Fixed.t,    *)
(*  which keeps the extracted code free of dictionaries.                     *)
(*****************************************************************************)

From Stdlib Require Import Uint63.
From Raytracing Require Import Fixed.

Import Fixed.FixedNotations.
Open Scope fixed_scope.

Record vec3 : Set := V3 { vx : Fixed.t; vy : Fixed.t; vz : Fixed.t }.

(* A colour is a vector of r, g, b components, as in the original. *)
Notation color := vec3.
Definition rgb (r g b : Fixed.t) : color := V3 r g b.

Definition zero : vec3 := V3 0 0 0.
Definition white : color := V3 1 1 1.
Definition black : color := V3 0 0 0.

Definition map (f : Fixed.t -> Fixed.t) (v : vec3) : vec3 :=
  V3 (f (vx v)) (f (vy v)) (f (vz v)).

Definition map2 (f : Fixed.t -> Fixed.t -> Fixed.t) (v w : vec3) : vec3 :=
  V3 (f (vx v) (vx w)) (f (vy v) (vy w)) (f (vz v) (vz w)).

Definition add (v w : vec3) : vec3 := map2 Fixed.add v w.
Definition sub (v w : vec3) : vec3 := map2 Fixed.sub v w.
Definition mul (v w : vec3) : vec3 := map2 Fixed.mul v w.
Definition neg (v : vec3) : vec3 := map Fixed.neg v.

(* scalar multiplication and division, the Lean HMul/HDiv instances *)
Definition scale (c : Fixed.t) (v : vec3) : vec3 := map (Fixed.mul c) v.
Definition divs (v : vec3) (c : Fixed.t) : vec3 := map (fun x => x / c) v.

Definition sum (v : vec3) : Fixed.t := vx v + vy v + vz v.
Definition dot (v w : vec3) : Fixed.t := sum (mul v w).
Definition length_squared (v : vec3) : Fixed.t := dot v v.
Definition length (v : vec3) : Fixed.t := Fixed.sqrt (length_squared v).

Definition cross (v w : vec3) : vec3 :=
  V3 (vy v * vz w - vz v * vy w)
     (vz v * vx w - vx v * vz w)
     (vx v * vy w - vy v * vx w).

Definition normalized (v : vec3) : vec3 := divs v (length v).

(** Reflect v in the plane with normal n. *)
Definition reflect (v n : vec3) : vec3 := sub v (scale (2 * dot v n) n).

(** Refract uv through the surface with normal n, with the ratio of the
    indices of refraction eta_i/eta_t. *)
Definition refract (uv n : vec3) (etai_over_etat : Fixed.t) : vec3 :=
  let cos_theta := Fixed.min (- dot uv n) 1 in
  let r_out_perp := scale etai_over_etat (add uv (scale cos_theta n)) in
  let r_out_parallel :=
    scale (- Fixed.sqrt (Fixed.abs (1 - length_squared r_out_perp))) n in
  add r_out_perp r_out_parallel.

(* The original's default epsilon is 1e-16, far below what Q38.24 can
   represent; the smallest positive value here is 2^-24 ~ 6e-8, so the
   squared length is compared against a representable 1e-10. *)
Definition near_zero (v : vec3) : bool := Fixed.ltb (length_squared v) 0.0000000001.

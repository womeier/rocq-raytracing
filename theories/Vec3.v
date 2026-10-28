(*****************************************************************************)
(*  Three-dimensional vectors over the primitive floats of Flt.v             *)
(*                                                                           *)
(*  A port of Render/Vec3.lean from kmill/lean4-raytracer.  The Lean         *)
(*  original is generic in the component type and gets its operations from   *)
(*  Add/Sub/Mul/Div instances; here everything is specialised to Flt.t,      *)
(*  which keeps the extracted code free of dictionaries.                     *)
(*****************************************************************************)

From Raytracing Require Import Flt.

Open Scope float_scope.

Record vec3 : Set := V3 { vx : Flt.t; vy : Flt.t; vz : Flt.t }.

(* A colour is a vector of r, g, b components, as in the original. *)
Notation color := vec3.
Definition rgb (r g b : Flt.t) : color := V3 r g b.

Definition zero : vec3 := V3 0 0 0.
Definition white : color := V3 1 1 1.
Definition black : color := V3 0 0 0.

Definition map (f : Flt.t -> Flt.t) (v : vec3) : vec3 :=
  V3 (f (vx v)) (f (vy v)) (f (vz v)).

Definition map2 (f : Flt.t -> Flt.t -> Flt.t) (v w : vec3) : vec3 :=
  V3 (f (vx v) (vx w)) (f (vy v) (vy w)) (f (vz v) (vz w)).

Definition add (v w : vec3) : vec3 := map2 Flt.add v w.
Definition sub (v w : vec3) : vec3 := map2 Flt.sub v w.
Definition mul (v w : vec3) : vec3 := map2 Flt.mul v w.
Definition neg (v : vec3) : vec3 := map Flt.neg v.

(* scalar multiplication and division, the Lean HMul/HDiv instances *)
Definition scale (c : Flt.t) (v : vec3) : vec3 := map (Flt.mul c) v.
Definition divs (v : vec3) (c : Flt.t) : vec3 := map (fun x => x / c) v.

Definition sum (v : vec3) : Flt.t := vx v + vy v + vz v.
Definition dot (v w : vec3) : Flt.t := sum (mul v w).
Definition length_squared (v : vec3) : Flt.t := dot v v.
Definition length (v : vec3) : Flt.t := Flt.sqrt (length_squared v).

Definition cross (v w : vec3) : vec3 :=
  V3 (vy v * vz w - vz v * vy w)
     (vz v * vx w - vx v * vz w)
     (vx v * vy w - vy v * vx w).

Definition normalized (v : vec3) : vec3 := divs v (length v).

(** Reflect v in the plane with normal n. *)
Definition reflect (v n : vec3) : vec3 := sub v (scale (2 * dot v n) n).

(** Refract uv through the surface with normal n, with the ratio of the
    indices of refraction eta_i/eta_t. *)
Definition refract (uv n : vec3) (etai_over_etat : Flt.t) : vec3 :=
  let cos_theta := Flt.min (- dot uv n) 1 in
  let r_out_perp := scale etai_over_etat (add uv (scale cos_theta n)) in
  let r_out_parallel :=
    scale (- Flt.sqrt (Flt.abs (1 - length_squared r_out_perp))) n in
  add r_out_perp r_out_parallel.

(* The original's epsilon, which binary64 represents and the Q38.24 fixed
   point of the first port had to raise to 1e-10 -- its smallest positive
   value was 2^-24, about 6e-8. *)
Definition near_zero (v : vec3) : bool := Flt.ltb (length_squared v) 1e-16.

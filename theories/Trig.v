(*****************************************************************************)
(*  Just enough trigonometry for the camera                                  *)
(*                                                                           *)
(*  The camera needs tan(vfov/2) and nothing else, so sine and cosine are    *)
(*  the truncated Taylor series, valid on |x| <= pi/4 where the omitted      *)
(*  terms are below the 2^-24 resolution of the format:                      *)
(*                                                                           *)
(*     sin x = x - x^3/6 + x^5/120 - x^7/5040                                *)
(*     cos x = 1 - x^2/2 + x^4/24 - x^6/720                                  *)
(*                                                                           *)
(*  The reciprocals appear as literals because multiplying is cheaper than   *)
(*  dividing.  Outside |x| <= pi/4 these are wrong (no argument reduction),  *)
(*  which is why only tan_deg, whose domain is checked, is exported for the  *)
(*  scene to use.                                                            *)
(*****************************************************************************)

From Stdlib Require Import Uint63.
From Raytracing Require Import Fixed.

Import Fixed.FixedNotations.
Open Scope fixed_scope.

Definition pi : Fixed.t := 3.14159265358979323846.
Definition deg_to_rad (d : Fixed.t) : Fixed.t := d * (pi / 180).

(* Horner form, in x2 = x^2 *)
Definition sin (x : Fixed.t) : Fixed.t :=
  let x2 := x * x in
  x * (1 - x2 * (0.16666666666666666 - x2 * (0.008333333333333333
                                             - x2 * 0.0001984126984126984))).

Definition cos (x : Fixed.t) : Fixed.t :=
  let x2 := x * x in
  1 - x2 * (0.5 - x2 * (0.041666666666666664 - x2 * 0.001388888888888889)).

Definition tan (x : Fixed.t) : Fixed.t := sin x / cos x.

(** tan of an angle in degrees, for |angle| < 90; the series is only good
    to pi/4, so bigger angles go through tan x = 1 / tan(pi/2 - x). *)
Definition tan_deg (d : Fixed.t) : Fixed.t :=
  let a := Fixed.abs d in
  let r := if Fixed.ltb a 45
           then tan (deg_to_rad a)
           else 1 / tan (deg_to_rad (90 - a)) in
  if Fixed.is_neg d then Fixed.neg r else r.

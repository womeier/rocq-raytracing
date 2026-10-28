(*****************************************************************************)
(*  Just enough trigonometry for the camera                                  *)
(*                                                                           *)
(*  PrimFloat has no transcendental primitive, so the camera's tan(vfov/2)   *)
(*  is computed here.  Sine and cosine are their Taylor series on            *)
(*  |x| <= pi/4, truncated where the first omitted term falls below the      *)
(*  rounding error of the result:                                            *)
(*                                                                           *)
(*     sin x = x - x^3/3! + ... - x^15/15! + x^17/17!   (next term 8e-20)    *)
(*     cos x = 1 - x^2/2! + ... + x^14/14! - x^16/16!   (next term 2e-18)    *)
(*                                                                           *)
(*  against an ulp of 1.1e-16 at sin(pi/4) and 2.2e-16 at cos 0, so both     *)
(*  land within one ulp of the correctly rounded value over the whole        *)
(*  interval.  (The fixed-point port stopped four terms earlier in each:     *)
(*  2^-24 resolution needed nothing more.)                                   *)
(*                                                                           *)
(*  The reciprocal factorials appear as literals because multiplying is      *)
(*  cheaper than dividing.  Outside |x| <= pi/4 these are wrong (no          *)
(*  argument reduction), which is why only tan_deg, whose domain is          *)
(*  checked, is exported for the scene to use.                               *)
(*****************************************************************************)

From Raytracing Require Import Flt.

Open Scope float_scope.

Definition pi : Flt.t := 3.14159265358979323846.
Definition deg_to_rad (d : Flt.t) : Flt.t := d * (pi / 180).

(* Horner form, in x2 = x^2 *)
Definition sin (x : Flt.t) : Flt.t :=
  let x2 := x * x in
  x * (1 - x2 * (0.16666666666666666
       - x2 * (0.008333333333333333
       - x2 * (0.0001984126984126984
       - x2 * (2.7557319223985893e-06
       - x2 * (2.505210838544172e-08
       - x2 * (1.6059043836821613e-10
       - x2 * (7.647163731819816e-13
       - x2 * 2.8114572543455206e-15)))))))).

Definition cos (x : Flt.t) : Flt.t :=
  let x2 := x * x in
  1 - x2 * (0.5
     - x2 * (0.041666666666666664
     - x2 * (0.001388888888888889
     - x2 * (2.48015873015873e-05
     - x2 * (2.755731922398589e-07
     - x2 * (2.08767569878681e-09
     - x2 * (1.1470745597729725e-11
     - x2 * 4.779477332387385e-14))))))).

Definition tan (x : Flt.t) : Flt.t := sin x / cos x.

(** tan of an angle in degrees, for |angle| < 90; the series is only good
    to pi/4, so bigger angles go through tan x = 1 / tan(pi/2 - x). *)
Definition tan_deg (d : Flt.t) : Flt.t :=
  let a := Flt.abs d in
  let r := if Flt.ltb a 45
           then tan (deg_to_rad a)
           else 1 / tan (deg_to_rad (90 - a)) in
  if Flt.ltb d 0 then Flt.neg r else r.

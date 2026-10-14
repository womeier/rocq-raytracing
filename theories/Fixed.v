(*****************************************************************************)
(*  Fixed-point arithmetic on primitive 63-bit integers                      *)
(*                                                                           *)
(*  CertiRocq's Wasm backend rejects primitive floats                        *)
(*                                                                           *)
(*    | AstCommon.primFloat => Err (floats are not yet supported)              *)
(*       (CertiRocq/CodegenWasm/LambdaANF_to_Wasm.v)                         *)
(*                                                                           *)
(*  so the raytracer computes in Q38.24 fixed point instead: a value is a    *)
(*  primitive int63 read as a two's-complement signed integer scaled by      *)
(*  2^24, i.e. [x] = to_Z x / 2^24.  That gives a resolution of 6e-8 and a   *)
(*  range of +-2.7e11, both far more than the scene needs.                   *)
(*                                                                           *)
(*  Only the primitives in the backend's table are used.  Notably that       *)
(*  table has no signed operation at all (no asr, divs, mods, ltsb, lesb,    *)
(*  compares), so Stdlib's Sint63 is off limits computationally and the      *)
(*  signed operations are derived here from the unsigned ones.  Sint63.to_Z  *)
(*  is a definition rather than a primitive, so it is still the right thing  *)
(*  to specify against in the proofs.                                        *)
(*****************************************************************************)

From Stdlib Require Import ZArith Uint63.

Open Scope uint63_scope.

Definition t : Set := int.

(** ** Format *)

(* fractional bits *)
Definition q : int := 24.

(* the sign bit of an int63, which is also Sint63.min_int *)
Definition sign_bit : int := 1 << 62.
Definition all_ones : int := 0 - 1.

Definition max_val : t := sign_bit - 1.   (* most positive *)
Definition min_val : t := sign_bit.       (* most negative *)

Definition zero : t := 0.
Definition one  : t := 1 << q.
Definition half : t := 1 << (q - 1).
Definition two  : t := 1 << (q + 1).

(** ** Sign, addition, comparison

    Addition and subtraction are the unsigned ones: two's complement makes
    them agree on both readings. *)

(* x is negative exactly when its unsigned value reaches 2^62 *)
Definition is_neg (x : t) : bool := Uint63.leb sign_bit x.

Definition add (x y : t) : t := x + y.
Definition sub (x y : t) : t := x - y.
Definition neg (x : t) : t := 0 - x.
Definition abs (x : t) : t := if is_neg x then neg x else x.

(* Two values of the same sign compare as unsigned ones; otherwise the
   negative one is the smaller.  Flipping the sign bit of both and
   comparing once would also do, but that allocates the two flipped words,
   and here the branches allocate nothing. *)
Definition ltb (x y : t) : bool :=
  if is_neg x then (if is_neg y then Uint63.ltb x y else true)
  else (if is_neg y then false else Uint63.ltb x y).

Definition leb (x y : t) : bool :=
  if is_neg x then (if is_neg y then Uint63.leb x y else true)
  else (if is_neg y then false else Uint63.leb x y).
Definition eqb (x y : t) : bool := Uint63.eqb x y.

Definition min (x y : t) : t := if ltb x y then x else y.
Definition max (x y : t) : t := if ltb x y then y else x.

(* arithmetic shift right: shift in copies of the sign bit, since asr is
   not available.  (all_ones << 63) is 0, so k = 0 is the identity. *)
Definition sar (x : t) (k : int) : t :=
  if is_neg x then (x >> k) lor (all_ones << (63 - k)) else x >> k.

Definition halve (x : t) : t := sar x 1.

(** ** Conversions *)

Definition of_int (n : int) : t := n << q.
Definition floor_to_int (x : t) : int := sar x q.          (* rounds down *)
Definition frac_part (x : t) : int := x land (one - 1).

(** ** Multiplication and division

    Both need the full 126-bit intermediate, which mulc and diveucl_21
    provide.  Both work on magnitudes and put the sign back afterwards, so
    both truncate towards zero. *)

(* (a * b) >> q for unsigned a, b.  The product of two magnitudes below
   2^31 stays below 2^62, where the single-word multiplication is already
   right: taking that path saves the pair mulc returns, which is a heap
   allocation per multiplication in a runtime without a garbage collector.
   Scene values are far inside the fast path (|x| < 128); the slow one is
   there to keep the operation total. *)
Definition small : int := 1 << 31.

Definition umulq (a b : int) : int :=
  if andb (Uint63.ltb a small) (Uint63.ltb b small) then (a * b) >> q
  else let (hi, lo) := mulc a b in (lo >> q) lor (hi << (63 - q)).

Definition mul (x y : t) : t :=
  let r := umulq (abs x) (abs y) in
  if xorb (is_neg x) (is_neg y) then neg r else r.

Definition square (x : t) : t := mul x x.

(* (a << q) / b for unsigned a, b, saturating at max_val: diveucl_21 needs
   its high word below the divisor, which also rules out b = 0, and the
   quotient itself has to stay below 2^62 to be a positive fixed-point
   number. *)
Definition shifted : int := 1 << 38.   (* a << q fits in a word below this *)

Definition udivq (a b : int) : int :=
  if Uint63.eqb b 0 then max_val
  else if Uint63.ltb a shifted then
    (* a << q is below 2^62, so one unsigned division does it, with no
       pair from diveucl_21 to allocate *)
    let r := (a << q) / b in
    if is_neg r then max_val else r
  else
    let hi := a >> (63 - q) in
    let lo := a << q in
    if Uint63.ltb hi b then
      let r := fst (diveucl_21 hi lo b) in
      if is_neg r then max_val else r
    else max_val.

Definition div (x y : t) : t :=
  let r := udivq (abs x) (abs y) in
  if xorb (is_neg x) (is_neg y) then neg r else r.

(* a fixed-point value from a ratio of two small integers: 0.9 is
   of_frac 9 10 *)
Definition of_frac (n d : int) : t := div (of_int n) (of_int d).

(** ** Square root

    Newton's iteration y |-> (y + x/y)/2 in fixed point.  head0 gives the
    binary magnitude of the raw value, and since the raw square root of x
    is sqrt(x * 2^q), a power of two within a factor of sqrt 2 of the
    answer is 1 << ((62 - head0 x + q) / 2).  From there the relative error
    is at most 0.3, and Newton squares it: six steps reach the 2^-24
    resolution of the format with room to spare. *)

Fixpoint sqrt_newton (n : nat) (x y : t) : t :=
  match n with
  | O => y
  | S n' => sqrt_newton n' x ((y + udivq x y) >> 1)
  end.

Definition sqrt (x : t) : t :=
  if leb x 0 then 0
  else sqrt_newton 6 x (1 << ((62 + q - head0 x) / 2)).

(** ** Notations *)

Declare Scope fixed_scope.
Delimit Scope fixed_scope with fx.

Module FixedNotations.
  Infix "+" := add : fixed_scope.
  Infix "-" := sub : fixed_scope.
  Infix "*" := mul : fixed_scope.
  Infix "/" := div : fixed_scope.
  Notation "- x" := (neg x) : fixed_scope.
  Infix "<?" := ltb : fixed_scope.
  Infix "<=?" := leb : fixed_scope.
  Infix "=?" := eqb : fixed_scope.
End FixedNotations.

(*****************************************************************************)
(** ** Decimal literals                                                      *)
(*                                                                           *)
(*  A Number Notation for fixed_scope, so that the port of the scene can be  *)
(*  written with the decimals of the original (0.5, 13, 1.5, -0.001) and     *)
(*  Eval prints fixed-point values back as decimals.  Both directions are    *)
(*  exact: every value is k/2^24, which has a finite decimal expansion of    *)
(*  at most 24 fractional digits (k/2^24 = k*5^24/10^24).                    *)
(*                                                                           *)
(*  This is parse- and print-time code only, unreachable from the Wasm       *)
(*  entry point, so it is free to use Z and the decimal representation.      *)
(*****************************************************************************)

(* Require without Import: Decimal.abs and Decimal.int would shadow ours. *)
From Corelib Require Init.Number Init.Decimal.

Definition scaleZ : Z := 16777216.                  (* 2^24 *)
Definition five_pow_q : Z := 59604644775390625.     (* 5^24 *)
Definition limitZ : Z := 4611686018427387904.       (* 2^62, exclusive bound *)

(* Digits come most-significant first, so reading a uint needs an
   accumulator and writing one prepends. *)
Fixpoint uint_to_Z_acc (acc : Z) (u : Decimal.uint) : Z :=
  match u with
  | Decimal.Nil => acc
  | Decimal.D0 u' => uint_to_Z_acc (acc * 10)     u'
  | Decimal.D1 u' => uint_to_Z_acc (acc * 10 + 1) u'
  | Decimal.D2 u' => uint_to_Z_acc (acc * 10 + 2) u'
  | Decimal.D3 u' => uint_to_Z_acc (acc * 10 + 3) u'
  | Decimal.D4 u' => uint_to_Z_acc (acc * 10 + 4) u'
  | Decimal.D5 u' => uint_to_Z_acc (acc * 10 + 5) u'
  | Decimal.D6 u' => uint_to_Z_acc (acc * 10 + 6) u'
  | Decimal.D7 u' => uint_to_Z_acc (acc * 10 + 7) u'
  | Decimal.D8 u' => uint_to_Z_acc (acc * 10 + 8) u'
  | Decimal.D9 u' => uint_to_Z_acc (acc * 10 + 9) u'
  end%Z.

Definition uint_to_Z (u : Decimal.uint) : Z := uint_to_Z_acc 0 u.

(* the magnitude and the sign of a signed decimal integer: -0.5 arrives as
   Neg (D0 Nil) with the 5 in the fractional part, so the sign has to come
   from the constructor rather than from the value *)
Definition int_mag (i : Decimal.int) : Z :=
  match i with Decimal.Pos u => uint_to_Z u | Decimal.Neg u => uint_to_Z u end.
Definition int_is_neg (i : Decimal.int) : bool :=
  match i with Decimal.Pos _ => false | Decimal.Neg _ => true end.

(* num/den -> raw, truncating towards zero; None when out of range *)
Definition of_ratio (sgn : bool) (num den : Z) : option t :=
  if Z.eqb den 0 then None else
  let m := Z.div (num * scaleZ)%Z den in
  if Z.ltb m limitZ then
    let r := Uint63.of_Z m in Some (if sgn then neg r else r)
  else None.

Definition of_decimal (d : Decimal.decimal) : option t :=
  match d with
  | Decimal.Decimal i f =>
      let den := Z.pow 10 (Z.of_nat (Decimal.nb_digits f)) in
      of_ratio (int_is_neg i) (int_mag i * den + uint_to_Z f)%Z den
  | Decimal.DecimalExp i f e =>
      let den := Z.pow 10 (Z.of_nat (Decimal.nb_digits f)) in
      let num := (int_mag i * den + uint_to_Z f)%Z in
      let ez := int_mag e in
      if int_is_neg e
      then of_ratio (int_is_neg i) num (den * Z.pow 10 ez)%Z
      else of_ratio (int_is_neg i) (num * Z.pow 10 ez)%Z den
  end.

Definition of_number (n : Number.number) : option t :=
  match n with
  | Number.Decimal d => of_decimal d
  | Number.Hexadecimal _ => None
  end.

Definition digit_cons (d : Z) (u : Decimal.uint) : Decimal.uint :=
  match d with
  | 1 => Decimal.D1 u | 2 => Decimal.D2 u | 3 => Decimal.D3 u
  | 4 => Decimal.D4 u | 5 => Decimal.D5 u | 6 => Decimal.D6 u
  | 7 => Decimal.D7 u | 8 => Decimal.D8 u | 9 => Decimal.D9 u
  | _ => Decimal.D0 u
  end%Z.

(* n as decimal digits, no leading zeros (0 prints as "0") *)
Fixpoint z_to_uint (fuel : nat) (n : Z) (acc : Decimal.uint) : Decimal.uint :=
  match fuel with
  | O => acc
  | S fuel' =>
      if Z.eqb n 0 then (match acc with Decimal.Nil => Decimal.D0 Decimal.Nil | _ => acc end)
      else z_to_uint fuel' (Z.div n 10) (digit_cons (Z.modulo n 10) acc)
  end.

(* exactly [width] digits, leading zeros kept: a fractional part *)
Fixpoint frac_to_uint (width : nat) (n : Z) (acc : Decimal.uint) : Decimal.uint :=
  match width with
  | O => acc
  | S w => frac_to_uint w (Z.div n 10) (digit_cons (Z.modulo n 10) acc)
  end.

(* drop trailing zeros of a width-digit fractional part *)
Fixpoint trim_zeros (fuel : nat) (n : Z) (width : nat) : Z * nat :=
  match fuel, width with
  | O, _ | _, O => (n, width)
  | S fuel', S w => if Z.eqb (Z.modulo n 10) 0 then trim_zeros fuel' (Z.div n 10) w
                    else (n, width)
  end.

(* The printer takes an int_wrapper rather than a t: that is how a Number
   Notation prints a primitive type (see Sint63.printer). *)
Definition to_number (w : int_wrapper) : option Number.number :=
  let x := int_wrap w in
  if Uint63.eqb x min_val then None else
  let s := is_neg x in
  let m := Uint63.to_Z (abs x) in
  let ip := Z.div m scaleZ in
  let fp := Z.modulo m scaleZ in
  let (fv, w) := trim_zeros 24 (fp * five_pow_q)%Z 24 in
  let ipu := z_to_uint 32 ip Decimal.Nil in
  Some (Number.Decimal
          (Decimal.Decimal (if s then Decimal.Neg ipu else Decimal.Pos ipu)
                           (frac_to_uint w fv Decimal.Nil))).

Number Notation int of_number to_number : fixed_scope.

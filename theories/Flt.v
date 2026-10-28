(*****************************************************************************)
(*  The scalar layer: primitive floats                                       *)
(*                                                                           *)
(*  The renderer computes in [Corelib.Floats.PrimFloat.float], IEEE 754      *)
(*  binary64, which is what the Lean original it is ported from uses.  This  *)
(*  file is what is left of the old [Fixed.v]: PrimFloat covers every        *)
(*  operation the scene needs but three, so what remains here is             *)
(*                                                                           *)
(*    - [min] and [max], which PrimFloat does not have;                      *)
(*    - [trunc_byte], the one place a float becomes an integer;              *)
(*                                                                           *)
(*  plus the names the rest of [theories/] calls the primitives by.          *)
(*                                                                           *)
(*  Those names are abbreviations rather than wrappers on purpose.  A        *)
(*  backend recognises a primitive by the kername at the application site,   *)
(*  so an abbreviation keeps every call site literally [PrimFloat.add];      *)
(*  a [Definition add := PrimFloat.add] would instead put a constant whose   *)
(*  body is the primitive between the two.                                   *)
(*                                                                           *)
(*  PrimFloat is Exported, not just Imported: that is where the decimal      *)
(*  literals of [float_scope] and its infix operators come from, so every    *)
(*  file that computes in floats gets them by requiring this one.  It is     *)
(*  what the old [Fixed.FixedNotations] and the hand-written Number          *)
(*  Notation of [Fixed.v] stood in for -- both are now the kernel's.         *)
(*****************************************************************************)

From Corelib Require Export PrimFloat.
From Stdlib Require Import Uint63.

Definition t : Set := float.

(* so that an unannotated literal in a [t] position -- a [vec3] component,
   a [knobs] field -- is read as a float even where [float_scope] is not
   open; [Bind Scope] keys on the head constant, and [t] is not [float] *)
Bind Scope float_scope with t.

(** ** The primitives, under the names the renderer uses

    Eleven of PrimFloat's nineteen.  Nine of them reach the extracted
    module: [leb] and [eqb] are used only in [Proofs.v] and [Tests.v].  The
    arithmetic ones mostly arrive through the infix notations of
    [float_scope] rather than through the names below. *)

Notation add := PrimFloat.add.     (* #float64_add *)
Notation sub := PrimFloat.sub.     (* #float64_sub *)
Notation mul := PrimFloat.mul.     (* #float64_mul *)
Notation div := PrimFloat.div.     (* #float64_div *)
Notation neg := PrimFloat.opp.     (* #float64_opp *)
Notation abs := PrimFloat.abs.     (* #float64_abs *)
Notation sqrt := PrimFloat.sqrt.   (* #float64_sqrt *)
Notation ltb := PrimFloat.ltb.     (* #float64_lt *)
Notation leb := PrimFloat.leb.     (* #float64_le *)
Notation eqb := PrimFloat.eqb.     (* #float64_eq *)

(** Non-negative integer counts -- pixel coordinates, the width and the
    height, the sample count -- as floats.  [of_uint63] is the only
    conversion PrimFloat has, and it goes this way only. *)
Notation of_int := PrimFloat.of_uint63.   (* #float64_of_uint63 *)

(** The sentinel the hit tests start from: no intersection is ever further
    away than this, which is what the fixed-point port had to spell
    [Fixed.max_val] for want of an infinity. *)
Notation infinity := PrimFloat.infinity.

(** ** Minimum and maximum

    Deliberately [if ltb] rather than anything resembling Wasm's [f64.min]
    and [f64.max]: those return a canonical NaN when either argument is
    NaN and have their own rule for signed zero, where a comparison and a
    select have neither wrinkle.  Comparisons also allocate nothing. *)

Definition min (x y : t) : t := if PrimFloat.ltb x y then x else y.
Definition max (x y : t) : t := if PrimFloat.ltb x y then y else x.

(** ** Truncation towards zero of a value in [0, 256)

    The only float-to-int conversion in the renderer: [Render.channel_byte]
    turns a clamped colour channel into one of the 256 byte values.

    PrimFloat has no truncation primitive.  The general route is
    [frshiftexp] and [normfr_mantissa] followed by an int63 shift, but
    those are two more primitives for a backend to implement -- and the two
    whose implementation has to reason about NaN payloads rather than just
    reinterpret the bits.  Since the only value ever converted is already
    known to lie in [0, 256), a binary search on the eight bits does it
    with nothing but [ltb], [sub] and float constants.

    It is exact.  Every step holds [r < 2 * p] on entry for a power of two
    [p] -- [x < 256 = 2 * 128] to begin with, and each step leaves [r]
    below the next [p] -- and it subtracts only when [p <= r], so
    Sterbenz's lemma applies and [r - p] loses nothing.  After eight steps
    [acc] is [floor x] and [r] is the fraction that was dropped.
    [Proofs.v] proves [acc] is a byte. *)

Fixpoint peel (n : nat) (p : t) (k : int) (r : t) (acc : int) : int :=
  match n with
  | O => acc
  | S n' =>
      let p' := PrimFloat.div p 2 in
      let k' := Uint63.lsr k 1 in
      if PrimFloat.ltb r p
      then peel n' p' k' r acc
      else peel n' p' k' (PrimFloat.sub r p) (Uint63.lor acc k)
  end.

Definition trunc_byte (x : t) : int := peel 8 128 128 x 0.

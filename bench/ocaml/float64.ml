(* The binary64 primitives, for the OCaml extraction of theories/.
 *
 * The companion to uint63.ml, and the shorter half: a Rocq primitive float
 * is an OCaml float, so every operation here is one OCaml operator.  These
 * are the definitions of kernel/float64.ml and kernel/float64_common.ml,
 * which is what makes the extracted renderer a fair thing to time -- an
 * arithmetic operation in theories/ is one machine instruction here, as it
 * should be in the Wasm module when the backend accepts floats.
 *
 * The [(x : float)] annotations on the comparisons are not decoration.
 * Without them OCaml uses polymorphic structural comparison, which is both
 * much slower and *wrong* for this purpose: it orders nan rather than
 * returning false.  The annotation picks the IEEE comparison, under which
 * nan compares false against everything -- which is what PrimFloat.ltb
 * specifies, and what theories/Flt.v's min and max are built to rely on.
 *
 * Only the ten operations the renderer reaches are here.  Nothing needs
 * Float64.le or Float64.eq: the extracted module does not contain them,
 * which is the same finding the Wasm quoting reported -- PrimFloat.leb and
 * PrimFloat.eqb are used only in Proofs.v and Tests.v. *)

type t = float

(* extraction emits every float literal as [Float64.of_float 0x1p+7]: a
   hexadecimal literal, so the constant in the generated OCaml is bit for
   bit the one the Rocq kernel had *)
let of_float (f : float) : t = f
[@@ocaml.inline always]

let opp = ( ~-. )
let abs = abs_float

let add (x : float) (y : float) : float = x +. y
[@@ocaml.inline always]

let sub (x : float) (y : float) : float = x -. y
[@@ocaml.inline always]

let mul (x : float) (y : float) : float = x *. y
[@@ocaml.inline always]

let div (x : float) (y : float) : float = x /. y
[@@ocaml.inline always]

let sqrt (x : float) : float = Stdlib.sqrt x
[@@ocaml.inline always]

let lt (x : float) (y : float) = x < y
[@@ocaml.inline always]

let le (x : float) (y : float) = x <= y
[@@ocaml.inline always]

let eq (x : float) (y : float) = x = y
[@@ocaml.inline always]

let of_uint63 x = Uint63.to_float x
[@@ocaml.inline always]

(* The kernel's own startup check, kept: it catches a host that keeps
   intermediates in x87's 80-bit registers, which would double-round and
   make every number in the benchmark meaningless. *)
let () =
  let b = ldexp 1. 53 in
  let s = add 1. (ldexp 1. (-52)) in
  if add b s <= b || add b 1. <> b || ldexp 1. (-1074) <= 0. then
    failwith "Detected non IEEE-754 compliant architecture (or wrong \
              rounding mode). Use of Float is thus unsafe."

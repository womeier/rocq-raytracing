(* The int63 primitives, for the OCaml extraction of theories/.
 *
 * Rocq's own extraction (Stdlib.extraction.ExtrOCamlInt63) maps
 * [Uint63.int] and its operations onto a module called [Uint63], which in
 * the Rocq tree is kernel/uint63_63.ml and reaches the linker as part of
 * rocq-runtime.kernel.  Linking that here would pull the whole kernel --
 * dynlink, the bytecode VM, the boot path -- into a benchmark binary, and
 * one of its operations ([to_float]) is a C stub, so the build would need
 * the stublibs too.
 *
 * So this file is the twenty-odd lines of it the renderer actually uses,
 * transcribed from kernel/uint63_63.ml.  Every definition below is the
 * kernel's, including the two tricks that are easy to get wrong:
 *
 *   - an int63 is an OCaml [int] with no masking.  OCaml's int is exactly
 *     63 bits wide on a 64-bit host, so +, - and * already wrap mod 2^63
 *     and the bit pattern *is* the int63 value.
 *   - comparison is unsigned, which [<] on OCaml ints is not.  Flipping
 *     the top bit of both sides (the hex literal below is 2^62, which as
 *     an OCaml int literal wraps to -2^62) turns the signed comparison
 *     into the unsigned one.
 *
 * [to_float] is the one thing not transcribed, since the kernel's is a C
 * stub: it is written out here, with the non-negative case -- every call
 * the renderer makes -- as a single conversion.
 *
 * bench/ocaml/main.ml --check renders the corner that theories/Tests.v
 * pins down by conversion, which is what says this file agrees with the
 * kernel it stands in for. *)

type t = int

let () = assert (Sys.word_size = 64)

let of_int (i : int) : t = i
[@@ocaml.inline always]

(* logical shift; out-of-range shift counts give zero, as in the kernel *)
let l_sr x y = if 0 <= y && y < 63 then x lsr y else 0

let l_and x y = x land y
[@@ocaml.inline always]

let l_or x y = x lor y
[@@ocaml.inline always]

let l_xor x y = x lxor y
[@@ocaml.inline always]

let add x y = x + y
[@@ocaml.inline always]

let sub x y = x - y
[@@ocaml.inline always]

let mul x y = x * y
[@@ocaml.inline always]

let maxuint63 = Int64.of_string "0x7FFFFFFFFFFFFFFF"
let to_uint64 i = Int64.logand (Int64.of_int i) maxuint63

(* unsigned division, and division by zero is zero -- the total operation
   Rocq's Uint63.div is *)
let div (x : int) (y : int) =
  if y = 0 then 0 else Int64.to_int (Int64.div (to_uint64 x) (to_uint64 y))

let rem (x : int) (y : int) =
  if y = 0 then x else Int64.to_int (Int64.rem (to_uint64 x) (to_uint64 y))

let equal (x : int) (y : int) = x = y
[@@ocaml.inline always]

let lt (x : int) (y : int) =
  (x lxor 0x4000000000000000) < (y lxor 0x4000000000000000)
[@@ocaml.inline always]

let le (x : int) (y : int) =
  (x lxor 0x4000000000000000) <= (y lxor 0x4000000000000000)
[@@ocaml.inline always]

(* What Flt.of_int compiles to: the unsigned value of the word, rounded to
   the nearest binary64.  The renderer only ever converts non-negative
   quantities -- pixel coordinates, the width and the height, the sample
   count, and the top 53 bits of a generator word -- so the first branch is
   the one that runs, and it is one cvtsi2sd.  The second is correct for
   the rest of the range, where the word's top bit makes the OCaml int
   negative and the value is 2^63 larger than it looks. *)
let to_float (i : int) : float =
  if i >= 0 then float_of_int i else Int64.to_float (to_uint64 i)

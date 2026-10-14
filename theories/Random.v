(*****************************************************************************)
(*  Pseudo-random numbers                                                    *)
(*                                                                           *)
(*  The Lean original draws its randomness from IO (IO.randFloat and the     *)
(*  friends built on it).  Rocq has no IO, so the generator state is an      *)
(*  int63 threaded through every function that samples: a function that      *)
(*  returned a in Lean returns a pair (a, state) here.                       *)
(*                                                                           *)
(*  The generator is SplitMix: the state advances by the golden-ratio        *)
(*  increment and the output is an avalanche mix of it.  That makes the      *)
(*  stream of a pixel a pure function of the pixel's coordinates, so the     *)
(*  image does not depend on how the work is cut into jobs.  The constants   *)
(*  are the SplitMix64 ones reduced mod 2^63, the word size here.            *)
(*****************************************************************************)

From Stdlib Require Import Uint63.
From Raytracing Require Import Fixed Vec3.

Open Scope uint63_scope.

Definition golden : int := 2177342782468422677.   (* 0x9E3779B97F4A7C15 mod 2^63 *)
Definition mix1   : int := 4564476756301768121.   (* 0xBF58476D1CE4E5B9 mod 2^63 *)
Definition mix2   : int := 1499779743744070123.   (* 0x94D049BB133111EB mod 2^63 *)

Definition mix (x : int) : int :=
  let z := (x lxor (x >> 30)) * mix1 in
  let z := (z lxor (z >> 27)) * mix2 in
  z lxor (z >> 31).

(* the state of a pixel's stream, from the scene seed and the pixel *)
Definition seed_at (seed x y : int) : int := mix (seed + mix (x + mix y)).

Definition next (s : int) : int * int :=
  let s' := s + golden in (mix s', s').

(** Uniform in [0, 1): the top 24 bits of the output are the fractional
    bits of the result. *)
Definition unit_fx (s : int) : Fixed.t * int :=
  let (r, s') := next s in (r >> 39, s').

Import Fixed.FixedNotations.
Open Scope fixed_scope.

(** Uniform in [lo, hi). *)
Definition range (lo hi : Fixed.t) (s : int) : Fixed.t * int :=
  let (u, s1) := unit_fx s in (lo + (hi - lo) * u, s1).

Definition vec_range (lo hi : Fixed.t) (s : int) : vec3 * int :=
  let (x, s1) := range lo hi s in
  let (y, s2) := range lo hi s1 in
  let (z, s3) := range lo hi s2 in
  (V3 x y z, s3).

(* Rejection sampling, as in the original; the Lean version tries 100 times
   and falls back to (1,0,0), here the fuel is explicit. *)
Fixpoint in_unit_sphere_fuel (n : nat) (s : int) : vec3 * int :=
  match n with
  | O => (V3 1 0 0, s)
  | S n' =>
      let (p, s1) := vec_range (-1) 1 s in
      if Fixed.ltb (Vec3.length_squared p) 1 then (p, s1)
      else in_unit_sphere_fuel n' s1
  end.

Definition in_unit_sphere (s : int) : vec3 * int := in_unit_sphere_fuel 32 s.

Fixpoint in_unit_disk_fuel (n : nat) (s : int) : vec3 * int :=
  match n with
  | O => (V3 0 0 0, s)
  | S n' =>
      let (x, s1) := range (-1) 1 s in
      let (y, s2) := range (-1) 1 s1 in
      let p := V3 x y 0 in
      if Fixed.ltb (Vec3.length_squared p) 1 then (p, s2)
      else in_unit_disk_fuel n' s2
  end.

Definition in_unit_disk (s : int) : vec3 * int := in_unit_disk_fuel 32 s.

(******************************************************************************)
(*  OCaml extraction, for benchmarking                                        *)
(*                                                                            *)
(*  The same renderer as extraction.v, through Rocq's own extraction rather   *)
(*  than CertiRocq's Wasm backend.  Two reasons for it to exist:              *)
(*                                                                            *)
(*   - the Wasm backend does not accept primitive floats yet, so this is the  *)
(*     only way to run the float port at speed and to measure it;             *)
(*   - it separates the two things the Wasm number conflates.  A render       *)
(*     through the Wasm module is the cost of the algorithm plus the cost of  *)
(*     that backend's calling convention, its boxing and its allocator; the   *)
(*     OCaml one is the algorithm with a mature backend under it.  The ratio  *)
(*     between them is the backend's overhead, which is the figure worth      *)
(*     knowing when the Wasm build comes back.                                *)
(*                                                                            *)
(*  The primitives go to the kernel's own implementations (Uint63 and         *)
(*  Float64 of rocq-runtime), which is what makes this a fair measurement:    *)
(*  Float64.add and the rest are [@@inline always] wrappers on OCaml's        *)
(*  +. -. *. /. and sqrt, so an extracted arithmetic operation is one         *)
(*  machine instruction, exactly as the Wasm one should be.                   *)
(*                                                                            *)
(*  [nat] is left as unary Peano on purpose, which is what CertiRocq          *)
(*  compiles; ExtrOcamlNatInt would make the sample and bounce counters       *)
(*  machine integers and measure a different program.                         *)
(******************************************************************************)

From Stdlib Require Import Uint63 List Strings.Byte.
From Stdlib Require Extraction.
From Stdlib Require Import ExtrOcamlBasic ExtrOcamlChar
                           ExtrOCamlInt63 ExtrOCamlFloats.
From Raytracing Require Import Flt Vec3 Random Scene Trig Render.

(* Uint63 and Float64 are the kernel modules the directives above point at;
   List and Nat would shadow OCaml's. *)
Extraction Blacklist Uint63 Float64 List Nat Byte String.

(* The Makefile's [ocaml] target creates this directory before compiling the
   file, and bench/ocaml/build.sh turns what lands in it into a binary. *)
Set Extraction Output Directory "bench/ocaml".

(* The three entry points the hosts use, and the records to build their
   arguments with -- extraction emits the type definitions alongside, so the
   driver constructs a [config] and a [job] as plain OCaml records. *)
Extraction "raytracer.ml"
  Render.render Render.prepare Render.ppm_header
  Scene.default_knobs Scene.scene_knobs.

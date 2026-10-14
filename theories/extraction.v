(******************************************************************************)
(*  Wasm extraction via CertiRocq                                             *)
(*                                                                            *)
(*    api_header  : config -> list byte       the PPM header                  *)
(*    api_prepare : config -> scene_data      the world and the camera        *)
(*    api_render  : scene_data * job -> list byte                             *)
(*                                            one span of one row, three      *)
(*                                            bytes per pixel                 *)
(*                                                                            *)
(*  Both entry points sit in one record so that a single Wasm module holds    *)
(*  the whole renderer, sharing one linear memory.  The host (src/index.js    *)
(*  in the browser) builds the config and job blocks, calls api_render once   *)
(*  per span, and resets the allocation pointer in between.                   *)
(******************************************************************************)

From Stdlib Require Import Uint63 List Strings.Byte.
From Raytracing Require Import Fixed Vec3 Random Scene Trig Render.
From CertiRocq.Plugin Require Import CertiRocq.

Import ListNotations.
Open Scope uint63_scope.

(* A 4x2 corner of the first-light scene, to see that the pipeline computes
   before it is compiled. *)
Definition demo_cfg : config := MkConfig 4 2 1 1 1 0 default_knobs.
Eval vm_compute in (ppm_header demo_cfg).
Eval vm_compute in (render (prepare demo_cfg, MkJob demo_cfg 0 0 4)).

Record wasm_api : Set := MkWasmApi {
  api_render  : scene_data * job -> list byte;
  api_prepare : config -> scene_data;
  api_header  : config -> list byte
}.

Definition raytracer_wasm_api : wasm_api :=
  {| api_render  := render;
     api_prepare := prepare;
     api_header  := ppm_header |}.

CertiRocq Compile Wasm raytracer_wasm_api.

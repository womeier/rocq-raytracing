(******************************************************************************)
(*  Rendering and PPM output                                                  *)
(*                                                                            *)
(*  The Lean original renders the whole image in one go, writing a P3 (ASCII) *)
(*  PPM file.                                                                 *)
(*  CertiRocq's Wasm backend has no garbage collector, and                    *)
(*  the whole image usually doesn't fit the 2GB of Wasm's linear memory.      *)
(*  Thus, the image is split into jobs consisting of a group of pixels each   *)
(*  (typically multiple jobs per row of the final image),                     *)
(*  the pixel groups are combined to an image in JavaScript.                  *)
(*                                                                            *)
(******************************************************************************)

From Stdlib Require Import Uint63 List Strings.Byte.
From Raytracing Require Import Flt Vec3 Random Scene Trig.

Import ListNotations.
Open Scope uint63_scope.

(** ** Jobs *)

Record config : Set := MkConfig {
  cfg_width   : int;
  cfg_height  : int;
  cfg_samples : int;
  cfg_depth   : int;
  cfg_seed    : int;
  cfg_scene   : int;   (* 0: first light, 1: the weekend scene, otherwise: adjustable *)
  cfg_knobs   : knobs  (* camera and the movable sphere (Scene.v) *)
}.

(* The world and the camera of a configuration.  The host builds this once
   and hands it back with every job: without a garbage collector the only
   way to free a job's allocations is to reset the allocation pointer, and
   anything built before the host takes its watermark survives that.  The
   alternative, rebuilding the scene inside each call, costs both the build
   and about 18 MB of linear memory per call. *)
Record scene_data : Set := MkSceneData {
  sd_world : list hittable;
  sd_cam   : camera
}.

Record job : Set := MkJob {
  job_cfg   : config;
  job_y     : int;     (* row, 0 is the top one *)
  job_x0    : int;     (* first column of the span *)
  job_count : int      (* how many pixels *)
}.

(* The recursion bounds are nats, the configuration is int63 (which is what
   the host can hand over cheaply), so the counts are converted.  The fuel
   is also the largest accepted value. *)
Fixpoint nat_of_int_fuel (fuel : nat) (n : int) : nat :=
  match fuel with
  | O => O
  | S fuel' => if n =? 0 then O else S (nat_of_int_fuel fuel' (n - 1))
  end.

Definition max_count : nat := 4096.
Definition nat_of_int (n : int) : nat := nat_of_int_fuel max_count n.

(** ** Bytes *)

Definition bit (n i : int) : bool := negb ((n >> i) land 1 =? 0).

Definition byte_of_int (n : int) : byte :=
  Byte.of_bits (bit n 0, (bit n 1, (bit n 2, (bit n 3,
               (bit n 4, (bit n 5, (bit n 6, bit n 7))))))).

Definition nl : byte := "010"%byte.   (* 0x0a *)
Definition sp : byte := " "%byte.

(* the decimal digits of n, most significant first *)
Fixpoint digits_fuel (fuel : nat) (n : int) (acc : list byte) : list byte :=
  match fuel with
  | O => acc
  | S fuel' =>
      let d := byte_of_int (48 + (n mod 10)) in
      if n <? 10 then d :: acc else digits_fuel fuel' (n / 10) (d :: acc)
  end.

Definition digits (n : int) : list byte := digits_fuel 24 n [].

(** The header of a binary (P6) PPM file: "P6\n<width> <height>\n255\n".
    The pixel bytes of the rows, top row first, follow it. *)
Definition ppm_header (cfg : config) : list byte :=
  ["P"%byte; "6"%byte; nl]
    ++ digits (cfg_width cfg) ++ [sp] ++ digits (cfg_height cfg) ++ [nl]
    ++ ["2"%byte; "5"%byte; "5"%byte; nl].

(** ** Pixels *)

Open Scope float_scope.

(* A channel of the accumulated colour as a byte.  gamma = 2, i.e. the
   square root, as in the original.  The clamp puts the scaled value in
   [0, 256), which is the range Flt.trunc_byte -- the renderer's one
   float-to-int conversion -- is built for. *)
Definition channel_byte (gamma : bool) (v : Flt.t) : byte :=
  let s := if gamma then Flt.sqrt v else v in
  byte_of_int (Flt.trunc_byte (256 * Flt.min (Flt.max s 0) 0.999999)).

Definition color_bytes (gamma : bool) (c : color) : list byte :=
  [channel_byte gamma (vx c); channel_byte gamma (vy c); channel_byte gamma (vz c)].

(* One supersampling pass per step, jittered inside the pixel. *)
Fixpoint sample_loop (n depth : nat) (world : list hittable) (cam : camera)
                     (xf yf wf hf : Flt.t) (acc : color) (g : int)
                     : color * int :=
  match n with
  | O => (acc, g)
  | S n' =>
      let (du, g1) := Random.unit_flt g in
      let (dv, g2) := Random.unit_flt g1 in
      let u := (xf + du) / wf in
      let v := (yf + dv) / hf in
      let (r, g3) := Scene.camera_ray cam u v g2 in
      let (c, g4) := Scene.ray_color world depth r Vec3.white g3 in
      sample_loop n' depth world cam xf yf wf hf (Vec3.add acc c) g4
  end.

Definition pixel_weekend (cfg : config) (world : list hittable) (cam : camera)
                         (x y : int) : list byte :=
  let samples := Uint63.max 1 (cfg_samples cfg) in
  (* v runs bottom-up, y from the top *)
  let j := (cfg_height cfg - 1 - y)%uint63 in
  let (sum, _) :=
    sample_loop (nat_of_int samples) (nat_of_int (cfg_depth cfg)) world cam
      (Flt.of_int x) (Flt.of_int j)
      (Flt.of_int (cfg_width cfg)) (Flt.of_int (cfg_height cfg))
      Vec3.black (Random.seed_at (cfg_seed cfg) x y) in
  color_bytes true (Vec3.divs sum (Flt.of_int samples)).

(* The first-light scene: no sampling, no bounces, and no gamma -- the
   colour is the surface normal, which gamma would only wash out. *)
Definition pixel_trace (cfg : config) (world : list hittable) (x y : int) : list byte :=
  let u := Flt.of_int x / Flt.of_int (cfg_width cfg) in
  let v := Flt.of_int (cfg_height cfg - 1 - y)%uint63 / Flt.of_int (cfg_height cfg) in
  color_bytes false (Scene.trace_color world u v).

(** ** Jobs *)

Fixpoint span_loop (n : nat) (f : int -> list byte) (x : int) : list byte :=
  match n with
  | O => []
  | S n' => f x ++ span_loop n' f (x + 1)%uint63
  end.

(* Every scene but the first-light one is viewed through the same camera,
   which the knobs describe; the defaults are the book's. *)
Definition config_camera (cfg : config) : camera :=
  let aspect := Flt.of_int (cfg_width cfg) / Flt.of_int (cfg_height cfg) in
  Scene.knob_camera (cfg_knobs cfg) aspect.

(** The world and the camera of a configuration, built once. *)
Definition prepare (cfg : config) : scene_data :=
  if (cfg_scene cfg =? 0)%uint63
  then MkSceneData [Scene.trace_sphere] (config_camera cfg)  (* camera unused *)
  else if (cfg_scene cfg =? 1)%uint63
  then let (world, _) := Scene.scene_weekend (cfg_seed cfg) in
       MkSceneData world (config_camera cfg)
  else MkSceneData (Scene.scene_knobs (cfg_knobs cfg)) (config_camera cfg).

Definition render (p : scene_data * job) : list byte :=
  let (sd, j) := p in
  let cfg := job_cfg j in
  let n := nat_of_int (job_count j) in
  if (cfg_scene cfg =? 0)%uint63
  then span_loop n (fun x => pixel_trace cfg (sd_world sd) x (job_y j)) (job_x0 j)
  else span_loop n
         (fun x => pixel_weekend cfg (sd_world sd) (sd_cam sd) x (job_y j))
         (job_x0 j).

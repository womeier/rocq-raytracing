(*****************************************************************************)
(*  Rays, camera, materials, spheres, and the recursive ray colour           *)
(*                                                                           *)
(*  A port of Main.lean from kmill/lean4-raytracer (which follows Ray        *)
(*  Tracing in One Weekend), with the simple normal-shaded scene of          *)
(*  TOTBWF/lean4-raytrace as a second, cheap scene.                          *)
(*                                                                           *)
(*  Two systematic differences from the Lean code:                           *)
(*   - the component type is Fixed.t, not Float (see Fixed.v);               *)
(*   - sampling functions take and return a generator state instead of       *)
(*     living in IO (see Random.v).                                          *)
(*****************************************************************************)

From Stdlib Require Import Uint63 List.
From Raytracing Require Import Fixed Trig Vec3 Random.

Import ListNotations.
Import Fixed.FixedNotations.
Open Scope fixed_scope.

(** ** Rays *)

Record ray : Set := MkRay { ray_origin : vec3; ray_dir : vec3 }.

Definition ray_at (r : ray) (t : Fixed.t) : vec3 :=
  Vec3.add (ray_origin r) (Vec3.scale t (ray_dir r)).

(** ** Camera

    vfov enters as half_height = tan(vfov/2), computed by Trig.tan_deg at
    the scene level; the camera itself only ever needs that number. *)

Record camera : Set := MkCamera {
  cam_origin      : vec3;
  cam_lower_left  : vec3;
  cam_horizontal  : vec3;
  cam_vertical    : vec3;
  cam_u           : vec3;   (* right *)
  cam_v           : vec3;   (* up *)
  cam_w           : vec3;   (* back *)
  cam_lens_radius : Fixed.t
}.

Definition camera_make (lookfrom lookat vup : vec3)
                       (half_height aspect aperture focus_dist : Fixed.t) : camera :=
  let viewport_height := 2 * half_height in
  let viewport_width := aspect * viewport_height in
  let w := Vec3.normalized (Vec3.sub lookfrom lookat) in
  let u := Vec3.normalized (Vec3.cross vup w) in
  let v := Vec3.cross w u in
  let horizontal := Vec3.scale (focus_dist * viewport_width) u in
  let vertical := Vec3.scale (focus_dist * viewport_height) v in
  let lower_left :=
    Vec3.sub (Vec3.sub (Vec3.sub lookfrom (Vec3.divs horizontal 2))
                       (Vec3.divs vertical 2))
             (Vec3.scale focus_dist w) in
  MkCamera lookfrom lower_left horizontal vertical u v w (aperture / 2).

Definition camera_ray (c : camera) (s t : Fixed.t) (g : int) : ray * int :=
  let (rd0, g1) := Random.in_unit_disk g in
  let rd := Vec3.scale (cam_lens_radius c) rd0 in
  let offset := Vec3.add (Vec3.scale (vx rd) (cam_u c))
                         (Vec3.scale (vy rd) (cam_v c)) in
  (MkRay (Vec3.add (cam_origin c) offset)
         (Vec3.sub (Vec3.sub (Vec3.add (Vec3.add (cam_lower_left c)
                                                 (Vec3.scale s (cam_horizontal c)))
                                       (Vec3.scale t (cam_vertical c)))
                             (cam_origin c))
                   offset),
   g1).

(** ** Materials *)

Inductive material : Set :=
  | Lambertian (albedo : color)
  | Metal (albedo : color) (fuzz : Fixed.t)
  | Dielectric (index_of_refraction : Fixed.t)
  | Sky.

Inductive material_response : Set :=
  | Emit (c : color)
  | Scatter (albedo : color) (scattered : ray).

Definition absorb : material_response := Emit Vec3.black.

Record hit_record : Set := MkHit {
  hit_p          : vec3;
  hit_t          : Fixed.t;
  hit_material   : material;
  hit_normal     : vec3;
  hit_front_face : bool
}.

Definition hit_with_normal (p : vec3) (t : Fixed.t) (m : material)
                           (dir outward_normal : vec3) : hit_record :=
  let front := Fixed.ltb (Vec3.dot dir outward_normal) 0 in
  MkHit p t m (if front then outward_normal else Vec3.neg outward_normal) front.

Definition pow5 (x : Fixed.t) : Fixed.t := let x2 := x * x in x2 * x2 * x.

Definition scatter (h : hit_record) (r : ray) (g : int) : material_response * int :=
  match hit_material h with
  | Lambertian albedo =>
      let (p, g1) := Random.in_unit_sphere g in
      let dir0 := Vec3.add (hit_normal h) (Vec3.normalized p) in
      let dir := if Vec3.near_zero dir0 then hit_normal h else dir0 in
      (Scatter albedo (MkRay (hit_p h) dir), g1)
  | Metal albedo fuzz =>
      let reflected := Vec3.reflect (Vec3.normalized (ray_dir r)) (hit_normal h) in
      let (p, g1) := Random.in_unit_sphere g in
      let scattered := MkRay (hit_p h) (Vec3.add reflected (Vec3.scale fuzz p)) in
      (if Fixed.ltb 0 (Vec3.dot (ray_dir scattered) (hit_normal h))
       then Scatter albedo scattered
       else absorb, g1)
  | Dielectric ir =>
      let ratio := if hit_front_face h then 1 / ir else ir in
      let unit_dir := Vec3.normalized (ray_dir r) in
      let cos_theta := Fixed.min (- Vec3.dot unit_dir (hit_normal h)) 1 in
      let sin_theta := Fixed.sqrt (1 - cos_theta * cos_theta) in
      let cannot_refract := Fixed.ltb 1 (ratio * sin_theta) in
      (* Schlick's approximation *)
      let r0' := (1 - ratio) / (1 + ratio) in
      let r0 := r0' * r0' in
      let reflectance := r0 + (1 - r0) * pow5 (1 - cos_theta) in
      let (u, g1) := Random.unit_fx g in
      let dir := if orb cannot_refract (Fixed.ltb u reflectance)
                 then Vec3.reflect unit_dir (hit_normal h)
                 else Vec3.refract unit_dir (hit_normal h) ratio in
      (Scatter Vec3.white (MkRay (hit_p h) dir), g1)
  | Sky =>
      let unit := Vec3.normalized (ray_dir r) in
      let t := 0.5 * (vy unit + 1) in
      (Emit (Vec3.add (Vec3.scale (1 - t) Vec3.white)
                      (Vec3.scale t (Vec3.rgb 0.5 0.7 1))), g)
  end.

(** ** Spheres *)

Inductive hittable : Set := Sphere (center : vec3) (radius : Fixed.t) (mat : material).

(* Keeps the closest hit so far in [h], exactly like the Lean version:
   a miss returns [h] unchanged. *)
Definition hit (obj : hittable) (r : ray) (a : Fixed.t) (tmin : Fixed.t)
               (h : hit_record) : hit_record :=
  match obj with
  | Sphere center radius m =>
      let oc := Vec3.sub (ray_origin r) center in
      let half_b := Vec3.dot oc (ray_dir r) in
      let c := Vec3.length_squared oc - radius * radius in
      let discr := half_b * half_b - a * c in
      if Fixed.ltb discr 0 then h
      else
        let sqrtd := Fixed.sqrt discr in
        (* the nearest root in the acceptable range *)
        let root1 := (- half_b - sqrtd) / a in
        let root := if orb (Fixed.ltb root1 tmin) (Fixed.ltb (hit_t h) root1)
                    then (- half_b + sqrtd) / a
                    else root1 in
        if orb (Fixed.ltb root tmin) (Fixed.ltb (hit_t h) root) then h
        else
          let p := ray_at r root in
          let outward_normal := Vec3.divs (Vec3.sub p center) radius in
          hit_with_normal p root m (ray_dir r) outward_normal
  end.

(* [a] is the same for every object of the list, so it is computed once
   here rather than inside each sphere test. *)
Definition hit_list (world : list hittable) (r : ray) (tmin tmax : Fixed.t) : hit_record :=
  let a := Vec3.length_squared (ray_dir r) in
  fold_left (fun h obj => hit obj r a tmin h)
            world
            (MkHit Vec3.zero tmax Sky Vec3.zero true).

(** ** The recursive ray colour

    The accumulator carries the product of the albedos met so far, as in the
    Lean original, which makes this tail recursive. *)

Fixpoint ray_color (world : list hittable) (depth : nat) (r : ray) (acc : color)
                   (g : int) : color * int :=
  match depth with
  | O => (Vec3.black, g)   (* bounce limit reached, no more light gathered *)
  | S depth' =>
      let h := hit_list world r 0.001 Fixed.max_val in
      let (resp, g1) := scatter h r g in
      match resp with
      | Emit c => (Vec3.mul acc c, g1)
      | Scatter albedo scattered =>
          ray_color world depth' scattered (Vec3.mul albedo acc) g1
      end
  end.

(** ** Scenes *)

(** The three big spheres and the random field of small ones of the book's
    final image.  The Lean version runs a and b over [0:22] and shifts by
    -11; the same spheres come out here from the same loop bounds. *)

Definition small_sphere (center : vec3) (g : int) : hittable * int :=
  let (choose, g1) := Random.unit_fx g in
  if Fixed.ltb choose 0.9 then
    let (a1, g2) := Random.vec_range 0 1 g1 in
    let (a2, g3) := Random.vec_range 0 1 g2 in
    (Sphere center 0.2 (Lambertian (Vec3.mul a1 a2)), g3)
  else if Fixed.ltb choose 0.95 then
    let (albedo, g2) := Random.vec_range 0.5 1 g1 in
    let (fuzz, g3) := Random.range 0 0.5 g2 in
    (Sphere center 0.2 (Metal albedo fuzz), g3)
  else
    (Sphere center 0.2 (Dielectric 1.5), g1).

(* one cell (a, b) of the 22x22 grid *)
Definition scene_cell (a b : Fixed.t) (g : int) : list hittable * int :=
  let (ra, g1) := Random.unit_fx g in
  let (rb, g2) := Random.unit_fx g1 in
  let center := V3 (a + 0.9 * ra) 0.2 (b + 0.9 * rb) in
  if Fixed.ltb 0.9 (Vec3.length (Vec3.sub center (V3 4 0.2 0)))
  then let (s, g3) := small_sphere center g2 in ([s], g3)
  else ([], g2).

(* b from -11 to 10 for a fixed a *)
Fixpoint scene_row (n : nat) (a b : Fixed.t) (g : int) : list hittable * int :=
  match n with
  | O => ([], g)
  | S n' =>
      let (here, g1) := scene_cell a b g in
      let (rest, g2) := scene_row n' a (b + 1) g1 in
      (here ++ rest, g2)
  end.

Fixpoint scene_grid (n : nat) (a : Fixed.t) (g : int) : list hittable * int :=
  match n with
  | O => ([], g)
  | S n' =>
      let (here, g1) := scene_row 22 a (-11) g in
      let (rest, g2) := scene_grid n' (a + 1) g1 in
      (here ++ rest, g2)
  end.

Definition scene_weekend (g : int) : list hittable * int :=
  let ground := Sphere (V3 0 (-1000) 0) 1000 (Lambertian (Vec3.rgb 0.5 0.5 0.5)) in
  let (field, g1) := scene_grid 22 (-11) g in
  (ground :: field
    ++ [ Sphere (V3 0 1 0) 1 (Dielectric 1.5)
       ; Sphere (V3 (-4) 1 0) 1 (Lambertian (Vec3.rgb 0.4 0.2 0.1))
       ; Sphere (V3 4 1 0) 1 (Metal (Vec3.rgb 0.7 0.6 0.5) 0) ],
   g1).

(** ** The adjustable scene

    Four spheres rather than 488, so that it can be re-rendered while a
    control is being dragged -- the cost of a ray is linear in the number of
    spheres, every one of them being tested.  The second sphere is the one
    the controls move; the camera reads its settings from the same record. *)

Record knobs : Set := MkKnobs {
  kn_cam      : vec3;      (* where the camera is *)
  kn_vfov     : Fixed.t;   (* vertical field of view, in degrees *)
  kn_aperture : Fixed.t;
  kn_focus    : Fixed.t;   (* distance to the focal plane *)
  kn_centre   : vec3;      (* the movable sphere *)
  kn_radius   : Fixed.t;
  kn_mat      : int;       (* 0 diffuse, 1 metal, anything else glass *)
  kn_param    : Fixed.t;   (* the metal's fuzz, or the glass's refractive index *)
  kn_albedo   : color
}.

(* The book's camera and its centre sphere, which is glass. *)
Definition default_knobs : knobs :=
  MkKnobs (V3 13 2 3) 20 0.1 10 (V3 0 1 0) 1 2%uint63 1.5 (Vec3.rgb 0.8 0.3 0.3).

Definition knob_material (k : knobs) : material :=
  if (kn_mat k =? 0)%uint63 then Lambertian (kn_albedo k)
  else if (kn_mat k =? 1)%uint63 then Metal (kn_albedo k) (kn_param k)
  else Dielectric (kn_param k).

(* The ground is a radius-100 sphere; the weekend scene's radius-1000 one
   would do as well, this is just a smaller world. *)
Definition scene_knobs (k : knobs) : list hittable :=
  [ Sphere (V3 0 (-100) 0) 100 (Lambertian (Vec3.rgb 0.5 0.5 0.5))
  ; Sphere (kn_centre k) (kn_radius k) (knob_material k)
  ; Sphere (V3 0 1 (-2.5)) 1 (Lambertian (Vec3.rgb 0.4 0.2 0.1))
  ; Sphere (V3 0 1 2.5) 1 (Metal (Vec3.rgb 0.7 0.6 0.5) 0) ].

(* The camera of a set of knobs.  camera_make wants the half-height of the
   viewport at unit distance, which is the tangent of half the field of
   view; tan_deg is exact enough for that and keeps floats out of it. *)
Definition knob_camera (k : knobs) (aspect : Fixed.t) : camera :=
  camera_make (kn_cam k) (V3 0 0 0) (V3 0 1 0)
              (Trig.tan_deg (kn_vfov k / 2)) aspect
              (kn_aperture k) (kn_focus k).

(** The first-light scene: one sphere and the sky, shaded by the surface
    normal, no sampling and no bounces (TOTBWF/lean4-raytrace).  The camera
    sits at the origin looking down -z through a 4x2 viewport, so u and v
    run over [0,1) as in the other scene and are mapped here. *)

Definition trace_sphere : hittable := Sphere (V3 0 0 (-1)) 0.5 (Lambertian Vec3.white).

Definition trace_color (world : list hittable) (u v : Fixed.t) : color :=
  let r := MkRay Vec3.zero (V3 (4 * u - 2) (2 * v - 1) (-1)) in
  let h := hit_list world r 0.001 Fixed.max_val in
  match hit_material h with
  | Sky =>
      let unit := Vec3.normalized (ray_dir r) in
      let t := 0.5 * (vy unit + 1) in
      Vec3.add (Vec3.scale (1 - t) Vec3.white) (Vec3.scale t (Vec3.rgb 0.5 0.7 1))
  | _ => Vec3.scale 0.5 (Vec3.add (hit_normal h) Vec3.white)
  end.

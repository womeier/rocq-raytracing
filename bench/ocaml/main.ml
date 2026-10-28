(* Renders one example with the Rocq implementation, through Rocq's OCaml
 * extraction rather than CertiRocq's Wasm backend.
 *
 *   bench/ocaml/rocq-render --name first-light --scene 0 --width 512 \
 *       --height 256 --samples 1 --depth 1 --out bench/results
 *
 * The command line and the JSON line on stdout are bench/rocq-render.mjs's,
 * so bench/run.mjs drives the two interchangeably.  What differs is what
 * there is to report: the Wasm module's figures are about its allocator
 * (calls, linear memory, bytes per sample, all of them consequences of
 * having no garbage collector), and the ones here are the GC's.
 *
 * It writes <out>/<name>.ocaml.ppm.  There is no PNG encoder on this side;
 * bench/ppm.mjs converts, as it does for the Lean renders.
 *
 * --check instead renders the corner that theories/Tests.v pins down by
 * conversion and compares the bytes.  That is the test that the two
 * primitive shims next to this file agree with the Rocq kernel they stand
 * in for: if of_uint63 rounded differently, or if a comparison ordered nan,
 * the corner would come out somewhere else. *)

let name = ref "render"
let out = ref "bench/results"
let scene = ref 1
let width = ref 200
let height = ref (-1)
let samples = ref 8
let depth = ref 30
let seed = ref 1
let chunk = ref 0 (* 0: one call per row *)
let quiet = ref false
let check = ref false

(* Scene.default_knobs, which is also bench/rocq-render.mjs's defaultKnobs:
   the book's camera -- lookfrom (13,2,3), 20 degrees, aperture 0.1, focus
   10 -- and its centre sphere, glass.  The weekend scene reads only the
   camera fields. *)
let knobs = Raytracer.default_knobs

let usage =
  "bench/ocaml/rocq-render [--name N] [--scene 0|1|2] [--width W] \
   [--height H] [--samples S] [--depth D] [--seed K] [--chunk C] \
   [--out DIR] [--quiet] [--check]"

let spec =
  [ ("--name", Arg.Set_string name, " name of the example");
    ("--out", Arg.Set_string out, " directory to write the PPM into");
    ("--scene", Arg.Set_int scene, " 0 first light, 1 weekend, 2 four spheres");
    ("--width", Arg.Set_int width, " image width");
    ("--height", Arg.Set_int height, " image height (default: two thirds of the width)");
    ("--samples", Arg.Set_int samples, " samples per pixel");
    ("--depth", Arg.Set_int depth, " maximum bounces");
    ("--seed", Arg.Set_int seed, " scene and sampling seed");
    ("--chunk", Arg.Set_int chunk, " pixels per render call (0: a whole row)");
    ("--quiet", Arg.Set quiet, " no progress on stderr");
    ("--check", Arg.Set check, " render Tests.v's corner and check the bytes") ]

(* --- the bridge to the extracted code ----------------------------------- *)

let u = Uint63.of_int

let config () : Raytracer.config =
  { Raytracer.cfg_width = u !width;
    cfg_height = u !height;
    cfg_samples = u (max 1 !samples);
    cfg_depth = u (max 1 !depth);
    cfg_seed = u !seed;
    cfg_scene = u !scene;
    cfg_knobs = knobs }

let job cfg y x0 count : Raytracer.job =
  { Raytracer.job_cfg = cfg; job_y = u y; job_x0 = u x0; job_count = u count }

(* [Render.render] returns a [list byte], which extraction gives as a
   [char list] (ExtrOcamlChar): three characters per pixel, in order. *)
let blit (dst : Bytes.t) (at : int) (cs : char list) : int =
  let rec go i = function
    | [] -> i
    | c :: tl -> Bytes.set dst i c; go (i + 1) tl
  in
  go at cs - at

(* --- the render --------------------------------------------------------- *)

let render_image () =
  let cfg = config () in
  let t0 = Unix.gettimeofday () in
  let sd = Raytracer.prepare cfg in
  let prepare_s = Unix.gettimeofday () -. t0 in

  let span = if !chunk > 0 then min !chunk !width else !width in
  let rgb = Bytes.create (3 * !width * !height) in
  let calls = ref 0 in

  let t1 = Unix.gettimeofday () in
  for y = 0 to !height - 1 do
    let x0 = ref 0 in
    while !x0 < !width do
      let count = min span (!width - !x0) in
      let got = blit rgb (3 * (!width * y + !x0)) (Raytracer.render (sd, job cfg y !x0 count)) in
      incr calls;
      if got <> 3 * count then
        failwith (Printf.sprintf "the renderer returned %d bytes for %d pixels" got count);
      x0 := !x0 + count
    done;
    if (not !quiet) && (y mod 16 = 15 || y = !height - 1) then
      Printf.eprintf "\r  ocaml %s: row %d / %d   %!" !name (y + 1) !height
  done;
  let render_s = Unix.gettimeofday () -. t1 in
  if not !quiet then prerr_newline ();

  let header = Buffer.create 32 in
  List.iter (Buffer.add_char header) (Raytracer.ppm_header cfg);
  (Buffer.contents header, rgb, prepare_s, render_s, !calls)

(* --- the self-check ----------------------------------------------------- *)

(* Tests.v: [render (prepare cfg4x2, MkJob cfg4x2 0 0 1) = ["192";"217";"255"]]
   for a 4x2 first-light image, and a four-pixel span is twelve bytes.  The
   same triple the fixed-point port produced, so it also says the two number
   formats agree on this pixel. *)
let run_check () =
  width := 4; height := 2; scene := 0; samples := 1; depth := 1; seed := 1;
  let cfg = config () in
  let sd = Raytracer.prepare cfg in
  let corner = Raytracer.render (sd, job cfg 0 0 1) in
  let span = Raytracer.render (sd, job cfg 0 0 4) in
  let shown cs = String.concat ";" (List.map (fun c -> string_of_int (Char.code c)) cs) in
  let ok = ref true in
  let expect what got want =
    if got <> want then begin
      ok := false;
      Printf.printf "FAIL %s: got %s, expected %s\n" what got want
    end else Printf.printf "ok   %s = %s\n" what got
  in
  expect "corner_is_sky" (shown corner) "192;217;255";
  expect "span_is_three_bytes_per_pixel" (string_of_int (List.length span)) "12";
  (* and that cutting the span does not change it, which is what lets the
     drivers chunk a row to a memory budget (Proofs.v: spans_compose) *)
  expect "spans_compose"
    (shown span)
    (shown (Raytracer.render (sd, job cfg 0 0 1)
            @ Raytracer.render (sd, job cfg 0 1 3)));
  expect "header_is_p6"
    (String.concat "" (List.map (String.make 1) (Raytracer.ppm_header cfg)))
    "P6\n4 2\n255\n";
  if !ok then print_endline "the extraction agrees with theories/Tests.v"
  else exit 1

(* --- main --------------------------------------------------------------- *)

let () =
  Arg.parse (Arg.align spec) (fun a -> raise (Arg.Bad ("unexpected " ^ a))) usage;
  if !check then run_check ()
  else begin
    if !height < 0 then height := max 1 (!width * 2 / 3);
    let (header, rgb, prepare_s, render_s, calls) = render_image () in

    let stem = Filename.concat !out (!name ^ ".ocaml") in
    let oc = open_out_bin (stem ^ ".ppm") in
    output_string oc header;
    output_bytes oc rgb;
    close_out oc;

    (* The GC counters are this side's answer to the Wasm module's
       allocation figures: minor_words is everything the renderer allocated
       (the vectors, the hit records, the byte lists), top_heap_words the
       high-water mark -- the analogue of linear memory grown. *)
    let g = Gc.quick_stat () in
    let mb w = w *. 8.0 /. 1048576.0 in
    Printf.printf
      "{\"name\":%S,\"impl\":\"ocaml\",\"scene\":%d,\"width\":%d,\"height\":%d,\
       \"samples\":%d,\"depth\":%d,\"seed\":%d,\
       \"prepare_s\":%.3f,\"render_s\":%.3f,\"total_s\":%.3f,\
       \"calls\":%d,\"allocated_mb\":%.1f,\"top_heap_mb\":%.1f,\
       \"minor_collections\":%d,\"major_collections\":%d,\"image\":%S}\n"
      !name !scene !width !height !samples !depth !seed
      prepare_s render_s (prepare_s +. render_s)
      calls (mb g.Gc.minor_words) (mb (float_of_int g.Gc.top_heap_words))
      g.Gc.minor_collections g.Gc.major_collections
      (stem ^ ".ppm")
  end

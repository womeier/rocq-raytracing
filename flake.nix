{
  description = "A raytracer in Rocq, compiled to WebAssembly by CertiRocq's verified Wasm backend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # The same CertiRocq fork as certirocqSrc below, fetched a second way.
  # CertiRocq is built from a recipe that lives *in* the checkout, so that
  # one file has to be readable while the flake is still being evaluated.
  # Reading it out of a fetchFromGitHub would make evaluation depend on
  # building a derivation, which `nix build --max-jobs 0` -- how CI checks
  # that the binary cache holds the toolchain -- refuses to do; an input
  # is fetched by the flake machinery instead, before evaluation starts.
  # The rev is pinned in both places and the two must agree: the assert in
  # CertiRocq below checks that they still do.
  inputs.certirocq = {
    url = "github:womeier/certirocq/2d7406b5ac4fdce17b54cc2c429af5cbd5a13db8";
    flake = false;
  };

  outputs =
    { self, nixpkgs, certirocq }:
    let
      # Linux x86_64 only, on purpose: the one platform this is developed on.
      # The Wasm the build produces is platform-independent anyway, so a
      # bundle built here runs anywhere.
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      pkgs = import nixpkgs {
        inherit system;
        # CertiRocq depends on CompCert (unfree) for its Clight backend.
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "compcert" ];
      };

      # One Rocq 9.1 toolchain. On unstable everything lives in
      # rocqPackages_9_1: the rocq core, the Coq-named compatibility
      # packages (coqc, which CertiRocq's plugin needs), and the stdlib.
      #
      # Two of CertiRocq's dependencies are not the ones nixpkgs picks by
      # default, matching what the fork's own .nix/config.nix pins:
      #   * WasmCert (nixpkgs' wasmcert) 2.2.1 instead of 2.2.0, which is
      #     what rocq-certirocq.opam asks for ("coq-wasm" {>= "2.2.1"}).
      #     This nixpkgs knows only the 2.2.0 release -- later ones hold
      #     2.2.1 back for Rocq 9.2 because it breaks the *released*
      #     CertiRocq -- so the version is given as an explicit rev+hash.
      #   * MetaRocq from its "9.1" development branch instead of the
      #     1.5.1-9.1 release. CertiRocq has needed that branch since
      #     https://github.com/CertiRocq/certirocq/pull/158; c8cd4605 is
      #     the branch head.
      rocqPackages = pkgs.rocqPackages_9_1.overrideScope (
        _self: super: {
          wasmcert = super.wasmcert.override {
            version = {
              version = "2.2.1";
              location = {
                rev = "v2.2.1";
                hash = "sha256-RtJXfaX/04+BuMWjnq6PKOyNm5Ed5v/ZP71C9Q8iSVk=";
              };
            };
          };
          metarocq = super.metarocq.override {
            version = {
              version = "unstable-c8cd4605";
              location = {
                rev = "c8cd46054518193103c3bb33aa6e15c7f489e72c";
                hash = "sha256-Lcr6B4gYSS57zVinn+e2tk1Kfy9XzJs+sd3CTuSTvX0=";
              };
            };
          };
        }
      );

      # CertiRocq is taken from a branch rather than the 0.9.1+9.1 release,
      # because the release's Wasm backend has no code generation for
      # primitive floats and this renderer computes in them
      # (theories/Flt.v) -- against the release, theories/extraction.v
      # stops at "Unsupported primitive operator:
      # Corelib.Floats.PrimFloat.ltb".
      #
      # womeier/certirocq wasm-prim-floats adds all eighteen PrimFloat
      # operations and float literals. A primitive float is boxed exactly
      # as a uint63 already was -- an 8-byte payload at an even address,
      # the value being that address, the payload holding the IEEE 754 bit
      # pattern -- so the memory layout, the invariant and the
      # instantiation proof are untouched, and src/index.js's one
      # setFloat64 per value is the whole host-side encoding. The branch
      # admits three float-only obligations (its TODO.md); the structural
      # parts of the correctness proof cover the new branch.
      certirocqSrc = pkgs.fetchFromGitHub {
        owner = "womeier";
        repo = "certirocq";
        rev = "2d7406b5ac4fdce17b54cc2c429af5cbd5a13db8";
        hash = "sha256-X5IxtzBUdSJyFD8sese0tpdkCRa/WFLTa+eshXOAA/g=";
      };

      # Built from the branch's own build recipe
      # (.nix/coq-overlays/CertiRocq/default.nix) rather than from
      # nixpkgs' rocqPackages_9_1.CertiRocq with the source swapped out.
      # nixpkgs' recipe is a snapshot of an older directory layout
      # (top-level plugin/ and cplugin/, built by `make plugins`); CertiRocq
      # has since moved both under plugins/ and split the build into `make
      # plugin` / `make cplugin` (CertiRocq/certirocq@fb1cf3e), so against
      # that recipe the build stops with "make: *** plugin: No such file or
      # directory". Taking the recipe from the source keeps the two in step.
      #
      # The recipe is read through the certirocq *input* (see inputs
      # above) while src stays the fetchFromGitHub: both name the same
      # rev, so both land on the same store path -- which is what the
      # assert says -- but only the input can be read during evaluation,
      # and only the fetch keeps this derivation byte-identical to the one
      # the binary cache was filled from.
      CertiRocq =
        assert certirocqSrc.outPath == certirocq.outPath;
        (rocqPackages.callPackage "${certirocq}/.nix/coq-overlays/CertiRocq/default.nix" {
          inherit pkgs;
        }).overrideAttrs
          (old: {
            version = "wasm-prim-floats-2d7406b5";
            src = certirocqSrc;
            # Both of these are cosmetic fixups of what the generic
            # mkCoqDerivation machinery leaves behind when it cannot resolve
            # `version` against a known release (there is none here -- see
            # certirocqSrc above): a "-broken" name suffix and meta.broken.
            name = "coq9.1-CertiRocq-wasm-prim-floats";
            meta = (old.meta or { }) // {
              broken = false;
            };
          });

      # Rocq sources + the files the web bundle is made of. Keeps build
      # products and editor leftovers out of the derivation.
      src = lib.cleanSourceWith {
        src = ./.;
        filter =
          path: type:
          type == "directory"
          || lib.hasSuffix ".v" path
          || lib.hasSuffix ".js" path
          || lib.hasSuffix ".html" path
          || lib.elem (baseNameOf path) [
            "Makefile"
            "_RocqProject"
          ];
      };

      # The whole raytracer as a single Wasm module, compiled by CertiRocq
      # from theories/extraction.v, plus the host glue that drives it.
      raytracer-wasm = pkgs.stdenv.mkDerivation {
        pname = "rocq-raytracer-wasm";
        version = "0.1.0";
        inherit src;

        nativeBuildInputs = [
          rocqPackages.coq
          CertiRocq
        ];

        COQBIN = "${rocqPackages.coq}/bin/";

        buildPhase = ''
          runHook preBuild
          ulimit -s unlimited 2>/dev/null || true
          make -j $NIX_BUILD_CORES
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp Raytracing.extraction.raytracer_wasm_api.wasm $out/raytracer.wasm
          cp src/index.html src/index.js $out/
          runHook postInstall
        '';

        meta = {
          description = "A raytracer in Rocq, compiled to WebAssembly by CertiRocq";
          license = lib.licenses.mit;
          platforms = [ system ];
        };
      };

      # The bundle is run by serving it: a static server for the page, which
      # needs one because a Wasm module cannot be fetched from a file:// URL.
      serve = pkgs.writeShellApplication {
        name = "rocq-raytracer-serve";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          port=''${1:-8000}
          echo "serving the raytracer on http://localhost:$port/"
          exec python3 -m http.server "$port" --directory ${raytracer-wasm}
        '';
      };
    in
    {
      packages.${system} = {
        default = raytracer-wasm;
        inherit raytracer-wasm;
        # The heavy prebuilt dependency, exposed so CI can fetch it
        # substitute-only before building anything:
        #   nix build --max-jobs 0 .#CertiRocq
        # CompCert comes with it (propagated), so that one fetch covers both.
        inherit CertiRocq;
        inherit serve;
      };

      # The build compiles Tests.v, whose examples are checked by
      # conversion, so building is the test suite.
      checks.${system}.build = raytracer-wasm;

      apps.${system} =
        let
          serveApp = {
            type = "app";
            program = lib.getExe serve;
            meta.description = "Serve the web page on http://localhost:8000/";
          };
        in
        {
          default = serveApp;
          serve = serveApp;
        };

      devShells.${system}.default = pkgs.mkShell {
        name = "rocq-raytracer";
        packages = [
          rocqPackages.rocq-core
          rocqPackages.coq
          CertiRocq
          rocqPackages.stdlib
          rocqPackages.coq-lsp
          pkgs.gnumake
          pkgs.python3
          pkgs.wabt # wasm2wat, to look at what came out
          # `make ocaml`: theories/ through Rocq's own extraction, which is
          # how the renderer is run and timed while the Wasm backend does
          # not accept primitive floats.  bench/ocaml/build.sh needs nothing
          # but ocamlopt and the unix library that comes with it.
          pkgs.ocaml
          # the benchmark drivers, bench/*.mjs
          pkgs.nodejs
        ];

        COQBIN = "${rocqPackages.coq}/bin/";

        shellHook = ''
          echo "rocq-raytracer development environment"
          echo "  rocq:  $(rocq --version | head -1)"
          echo ""
          echo "Build the Wasm module:  make        (or: nix build)"
          echo "Build the OCaml one:    make ocaml  (then: make check-ocaml)"
          echo "Benchmark it:           make bench-ocaml"
          echo "Serve the page:         nix run .#serve   (then open localhost:8000)"
        '';
      };
    };
}

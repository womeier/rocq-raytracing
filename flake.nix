{
  description = "A raytracer in Rocq, compiled to WebAssembly by CertiRocq's verified Wasm backend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
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
      # packages (coqc, which CertiRocq's plugin needs), CertiRocq itself
      # and the stdlib.
      rocqPackages = pkgs.rocqPackages_9_1;

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
          rocqPackages.CertiRocq
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
        CertiRocq = rocqPackages.CertiRocq;
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
          rocqPackages.CertiRocq
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

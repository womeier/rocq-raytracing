all: Makefile.rocq
	@+$(MAKE) -f Makefile.rocq all

clean: Makefile.rocq
	@+$(MAKE) -f Makefile.rocq cleanall
	@rm -f Makefile.rocq Makefile.rocq.conf *.wasm
	@rm -f bench/ocaml/raytracer.ml bench/ocaml/raytracer.mli \
	       bench/ocaml/rocq-render bench/ocaml/*.cm[iox] bench/ocaml/*.o

Makefile.rocq: _RocqProject
	$(COQBIN)rocq makefile -f _RocqProject -o Makefile.rocq

# The OCaml extraction (theories/extraction_ocaml.v, bench/ocaml/), which is
# how the renderer is run and timed while CertiRocq's Wasm backend does not
# accept primitive floats.
#
# Compiled here rather than through Makefile.rocq, and left out of
# _RocqProject, so that the Wasm build and `nix build` never reach it: it is
# a benchmarking tool and has no business in the deliverable.  The cost of
# that is repeating the two flags _RocqProject sets.
ROCQFLAGS = -R theories Raytracing -w -inexact-float

bench/ocaml/raytracer.ml: theories/extraction_ocaml.v theories/Render.vo
	@mkdir -p bench/ocaml
	$(COQBIN)rocq c $(ROCQFLAGS) $<

ocaml: bench/ocaml/raytracer.ml
	bench/ocaml/build.sh

# Renders Tests.v's corner through the extracted OCaml and compares the
# bytes, which is what checks bench/ocaml/uint63.ml and float64.ml against
# the kernel primitives they stand in for.
check-ocaml: ocaml
	./bench/ocaml/rocq-render --check

# The benchmark: four examples, rendered by this project and by the two Lean
# originals, timed and compared (bench/README.md).
bench-setup:
	bench/setup.sh

bench: all
	node bench/run.mjs

# The same four examples through the OCaml extraction only -- no Wasm module
# and no Lean binaries needed, so this is the one that runs today.
bench-ocaml: ocaml
	node bench/run.mjs --skip-lean --skip-wasm

force _RocqProject Makefile theories/extraction_ocaml.v: ;

%: Makefile.rocq force
	@+$(MAKE) -f Makefile.rocq $@

.PHONY: all clean force bench bench-setup bench-ocaml ocaml check-ocaml

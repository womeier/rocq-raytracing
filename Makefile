all: Makefile.rocq
	@+$(MAKE) -f Makefile.rocq all

clean: Makefile.rocq
	@+$(MAKE) -f Makefile.rocq cleanall
	@rm -f Makefile.rocq Makefile.rocq.conf *.wasm

Makefile.rocq: _RocqProject
	$(COQBIN)rocq makefile -f _RocqProject -o Makefile.rocq

# The benchmark: four examples, rendered by this project and by the two Lean
# originals, timed and compared (bench/README.md).
bench-setup:
	bench/setup.sh

bench: all
	node bench/run.mjs

force _RocqProject Makefile: ;

%: Makefile.rocq force
	@+$(MAKE) -f Makefile.rocq $@

.PHONY: all clean force bench bench-setup

#!/usr/bin/env bash
# Builds bench/ocaml/rocq-render from the extracted renderer.
#
# Four modules, in dependency order: the two primitive shims, the extracted
# raytracer.ml, and the driver.  No libraries but unix (for a wall clock),
# so plain ocamlopt does it -- no dune, no findlib, nothing to install.
#
# raytracer.ml is generated: `make theories/extraction_ocaml.vo` writes it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

if [ ! -f raytracer.ml ]; then
  echo "bench/ocaml/raytracer.ml is missing; run 'make ocaml' from the root" >&2
  exit 1
fi

OCAMLOPT=${OCAMLOPT:-ocamlopt}

# -O3 is flambda-only and silently ignored otherwise; -unboxed-types is not
# a thing in 4.14.  -inline 100 is what matters: the shims are one-line
# wrappers and must disappear into their call sites.
#
# -w -a on raytracer.ml alone: extraction emits unused values and
# non-exhaustive-looking matches by design, and they are not ours to fix.
"$OCAMLOPT" -unsafe -inline 100 -nodynlink \
  -I . unix.cmxa \
  uint63.ml float64.ml \
  -w -a raytracer.mli raytracer.ml \
  -w +a-4-9-40-42-44-45-70 main.ml \
  -o rocq-render

rm -f ./*.cm[iox] ./*.o
echo "built $here/rocq-render"

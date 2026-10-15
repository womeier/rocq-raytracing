#!/usr/bin/env bash
# Fetches the two Lean raytracers this project was ported from, patches each
# one so that it can be driven and timed from a script, and builds them.
#
# Both patches are small and are kept in bench/lean/:
#   kmill-cli.patch   options for size, samples, depth and thread count, a
#                     timing line on stdout, progress on stderr; the default
#                     thread count becomes 1, since the Wasm module is one core
#   totbwf-cli.patch  a lakefile (leanpkg is gone), an output path, the same
#                     timing line, and the fix for an off-by-one that made the
#                     512x256 render come out 511x255
#
# Run from the repository root:  bench/setup.sh
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)
vendor=bench/vendor
mkdir -p "$vendor"

# Pinned, so that a measurement can be repeated.
clone() { # <dir> <url> <commit> <patch>
  local dir="$vendor/$1" url=$2 commit=$3 patch=$4
  if [ ! -d "$dir/.git" ]; then
    echo "==> cloning $url"
    git clone --quiet "$url" "$dir"
  fi
  git -C "$dir" fetch --quiet origin "$commit" 2>/dev/null || true
  git -C "$dir" checkout --quiet --force "$commit"
  git -C "$dir" clean -qfd -e .lake
  echo "==> patching $1"
  git -C "$dir" apply "$root/$patch"
}

clone lean4-raytracer https://github.com/kmill/lean4-raytracer \
      205143b32c006199c914cf6f340004137aaaa72a bench/lean/kmill-cli.patch
clone lean4-raytrace  https://github.com/TOTBWF/lean4-raytrace \
      6f4e9712ce15ff29523ae30416ea6ce5ea26818e bench/lean/totbwf-cli.patch

# elan fetches the toolchain each project pins on the first build.
for d in lean4-raytracer lean4-raytrace; do
  echo "==> building $d"
  (cd "$vendor/$d" && lake build)
done

echo
echo "built:"
ls -l "$vendor"/lean4-raytracer/.lake/build/bin/render "$vendor"/lean4-raytrace/.lake/build/bin/trace
echo
echo "the Rocq side needs the Wasm module, which 'make' (or 'nix build') produces."

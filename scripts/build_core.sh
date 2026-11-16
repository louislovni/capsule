#!/bin/sh
# Fetches PokeDaisy (and the mGBA it pins) and builds the C side of the app.
#   scripts/build_core.sh ios    -> build/core-ios/{libcapsulecore.a, pokedaisy/pokedaisy_gbc_libretro.a}
#   scripts/build_core.sh host   -> build/core-host, then runs the tests (any Unix)
set -eu

POKEDAISY_COMMIT=0040e61fcb129d7313e3941771572c93d6722816
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-host}"
SRC="$ROOT/Vendor/pokedaisy"
OUT="$ROOT/build/core-$TARGET"

if [ ! -d "$SRC/.git" ]; then
	mkdir -p "$ROOT/Vendor"
	git init -q "$SRC"
	git -C "$SRC" remote add origin https://github.com/lidor30/pokedaisy.git
fi
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$POKEDAISY_COMMIT" ]; then
	git -C "$SRC" fetch -q --depth 1 origin "$POKEDAISY_COMMIT"
	git -C "$SRC" checkout -q --force FETCH_HEAD
fi
# Only the mGBA submodule is needed for this core.
git -C "$SRC" submodule update -q --init --depth 1 third_party/mgba

# Two local changes, both safe to apply twice:
# 1. The core is linked into the app, so it is built as a static library.
sed -i.bak 's/add_library(pokedaisy_gbc_libretro SHARED/add_library(pokedaisy_gbc_libretro STATIC/' "$SRC/libretro/CMakeLists.txt"
# 2. mGBA's CMake forces a macOS deployment target on every Apple platform, wrong for iOS.
sed -i.bak 's/set(CMAKE_OSX_DEPLOYMENT_TARGET "10.6")/# deployment target left to the caller/' \
	"$SRC/third_party/mgba/CMakeLists.txt"
rm -f "$SRC/libretro/CMakeLists.txt.bak" "$SRC/third_party/mgba/CMakeLists.txt.bak"

case "$TARGET" in
ios)
	cmake -S "$ROOT/Core" -B "$OUT" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
	cmake --build "$OUT" --target capsulecore pokedaisy_gbc_libretro -j 4
	;;
host)
	cmake -S "$ROOT/Core" -B "$OUT" -DCMAKE_BUILD_TYPE=Release
	cmake --build "$OUT" -j 4
	(cd "$OUT" && ctest --output-on-failure)
	;;
*)
	echo "usage: $0 ios|host" >&2
	exit 2
	;;
esac

ls -l "$OUT/libcapsulecore.a" "$OUT/pokedaisy/pokedaisy_gbc_libretro.a"

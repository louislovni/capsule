#!/bin/sh
# Fetches mGBA at a pinned commit and builds libcapsulecore.a (mGBA + bridge + pkcore).
#   scripts/build_core.sh ios    -> build/core-ios/libcapsulecore.a   (macOS + Xcode)
#   scripts/build_core.sh host   -> build/core-host, then runs the tests (any Unix)
set -eu

MGBA_COMMIT=6c062d1407aa4bfec3235cebb12d229abf781779
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-host}"
SRC="$ROOT/Vendor/mgba"
OUT="$ROOT/build/core-$TARGET"

if [ ! -d "$SRC/.git" ]; then
	mkdir -p "$ROOT/Vendor"
	git init -q "$SRC"
	git -C "$SRC" remote add origin https://github.com/mgba-emu/mgba.git
fi
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$MGBA_COMMIT" ]; then
	git -C "$SRC" fetch -q --depth 1 origin "$MGBA_COMMIT"
	git -C "$SRC" checkout -q --force FETCH_HEAD
fi

# mGBA's CMake forces a macOS deployment target on every Apple platform, which is
# wrong for iOS. Neutralise that one line (safe to run twice).
if grep -q 'set(CMAKE_OSX_DEPLOYMENT_TARGET "10.6")' "$SRC/CMakeLists.txt"; then
	sed -i.bak 's/set(CMAKE_OSX_DEPLOYMENT_TARGET "10.6")/# deployment target left to the caller/' "$SRC/CMakeLists.txt"
	rm -f "$SRC/CMakeLists.txt.bak"
fi

case "$TARGET" in
ios)
	# RelWithDebInfo rather than Release: on Apple platforms mGBA adds link-time
	# optimisation to Release builds, which we do not need in a static library.
	cmake -S "$ROOT/Core" -B "$OUT" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0
	cmake --build "$OUT" --target capsulecore -j 4
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

ls -l "$OUT/libcapsulecore.a"

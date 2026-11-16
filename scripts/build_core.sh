#!/bin/sh
# Fetches PokeDaisy (with the mGBA and DSperate it pins) and builds the C side of the app.
#   scripts/build_core.sh ios    -> build/core-ios/libcapsulecore.a
#                                   build/frameworks/{pokedaisy_gbc,pokedaisy_ds}.framework
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
git -C "$SRC" submodule update -q --init --depth 1 third_party/mgba
git -C "$SRC" submodule update -q --init --recursive --depth 1 third_party/dsperate-lr

# Start from PokeDaisy's files as published, then make the two changes below.
git -C "$SRC" checkout -q -- libretro/CMakeLists.txt linux/libretro-ds/CMakeLists.txt
git -C "$SRC/third_party/mgba" checkout -q -- CMakeLists.txt
git -C "$SRC/third_party/dsperate-lr/DSperate" checkout -q -- src/core/crypto/aes.c
# 1. Their link options are GNU ld's (version scripts): Apple's linker has none of them.
perl -pi -e 's/^(target_link_options\(pokedaisy_\w+_libretro PRIVATE -Wl,--.*\))$/if(NOT APPLE)\n  $1\nendif()/' \
	"$SRC/libretro/CMakeLists.txt" "$SRC/linux/libretro-ds/CMakeLists.txt"
# 2. DSperate asks Linux (getauxval) whether an ARM CPU has AES instructions: elsewhere
#    it takes its plain C cipher instead, as it does on any other system.
perl -0pi -e 's/#if defined\(__aarch64__\) && defined\(__GNUC__\)\n#include <arm_neon.h>\n#include <sys\/auxv.h>/#if defined(__aarch64__) && defined(__GNUC__) && defined(__linux__)\n#include <arm_neon.h>\n#include <sys\/auxv.h>/' \
	"$SRC/third_party/dsperate-lr/DSperate/src/core/crypto/aes.c"
grep -q 'defined(__GNUC__) && defined(__linux__)' "$SRC/third_party/dsperate-lr/DSperate/src/core/crypto/aes.c"
# 3. mGBA's CMake forces a macOS deployment target on every Apple platform, wrong for iOS.
perl -pi -e 's/set\(CMAKE_OSX_DEPLOYMENT_TARGET "10.6"\)/# deployment target left to the caller/' \
	"$SRC/third_party/mgba/CMakeLists.txt"

CORES="pokedaisy_gbc_libretro pokedaisy_ds_libretro"

case "$TARGET" in
ios)
	cmake -S "$ROOT/Core" -B "$OUT" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0
	# shellcheck disable=SC2086
	cmake --build "$OUT" --target capsulecore $CORES -j 4
	# Each core becomes a framework the app embeds and opens by path.
	FRAMEWORKS="$ROOT/build/frameworks"
	rm -rf "$FRAMEWORKS"
	mkdir -p "$FRAMEWORKS"
	for core in $CORES; do
		name="${core%_libretro}"
		lib="$(find "$OUT" -name "$core.dylib" -o -name "$core.so" | head -n 1)"
		test -n "$lib"
		dir="$FRAMEWORKS/$name.framework"
		mkdir -p "$dir"
		cp "$lib" "$dir/$name"
		install_name_tool -id "@rpath/$name.framework/$name" "$dir/$name"
		cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>app.capsule.gba.$(echo "$name" | tr '_' '-')</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>16.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict>
</plist>
PLIST
		ls -l "$dir/$name"
	done
	ls -l "$OUT/libcapsulecore.a"
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

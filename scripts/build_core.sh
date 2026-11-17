#!/bin/sh
# Fetches PokeDaisy - our fork's capsule branch, upstream plus Capsule's changes (CAPSULE.md there) -
# with the mGBA and DSperate it pins, and builds the C side of the app.
#   scripts/build_core.sh ios    -> build/core-ios/libcapsulecore.a
#                                   build/frameworks/{pokedaisy_gbc,pokedaisy_ds}.framework
#   scripts/build_core.sh host   -> build/core-host, then runs the tests (any Unix)
set -eu

POKEDAISY_COMMIT=84d8e58e2c4e6f098457d8256134a834be0fcc79   # louislovni/pokedaisy, branch capsule
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-host}"
SRC="$ROOT/Vendor/pokedaisy"
OUT="$ROOT/build/core-$TARGET"

if [ ! -d "$SRC/.git" ]; then
	mkdir -p "$ROOT/Vendor"
	git init -q "$SRC"
	git -C "$SRC" remote add origin https://github.com/louislovni/pokedaisy.git
fi
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$POKEDAISY_COMMIT" ]; then
	git -C "$SRC" fetch -q --depth 1 origin "$POKEDAISY_COMMIT"
	git -C "$SRC" checkout -q --force FETCH_HEAD
fi
git -C "$SRC" submodule update -q --init --depth 1 third_party/mgba
git -C "$SRC" submodule update -q --init --recursive --depth 1 third_party/dsperate-lr

# Start from the files as committed: the fork's CMake applies its DSperate patch at configure time
# (third_party/patches/dsperate-capsule.patch), and the steps below change a few more.
git -C "$SRC/third_party/mgba" checkout -q -- CMakeLists.txt
git -C "$SRC/third_party/dsperate-lr/DSperate" checkout -q -- \
	src/core/crypto/aes.c src/core/cheat/analog_db.cpp src/core/io/dsi_font.cpp \
	src/core/gpu/gpu3d.h src/core/gpu/gpu3d.cpp
# 1. DSperate's data files are linked in with ELF assembly; Apple's needs Mach-O.
if [ "$TARGET" = ios ]; then
	python3 "$ROOT/scripts/patch_dsperate_macho.py" "$SRC/third_party/dsperate-lr/DSperate"
fi
# 2. mGBA's CMake forces a macOS deployment target on every Apple platform, wrong for iOS.
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

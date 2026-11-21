#!/bin/sh
# Fetches PokeDaisy - our fork's capsule branch, upstream plus Capsule's changes (CAPSULE.md there) -
# with the mGBA and DSperate it pins, and builds the C side of the app.
#   scripts/build_core.sh ios    -> build/core-ios/libcapsulecore.a
#                                   build/frameworks/{pokedaisy_gbc,pokedaisy_ds}.framework
#   scripts/build_core.sh host   -> build/core-host, then runs the tests (any Unix)
#   scripts/build_core.sh windows -> build/Capsule-Windows.zip: PokeDaisy's desktop frontend, the two cores,
#                                   SDL2 and Capsule.exe (windows/launcher: sign-in and cloud saves).
#                                   Needs mingw-w64 and Go; GOOGLE_DESKTOP_CLIENT_ID / _SECRET for the sign-in.
set -eu

POKEDAISY_COMMIT=02ee6003e3c01df5f778643df438113b6ccfffd1
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
# ... and MinGW's, PE/COFF.
if [ "$TARGET" = windows ]; then
	python3 "$ROOT/scripts/patch_dsperate_coff.py" "$SRC/third_party/dsperate-lr/DSperate"
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
windows)
	SDL_VERSION=2.30.9
	SDL_SHA256=b188d165dc4a0372042bff3d0c18e9bb90772581e92a7b8b47b521b47714f75c
	SDL_DIR="$ROOT/build/sdl2-mingw"
	if [ ! -d "$SDL_DIR/SDL2-$SDL_VERSION" ]; then
		mkdir -p "$SDL_DIR"
		curl -sSL -o "$SDL_DIR/sdl.tgz" \
			"https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL2-devel-$SDL_VERSION-mingw.tar.gz"
		echo "$SDL_SHA256  $SDL_DIR/sdl.tgz" | sha256sum -c -
		tar xzf "$SDL_DIR/sdl.tgz" -C "$SDL_DIR"
	fi
	SDL_ROOT="$SDL_DIR/SDL2-$SDL_VERSION/x86_64-w64-mingw32"
	cmake -S "$ROOT/Core" -B "$OUT" -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$ROOT/Core/win/mingw.cmake"
	# shellcheck disable=SC2086
	cmake --build "$OUT" --target $CORES -j 4
	cmake -S "$ROOT/windows" -B "$ROOT/build/win-frontend" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_TOOLCHAIN_FILE="$ROOT/Core/win/mingw.cmake" -DPOKEDAISY_DIR="$SRC" -DSDL2_ROOT="$SDL_ROOT"
	cmake --build "$ROOT/build/win-frontend" -j 4
	VERSION="${CAPSULE_VERSION:-dev}"
	# The cloud sync against a fake Firestore first (cloud_test.go): two devices, clock footers, conflicts.
	(cd "$ROOT/windows/launcher" && go test ./...)
	(cd "$ROOT/windows/launcher" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath \
		-ldflags "-s -w -X main.version=$VERSION -X main.googleClientID=${GOOGLE_DESKTOP_CLIENT_ID:-} -X main.googleClientSecret=${GOOGLE_DESKTOP_CLIENT_SECRET:-}" \
		-o "$ROOT/build/win-launcher/Capsule.exe" .)

	PKG="$ROOT/build/win-package/Capsule"
	rm -rf "$ROOT/build/win-package" && mkdir -p "$PKG/roms" "$PKG/licenses"
	cp "$ROOT/build/win-launcher/Capsule.exe" "$ROOT/build/win-frontend/pokedaisy.exe" "$SDL_ROOT/bin/SDL2.dll" "$PKG/"
	for core in $CORES; do cp "$(find "$OUT" -name "$core.dll" | head -n 1)" "$PKG/"; done
	cp "$ROOT/windows/LISEZMOI.txt" "$PKG/LISEZMOI.txt"
	# COMPATIBLE GAMES: the games Capsule knows, read by Capsule.exe (compat.go) for the game list's X / Y.
	cp "$ROOT/App/Library/compat.json" "$PKG/compat.json"
	cp "$ROOT/windows/roms-LISEZMOI.txt" "$PKG/roms/LISEZMOI.txt"
	cp "$ROOT/LICENSE" "$PKG/licenses/Capsule-GPL-3.0.txt"
	cp "$ROOT/NOTICE" "$PKG/licenses/Capsule-NOTICE.txt"
	cp "$SRC/LICENSE" "$PKG/licenses/PokeDaisy-LICENSE.txt"
	cp "$SRC/NOTICE" "$PKG/licenses/PokeDaisy-NOTICE.txt"
	cp "$SRC/third_party/mgba/LICENSE" "$PKG/licenses/mGBA-MPL-2.0.txt"
	cp "$SDL_DIR/SDL2-$SDL_VERSION/LICENSE.txt" "$PKG/licenses/SDL2-zlib.txt"
	cp "$ROOT/Core/third_party/monocypher/LICENCE.md" "$PKG/licenses/Monocypher-LICENCE.md"
	cp "$ROOT/Core/third_party/mdns/LICENSE" "$PKG/licenses/mdns-Unlicense.txt"
	(cd "$SRC/third_party/dsperate-lr" && find . -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'notice*' \) \
		-not -path './.git/*' | while read -r f; do mkdir -p "$PKG/licenses/dsperate-lr/$(dirname "$f")"; cp "$f" "$PKG/licenses/dsperate-lr/$f"; done)
	printf 'Capsule %s pour Windows\nSource : https://github.com/louislovni/capsule\nPokeDaisy : https://github.com/louislovni/pokedaisy (%s)\n' \
		"$VERSION" "$POKEDAISY_COMMIT" > "$PKG/SOURCE.txt"
	rm -f "$ROOT/build/Capsule-Windows.zip"
	(cd "$ROOT/build/win-package" && zip -qr9 "$ROOT/build/Capsule-Windows.zip" Capsule)
	ls -l "$ROOT/build/Capsule-Windows.zip"
	;;
*)
	echo "usage: $0 ios|host|windows" >&2
	exit 2
	;;
esac

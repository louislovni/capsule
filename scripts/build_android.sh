#!/bin/sh
# Capsule for Android: PokeDaisy's Android app (our fork's capsule branch) in its "capsule" build type -
# package com.pokedaisy.app.capsule, named Capsule, updating from this repo's releases.
#   scripts/build_android.sh [version] [code] -> build/Capsule.apk
# Needs JDK 17 and the Android SDK (ANDROID_HOME) with NDK 28.2.13676358 and CMake 3.22.1.
# Signing: android/capsule-android.p12 (PKCS12, alias capsule), its password in ANDROID_KEYSTORE_PASSWORD;
# without it the APK is signed with the debug key (a test build: it can't update a signed install).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POKEDAISY_COMMIT="$(sed -n 's/^POKEDAISY_COMMIT=\([0-9a-f]*\).*/\1/p' "$ROOT/scripts/build_core.sh")"
VERSION="${1:-1.6.1.0}"
CODE="${2:-1000}"
SRC="$ROOT/Vendor/pokedaisy-android"

if [ ! -d "$SRC/.git" ]; then
	mkdir -p "$ROOT/Vendor"
	git init -q "$SRC"
	git -C "$SRC" remote add origin https://github.com/louislovni/pokedaisy.git
fi
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$POKEDAISY_COMMIT" ]; then
	git -C "$SRC" fetch -q --depth 1 origin "$POKEDAISY_COMMIT"
	git -C "$SRC" checkout -q --force FETCH_HEAD
fi
for m in third_party/mgba third_party/rcheevos third_party/melonds third_party/dsperate third_party/zlib; do
	git -C "$SRC" submodule update -q --init --recursive --depth 1 "$m"
done

rm -f "$SRC/keystore.properties"
if [ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ]; then
	{
		echo "storeFile=$ROOT/android/capsule-android.p12"
		echo "storePassword=$ANDROID_KEYSTORE_PASSWORD"
		echo "keyAlias=capsule"
		echo "keyPassword=$ANDROID_KEYSTORE_PASSWORD"
	} > "$SRC/keystore.properties"
	echo "signing: Capsule's key"
else
	echo "signing: debug key (no ANDROID_KEYSTORE_PASSWORD)"
fi

(cd "$SRC" && ./gradlew --no-daemon -q :app:assembleCapsule \
	-Ppokedaisy.versionName="$VERSION" -Ppokedaisy.versionCode="$CODE")
rm -f "$SRC/keystore.properties"
APK="$(find "$SRC/app/build/outputs/apk/capsule" -name '*.apk' | head -n 1)"
mkdir -p "$ROOT/build"
cp "$APK" "$ROOT/build/Capsule.apk"
ls -l "$ROOT/build/Capsule.apk"

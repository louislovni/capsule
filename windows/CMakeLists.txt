# PokeDaisy's desktop frontend (linux/main.c, an SDL2 libretro frontend) for Windows, as Capsule ships it:
# it loads pokedaisy_gbc_libretro.dll / pokedaisy_ds_libretro.dll from beside itself.
#   cmake -S windows -B build/win-frontend -DCMAKE_TOOLCHAIN_FILE=Core/win/mingw.cmake \
#         -DPOKEDAISY_DIR=Vendor/pokedaisy -DSDL2_ROOT=<SDL2-devel-mingw>/x86_64-w64-mingw32
cmake_minimum_required(VERSION 3.18)
project(capsule_windows_frontend C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_EXTENSIONS ON)
set(POKEDAISY_DIR "" CACHE PATH "PokeDaisy source tree")
set(SDL2_ROOT "" CACHE PATH "SDL2's MinGW development files (the x86_64-w64-mingw32 folder)")
set(WIN "${CMAKE_CURRENT_SOURCE_DIR}/../Core/win")

file(GLOB PD_CORE CONFIGURE_DEPENDS ${POKEDAISY_DIR}/3ds/core/*.c)
add_executable(pokedaisy WIN32 ${POKEDAISY_DIR}/linux/main.c ${PD_CORE} ${POKEDAISY_DIR}/3ds/desktop/pd_png.c)
target_include_directories(pokedaisy PRIVATE ${POKEDAISY_DIR}/3ds/core ${POKEDAISY_DIR}/third_party/mgba/src/platform/libretro
  ${SDL2_ROOT}/include/SDL2)
target_include_directories(pokedaisy BEFORE PRIVATE ${WIN}/include)
# POCKET_PURE: one save per game, no save states or rewind (Capsule's rule).
target_compile_definitions(pokedaisy PRIVATE _GNU_SOURCE POCKET_PURE)
target_compile_options(pokedaisy PRIVATE -include ${WIN}/compat.h -O2)
target_link_directories(pokedaisy PRIVATE ${SDL2_ROOT}/lib)
# The game list's patcher: a dropped .ips / .ups / .bps / .xdelta (PokeDaisy's third_party/pkpatch, Capsule's pk_patch.c).
include(${POKEDAISY_DIR}/third_party/pkpatch/pkpatch.cmake)
# JOUER A DEUX: Capsule's co-op (coop_pc.c over Core/coop, PokeDaisy's protocol; mDNS for the Wi-Fi).
set(CORE "${CMAKE_CURRENT_SOURCE_DIR}/../Core")
add_library(capsule_coop STATIC coop_pc.c ${CORE}/coop/coop_crypto.c ${CORE}/coop/coop_noise.c ${CORE}/coop/coop_wire.c
  ${CORE}/coop/coop_host.c ${CORE}/third_party/monocypher/monocypher.c
  ${CORE}/pkcore/pk_text.c ${CORE}/pkcore/pk_mon.c ${CORE}/pkcore/pk_save.c)
target_include_directories(capsule_coop PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} PRIVATE ${CORE}/coop ${CORE}/pkcore
  ${CORE}/third_party/monocypher ${CORE}/third_party/mdns ${CMAKE_CURRENT_SOURCE_DIR}/include-mdns)
target_compile_options(capsule_coop PRIVATE -O2)
target_link_libraries(capsule_coop PUBLIC ws2_32 bcrypt)
target_compile_definitions(pokedaisy PRIVATE CAPSULE_COOP)
target_link_libraries(pokedaisy PRIVATE capsule_coop pkpatch mingw32 SDL2main SDL2 m)
target_link_options(pokedaisy PRIVATE -static-libgcc -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive,-Bdynamic)

# Builds the C side of the app:
#   - PokeDaisy's two libretro cores, each a dynamic library of its own (they
#     share hundreds of internal names, so they can't live in one binary):
#       pokedaisy_gbc_libretro  Game Boy, Game Boy Color, Game Boy Advance (mGBA)
#       pokedaisy_ds_libretro   Nintendo DS (DSperate, without its JIT: iOS forbids one)
#     built from PokeDaisy's own CMake files; scripts/build_core.sh wraps them
#     as frameworks for the app.
#   - libcapsulecore.a: the host that loads a core (bridge/lr_bridge.c) and
#     pkcore, the save-file and Pokemon helpers behind the bank.
# The app only ever sees lr_bridge.h and pkcore.h.
cmake_minimum_required(VERSION 3.18)
project(CapsuleCore C CXX)

set(POKEDAISY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Vendor/pokedaisy" CACHE PATH "PokeDaisy source tree")
if(NOT EXISTS "${POKEDAISY_DIR}/libretro/CMakeLists.txt")
	message(FATAL_ERROR "PokeDaisy not found in ${POKEDAISY_DIR}. Run scripts/build_core.sh, which fetches it.")
endif()
add_subdirectory("${POKEDAISY_DIR}/libretro" pokedaisy EXCLUDE_FROM_ALL)
set(DSPERATE_JIT OFF CACHE BOOL "" FORCE)
# No EGL / OpenGL ES on iOS: the DS core draws its 3D in software.
set(DSPERATE_GLES OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
add_subdirectory("${POKEDAISY_DIR}/linux/libretro-ds" pokedaisy-ds EXCLUDE_FROM_ALL)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(pkcore OBJECT
	pkcore/pk_text.c
	pkcore/pk_mon.c
	pkcore/pk_save.c
	pkcore/pk_live.c
	pkcore/pk_info.c
	pkcore/pk_gb.c
	pkcore/pk_gbdata_gen.c
	pkcore/pk_profiles_gen.c)
target_include_directories(pkcore PUBLIC pkcore)
target_compile_options(pkcore PRIVATE -Wall -Wextra)

add_library(bridge OBJECT bridge/lr_bridge.c)
target_include_directories(bridge PUBLIC bridge)
target_include_directories(bridge PRIVATE "${POKEDAISY_DIR}/third_party/mgba/src/platform/libretro")
target_compile_options(bridge PRIVATE -Wall -Wextra)

add_library(capsulecore STATIC $<TARGET_OBJECTS:bridge> $<TARGET_OBJECTS:pkcore>)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
	enable_testing()
	add_executable(test_pkcore tests/test_pkcore.c)
	target_link_libraries(test_pkcore PRIVATE capsulecore m)
	target_include_directories(test_pkcore PRIVATE pkcore)
	add_test(NAME pkcore COMMAND test_pkcore)

	add_executable(test_pkgb tests/test_pkgb.c)
	target_link_libraries(test_pkgb PRIVATE capsulecore m)
	target_include_directories(test_pkgb PRIVATE pkcore)
	add_test(NAME pkgb COMMAND test_pkgb)

	add_executable(test_bridge tests/test_bridge.c)
	target_link_libraries(test_bridge PRIVATE capsulecore m pthread ${CMAKE_DL_LIBS})
	target_include_directories(test_bridge PRIVATE bridge)
	target_compile_definitions(test_bridge PRIVATE
		GBC_CORE="$<TARGET_FILE:pokedaisy_gbc_libretro>" DS_CORE="$<TARGET_FILE:pokedaisy_ds_libretro>"
		DS_DIAGNOSTIC_SCRIPT="${POKEDAISY_DIR}/linux/dsperate/make_diagnostic.py")
	add_dependencies(test_bridge pokedaisy_gbc_libretro pokedaisy_ds_libretro)
	add_test(NAME bridge COMMAND test_bridge)
endif()

# Builds the C side of the app as two static libraries:
#   - pokedaisy_gbc_libretro.a: PokeDaisy's libretro core (mGBA plus the companion,
#     HUD, quick menu and EXPAND), built from its own CMake file, unchanged
#     except that it is made static (scripts/build_core.sh does that).
#   - libcapsulecore.a: the host for that core (bridge/lr_bridge.c) and pkcore,
#     the save-file and Pokemon helpers behind the bank.
# The app only ever sees lr_bridge.h and pkcore.h.
cmake_minimum_required(VERSION 3.18)
project(CapsuleCore C)

set(POKEDAISY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Vendor/pokedaisy" CACHE PATH "PokeDaisy source tree")
if(NOT EXISTS "${POKEDAISY_DIR}/libretro/CMakeLists.txt")
	message(FATAL_ERROR "PokeDaisy not found in ${POKEDAISY_DIR}. Run scripts/build_core.sh, which fetches it.")
endif()
add_subdirectory("${POKEDAISY_DIR}/libretro" pokedaisy EXCLUDE_FROM_ALL)

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
add_dependencies(capsulecore pokedaisy_gbc_libretro)

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
	target_link_libraries(test_bridge PRIVATE capsulecore pokedaisy_gbc_libretro m pthread)
	target_include_directories(test_bridge PRIVATE bridge)
	add_test(NAME bridge COMMAND test_bridge)
endif()

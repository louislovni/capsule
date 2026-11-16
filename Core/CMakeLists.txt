# Builds everything written in C as one static library, libcapsulecore.a:
#   - mGBA (GBA core only, no optional dependency)
#   - the bridge between mGBA and the app
#   - pkcore, the Pokemon save / memory helpers
# The app only ever sees emu_bridge.h and pkcore.h.
cmake_minimum_required(VERSION 3.16)
project(CapsuleCore C)

set(MGBA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Vendor/mgba" CACHE PATH "mGBA source tree")
if(NOT EXISTS "${MGBA_DIR}/CMakeLists.txt")
	message(FATAL_ERROR "mGBA not found in ${MGBA_DIR}. Run scripts/build_core.sh, which fetches it.")
endif()

set(M_CORE_GBA ON)
set(M_CORE_GB OFF)
set(BUILD_LTO OFF)
set(SKIP_GIT ON)
# EXCLUDE_FROM_ALL puts mGBA in its "library only" mode: static, no frontends, no dependencies.
add_subdirectory("${MGBA_DIR}" mgba EXCLUDE_FROM_ALL)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(pkcore OBJECT
	pkcore/pk_text.c
	pkcore/pk_mon.c
	pkcore/pk_save.c
	pkcore/pk_live.c
	pkcore/pk_profiles_gen.c)
target_include_directories(pkcore PUBLIC pkcore)
target_compile_options(pkcore PRIVATE -Wall -Wextra)

# The bridge includes mGBA headers, whose structures change with mGBA's feature
# switches. Compile it with exactly the definitions mGBA itself was built with.
add_library(bridge OBJECT bridge/emu_bridge.c)
target_include_directories(bridge PUBLIC bridge)
target_include_directories(bridge PRIVATE "${MGBA_DIR}/include" "${CMAKE_CURRENT_BINARY_DIR}/mgba/include")
get_target_property(MGBA_TARGET_DEFS mgba COMPILE_DEFINITIONS)
get_directory_property(MGBA_DIR_DEFS DIRECTORY "${MGBA_DIR}" COMPILE_DEFINITIONS)
if(MGBA_TARGET_DEFS)
	target_compile_definitions(bridge PRIVATE ${MGBA_TARGET_DEFS})
endif()
if(MGBA_DIR_DEFS)
	target_compile_definitions(bridge PRIVATE ${MGBA_DIR_DEFS})
endif()
add_dependencies(bridge mgba)

add_library(capsulecore STATIC
	$<TARGET_OBJECTS:bridge>
	$<TARGET_OBJECTS:pkcore>
	$<TARGET_OBJECTS:mgba>)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
	enable_testing()
	add_executable(test_pkcore tests/test_pkcore.c)
	target_link_libraries(test_pkcore PRIVATE capsulecore m)
	target_include_directories(test_pkcore PRIVATE pkcore)
	add_test(NAME pkcore COMMAND test_pkcore)

	add_executable(test_bridge tests/test_bridge.c)
	target_link_libraries(test_bridge PRIVATE capsulecore m pthread)
	target_include_directories(test_bridge PRIVATE bridge)
	add_test(NAME bridge COMMAND test_bridge)
endif()

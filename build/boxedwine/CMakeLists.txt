cmake_minimum_required(VERSION 3.22)
project(MadeiraWine32 LANGUAGES C CXX)

# This target exercises the native interpreter and full Wine filesystem before
# embedding them in the iOS host. It deliberately has no native-code JIT flags.
set(BOXEDWINE_SOURCE "" CACHE PATH "Pinned source produced by fetch.py")
if(NOT EXISTS "${BOXEDWINE_SOURCE}/.madeira-source-revision")
  message(FATAL_ERROR "Fetch the pinned source with build/boxedwine/fetch.py first")
endif()
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/runtime.json" runtime_manifest)
string(JSON required_revision GET "${runtime_manifest}" source revision)
file(READ "${BOXEDWINE_SOURCE}/.madeira-source-revision" source_revision)
string(STRIP "${source_revision}" source_revision)
if(NOT source_revision STREQUAL required_revision)
  message(FATAL_ERROR "BoxedWine source revision does not match runtime.json")
endif()

find_package(SDL2 REQUIRED)
find_package(ZLIB REQUIRED)
find_package(OpenGL REQUIRED)
find_package(Threads REQUIRED)

set(BW "${BOXEDWINE_SOURCE}")
file(GLOB_RECURSE emulation CONFIGURE_DEPENDS "${BW}/source/emulation/*.cpp")
list(FILTER emulation EXCLUDE REGEX "/cpu/(jit|x32|x64|armv7|armv8|wasm)/")
file(GLOB_RECURSE kernel CONFIGURE_DEPENDS "${BW}/source/kernel/*.cpp")
file(GLOB common CONFIGURE_DEPENDS
  "${BW}/source/io/*.cpp" "${BW}/source/util/*.cpp"
  "${BW}/source/x11/*.cpp" "${BW}/source/vulkan/*.cpp"
  "${BW}/source/opengl/*.cpp" "${BW}/source/opengl/sdl/*.cpp"
  "${BW}/source/sdl/*.cpp" "${BW}/source/sdl/singleThreaded/*.cpp"
  "${BW}/platform/sdl/*.cpp" "${BW}/platform/linux/*.cpp")
# The downloader belongs to upstream's launcher UI, which Madeira replaces.
list(FILTER common EXCLUDE REGEX "/networkutils\\.cpp$")
file(GLOB softfloat CONFIGURE_DEPENDS
  "${BW}/lib/softfloat/source/*.c" "${BW}/lib/softfloat/source/8086-SSE/*.c")
add_library(bw_softfloat STATIC ${softfloat})
target_include_directories(bw_softfloat PRIVATE
  "${BW}/lib/softfloat/source/include" "${BW}/lib/softfloat/source"
  "${BW}/lib/softfloat/source/8086-SSE")

add_executable(madeira-wine32 ${emulation} ${kernel} ${common}
  "${BW}/lib/zlib/contrib/minizip/ioapi.c"
  "${BW}/lib/zlib/contrib/minizip/mztools.c"
  "${BW}/lib/zlib/contrib/minizip/unzip.c"
  "${BW}/lib/zlib/contrib/minizip/zip.c")
target_compile_features(madeira-wine32 PRIVATE cxx_std_20)
target_compile_definitions(madeira-wine32 PRIVATE
  BOXEDWINE_DISABLE_UI BOXEDWINE_64 BOXEDWINE_POSIX BOXEDWINE_ZLIB
  BOXEDWINE_OPENGL_SDL "GLH=<SDL_opengl.h>" SDL2=1 SIMDE_SSE2_NO_NATIVE)
target_include_directories(madeira-wine32 PRIVATE
  "${BW}/include" "${BW}/lib/simde" "${BW}/lib/asmjit"
  "${BW}/lib/zlib/contrib/minizip")
target_compile_options(madeira-wine32 PRIVATE
  $<$<COMPILE_LANGUAGE:CXX>:-Wno-invalid-offsetof>)
target_link_libraries(madeira-wine32 PRIVATE
  bw_softfloat SDL2::SDL2 ZLIB::ZLIB OpenGL::GL Threads::Threads ${CMAKE_DL_LIBS})

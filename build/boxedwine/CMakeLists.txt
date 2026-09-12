cmake_minimum_required(VERSION 3.22)
project(MadeiraWine32 LANGUAGES C CXX)
option(MADEIRA_SANITIZE "Use AddressSanitizer in host execution tests" OFF)

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

find_package(ZLIB REQUIRED)
find_package(Threads REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(BW "${BOXEDWINE_SOURCE}")
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  enable_language(OBJC OBJCXX)
  set(MADEIRA_IOS TRUE)
  set(OSMESA_ROOT "" CACHE PATH "Static OSMesa produced by build/mesa-ios")
  if(NOT EXISTS "${OSMESA_ROOT}/libOSMesa.a")
    message(FATAL_ERROR "Build iOS OSMesa with the matching SDK first")
  endif()
  set(SDL_SHARED OFF CACHE BOOL "" FORCE)
  set(SDL_STATIC ON CACHE BOOL "" FORCE)
  set(SDL_TEST OFF CACHE BOOL "" FORCE)
  set(VIDEO_OPENGL OFF CACHE BOOL "" FORCE)
  set(VIDEO_OPENGLES OFF CACHE BOOL "" FORCE)
  set(VIDEO_VULKAN OFF CACHE BOOL "" FORCE)
  set(RENDER_METAL ON CACHE BOOL "" FORCE)
  string(TOLOWER "${CMAKE_OSX_SYSROOT}" shader_sysroot)
  if(shader_sysroot MATCHES "iphonesimulator")
    set(shader_sdk iphonesimulator)
  else()
    set(shader_sdk iphoneos)
  endif()
  execute_process(COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/build_ios_shaders.py" --source "${BW}" --sdk "${shader_sdk}"
    COMMAND_ERROR_IS_FATAL ANY)
  add_subdirectory("${BW}/lib/sdl2" "${CMAKE_CURRENT_BINARY_DIR}/sdl2")
  target_compile_definitions(SDL2-static PRIVATE SDL_MAIN_HANDLED)
  # This vendored SDL sets a C90 compatibility warning to error even in its
  # Objective-C files. Mixed declarations are valid in the Apple language mode.
  target_compile_options(SDL2-static PRIVATE -Wno-error=declaration-after-statement)
  set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/ios_platform.mm"
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  add_library(madeira-osmesa STATIC IMPORTED)
  set_target_properties(madeira-osmesa PROPERTIES
    IMPORTED_LOCATION "${OSMESA_ROOT}/libOSMesa.a"
    INTERFACE_INCLUDE_DIRECTORIES "${OSMESA_ROOT}/include")
  set(platform_libraries SDL2-static madeira-osmesa "-framework Foundation")
  set(gl_definitions MADEIRA_IOS BOXEDWINE_OPENGL_OSMESA BOXEDWINE_GLHANDLE_ARB_POINTER "GLH=<GL/gl.h>")
  execute_process(COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/prepare_ios.py" --source "${BW}"
    COMMAND_ERROR_IS_FATAL ANY)
else()
  find_package(SDL2 REQUIRED)
  find_package(OpenGL REQUIRED)
  set(platform_libraries SDL2::SDL2 OpenGL::GL)
  set(gl_definitions BOXEDWINE_OPENGL_SDL "GLH=<SDL_opengl.h>")
endif()

execute_process(COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/prepare_embedded.py" --source "${BOXEDWINE_SOURCE}"
  COMMAND_ERROR_IS_FATAL ANY)

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
# The caller owns the host event loop and process lifetime.
list(FILTER common EXCLUDE REGEX "/source/sdl/main\\.cpp$")
list(FILTER common EXCLUDE REGEX "/source/sdl/singleThreaded/mainloop\\.cpp$")
if(MADEIRA_IOS)
  list(FILTER common EXCLUDE REGEX "/source/opengl/sdl/")
  list(APPEND common "${BW}/source/opengl/osmesa/osmesa.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ios_platform.mm")
endif()
file(GLOB softfloat CONFIGURE_DEPENDS
  "${BW}/lib/softfloat/source/*.c" "${BW}/lib/softfloat/source/8086-SSE/*.c")
add_library(bw_softfloat STATIC ${softfloat})
set(softfloat_namespace "${CMAKE_CURRENT_BINARY_DIR}/madeira-softfloat-namespace.h")
execute_process(COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/namespace_softfloat.py" --source "${BW}" --output "${softfloat_namespace}"
  COMMAND_ERROR_IS_FATAL ANY)
add_custom_command(TARGET bw_softfloat POST_BUILD
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/check_softfloat_symbols.py"
    --archive "$<TARGET_FILE:bw_softfloat>"
  VERBATIM)
target_include_directories(bw_softfloat PRIVATE
  "${BW}/lib/softfloat/source/include" "${BW}/lib/softfloat/source"
  "${BW}/lib/softfloat/source/8086-SSE")

add_library(madeira-wine32-engine STATIC ${emulation} ${kernel} ${common}
  "${CMAKE_CURRENT_SOURCE_DIR}/embedded.cpp"
  "${BW}/lib/zlib/contrib/minizip/ioapi.c"
  "${BW}/lib/zlib/contrib/minizip/mztools.c"
  "${BW}/lib/zlib/contrib/minizip/unzip.c"
  "${BW}/lib/zlib/contrib/minizip/zip.c")
target_compile_features(madeira-wine32-engine PRIVATE cxx_std_20)
target_compile_definitions(madeira-wine32-engine PRIVATE
  MADEIRA_EMBEDDED SDL_MAIN_HANDLED
  BOXEDWINE_DISABLE_UI BOXEDWINE_64 BOXEDWINE_POSIX BOXEDWINE_ZLIB
  ${gl_definitions} SDL2=1 SIMDE_SSE2_NO_NATIVE)
target_include_directories(madeira-wine32-engine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}" "${BW}/source/sdl"
  "${BW}/include" "${BW}/lib/simde" "${BW}/lib/asmjit"
  "${BW}/lib/zlib/contrib/minizip")
target_compile_options(madeira-wine32-engine PRIVATE
  -include "${softfloat_namespace}"
  $<$<COMPILE_LANGUAGE:CXX>:-Wno-invalid-offsetof>)
target_link_libraries(madeira-wine32-engine PRIVATE
  bw_softfloat ${platform_libraries} ZLIB::ZLIB Threads::Threads ${CMAKE_DL_LIBS})
if(MADEIRA_SANITIZE)
  target_compile_options(madeira-wine32-engine PRIVATE -fsanitize=address -fno-omit-frame-pointer)
  target_link_options(madeira-wine32-engine INTERFACE -fsanitize=address)
endif()

if(MADEIRA_IOS)
  add_executable(madeira-wine32-ios-link ios_link_smoke.c)
  set_target_properties(madeira-wine32-ios-link PROPERTIES LINKER_LANGUAGE CXX MACOSX_BUNDLE FALSE)
  target_link_libraries(madeira-wine32-ios-link PRIVATE madeira-wine32-engine)
  set(WINE32_PROBE_PAYLOAD "" CACHE PATH "Directory of CI-built x86 Windows fixtures")
  set(WINE32_PROBE_ROOTFS "" CACHE FILEPATH "Complete pinned Wine32 ZIP for iOS execution tests")
  set(WINE32_PROBE_GRAPHICS "" CACHE FILEPATH "Matching guest GL overlay ZIP")
  if(WINE32_PROBE_PAYLOAD AND WINE32_PROBE_ROOTFS)
    if(NOT EXISTS "${WINE32_PROBE_GRAPHICS}")
      message(FATAL_ERROR "The iOS probe requires the matching guest GL overlay")
    endif()
    set(ios_probe "${CMAKE_CURRENT_SOURCE_DIR}/../../tests/wine32/ios")
    add_executable(MadeiraWine32Probe MACOSX_BUNDLE "${ios_probe}/ProbeHost.mm"
      "${WINE32_PROBE_PAYLOAD}" "${WINE32_PROBE_ROOTFS}" "${WINE32_PROBE_GRAPHICS}")
    set_source_files_properties("${WINE32_PROBE_PAYLOAD}" "${WINE32_PROBE_ROOTFS}" "${WINE32_PROBE_GRAPHICS}"
      PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    set_target_properties(MadeiraWine32Probe PROPERTIES
      OBJCXX_STANDARD 20
      MACOSX_BUNDLE_INFO_PLIST "${ios_probe}/Info.plist.in"
      XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
    target_include_directories(MadeiraWine32Probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_compile_options(MadeiraWine32Probe PRIVATE -fobjc-arc)
    target_compile_features(MadeiraWine32Probe PRIVATE cxx_std_20)
    target_link_libraries(MadeiraWine32Probe PRIVATE madeira-wine32-engine
      "-framework UIKit" "-framework QuartzCore")
  endif()
else()
  add_executable(madeira-wine32 embedded_runner.cpp)
  target_compile_features(madeira-wine32 PRIVATE cxx_std_20)
  target_link_libraries(madeira-wine32 PRIVATE madeira-wine32-engine Threads::Threads)
endif()

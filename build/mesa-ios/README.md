# Static softpipe OSMesa for Apple ARM64

This build supplies the native OpenGL software renderer for the planned BoxedWine backend. It does not implement Wine D3D9 translation, start an x86 process, or prove a game renders. The consuming backend must create an OSMesa context, supply its framebuffer, and present the pixels through the app.

Mesa 25.0.7 is pinned by archive SHA256 in `source.json`. This version still contains `src/gallium/targets/osmesa`; Mesa 25.1 removed that target. Every build option was checked against the release's actual `meson_options.txt`. The selected driver is `softpipe`, LLVM and `draw-use-llvm` are disabled, and guest shaders use software interpretation. The build creates ordinary ARM64 code and does not request executable memory for a JIT. Only ARM64 device and ARM64 Simulator slices are supported.

## GitHub Actions

Run on a macOS runner with full Xcode selected and Python **3.12**. Xcode supplies clang, clang++, Objective-C support, the two SDKs, Apple libtool, lipo, nm and vtool. macOS supplies bison and flex; Mesa's source supports the older Apple bison by omitting unsupported warning flags. The script bootstraps pinned Meson 1.7.2, Ninja 1.11.1.4, Mako 1.3.9, MarkupSafe 3.0.2, packaging 24.2 and PyYAML 6.0.2 wheels. Exact wheel URLs and hashes for Python 3.12 on macOS Intel/ARM are in `source.json`; there is no source-package build or network dependency resolution. Downloads always use `OpenAI File Downloader, XaiImageApiFetch/1.0`; pip installs with `--no-index --no-deps`.

```yaml
jobs:
  mesa-ios:
    runs-on: macos-14
    strategy:
      matrix:
        sdk: [iphoneos, iphonesimulator]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - name: Build static OSMesa
        run: bash build/mesa-ios/build.sh --sdk '${{ matrix.sdk }}'
      - uses: actions/upload-artifact@v4
        with:
          name: mesa-softpipe-${{ matrix.sdk }}
          path: build/mesa-ios/out/${{ matrix.sdk }}/
          if-no-files-found: error
```

The script refuses execution outside GitHub Actions. No configuration or compiler invocation was performed on the development Mac. The CI build will be the first compiler validation of this recipe.

The default deployment target is iOS 16.0; change it with `--deployment-target 17.0`, for example. `--output /absolute/directory` changes the artifact destination. Device and Simulator receive separate cross files and build directories. Target compiler flags include both the SDK sysroot and the correct `arm64-apple-ios…[-simulator]` triple. A cross pkg-config stub and `--wrap-mode=nodownload` prevent silently linking the build Mac's Homebrew dependencies. Compression, XML configuration, GPU drivers, window systems and optional tooling are disabled.

## Static packaging and verification

Upstream OSMesa explicitly uses Meson's `shared_library`; setting `default_library=static` alone does not change it. This recipe first builds that target using static Mesa dependencies. The successful intermediate link checks the real transitive dependency graph. It then extracts the exact object/archive inputs from Ninja's link command, expands response files and Darwin file lists, and combines those inputs with Apple `libtool -static`. It never guesses a list of Mesa libraries or packages every archive found in the build tree.

The output contains:

- `libOSMesa.a`: the complete static archive for the requested SDK.
- `include/GL` and `include/KHR`: headers needed by the native consumer.
- `osmesa-link-smoke`: an SDK-specific executable linked against the final archive. Its main function creates a context and clears a framebuffer, but this recipe **does not execute it**.
- `build.json`: source/wheel hashes, SDK/Xcode versions, options, archive hash and constituent inputs.

The recipe verifies ARM64 architecture, required OSMesa and OpenGL symbols, absence of LLVM builder symbols, a link against the completed archive, and the smoke executable's Mach-O platform (`IOS` versus `IOSSIMULATOR`). The smoke link uses the final archive plus Apple system libraries only, which catches missing transitive Mesa archive members. Use a Simulator/device test host to run the renderer before claiming graphics works.

Link `libOSMesa.a` with the app's C++ linker and include these headers. Do not simultaneously link another desktop GL implementation defining the same `gl*` symbols. A Simulator archive is not interchangeable with a device archive despite both reporting ARM64.

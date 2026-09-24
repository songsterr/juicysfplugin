# Single-command build (produces ./out/win_x64/VST2/libjuicysfplugin.dll):
#   DOCKER_BUILDKIT=1 docker buildx build -f win32.Dockerfile \
#     --target output --output type=local,dest=./out .
#
# If you are behind a proxy or your host DNS is unreliable, add:
#   --network=host \
#   --build-arg HTTP_PROXY=$HTTP_PROXY --build-arg HTTPS_PROXY=$HTTPS_PROXY
#
# The classic two-step flow still works if you prefer a tagged image + bundle:
#   DOCKER_BUILDKIT=1 docker build . -f win32.Dockerfile --tag=llvm-mingw
#   ./distribute/bundle_win32.sh 3.1.0
ARG UBUNTU_VER=22.04

FROM ubuntu:$UBUNTU_VER AS wgetter
RUN echo 'Acquire::Retries "10"; Acquire::http::Timeout "30";' > /etc/apt/apt.conf.d/80-retries && \
apt-get update -qq && \
apt-get install -qqy --no-install-recommends \
wget ca-certificates && \
apt-get clean -y && \
rm -rf /var/lib/apt/lists/*

FROM wgetter AS get_llvm_mingw
COPY win32_cross_compile/download_llvm_mingw.sh download_llvm_mingw.sh
ARG LLVM_MINGW_VER=20260616
RUN LLVM_MINGW_VER=$LLVM_MINGW_VER ./download_llvm_mingw.sh download_llvm_mingw.sh

# Fetches Steinberg VST 2.4 headers (aeffect.h, aeffectx.h, vstfxstore.h) that
# JUCE needs to emit a VST2 module. Steinberg discontinued distribution in 2018;
# we pull from public GPL/BSD projects that ship them. This is grey-area
# licensing; the resulting DLL must not be published without a VST2 license
# decision.
# IPv4 first + short timeouts: raw.githubusercontent.com has AAAA records, and
# where the build network's IPv6 egress is broken each file otherwise waits out
# IPv6 connect timeouts (~27 min for the three on builderr).
FROM wgetter AS get_vst2_sdk
RUN mkdir -p /VST2_SDK/pluginterfaces/vst2.x && \
    WGET="wget -q --prefer-family=IPv4 --timeout=30 --tries=3" && \
    $WGET -O /VST2_SDK/pluginterfaces/vst2.x/aeffect.h    https://raw.githubusercontent.com/pac-dev/protoplug/master/Frameworks/vstsdk2.4_minimal/pluginterfaces/vst2.x/aeffect.h && \
    $WGET -O /VST2_SDK/pluginterfaces/vst2.x/aeffectx.h   https://raw.githubusercontent.com/pac-dev/protoplug/master/Frameworks/vstsdk2.4_minimal/pluginterfaces/vst2.x/aeffectx.h && \
    $WGET -O /VST2_SDK/pluginterfaces/vst2.x/vstfxstore.h https://raw.githubusercontent.com/R-Tur/VST_SDK_2.4/master/pluginterfaces/vst2.x/vstfxstore.h

FROM ubuntu:$UBUNTU_VER AS gitter
RUN apt-get update -qq && \
apt-get install -qqy --no-install-recommends \
git ca-certificates && \
apt-get clean -y && \
rm -rf /var/lib/apt/lists/*

FROM gitter AS get_juce
COPY win32_cross_compile/clone_juce.sh clone_juce.sh
RUN ./clone_juce.sh

FROM gitter AS get_fluidsynth
COPY win32_cross_compile/clone_fluidsynth.sh clone_fluidsynth.sh
RUN ./clone_fluidsynth.sh

FROM ubuntu:$UBUNTU_VER AS toolchain
RUN apt-get update -qq && \
apt-get install -qqy --no-install-recommends \
xz-utils cmake build-essential pkg-config && \
apt-get clean -y && \
rm -rf /var/lib/apt/lists/*
COPY --from=get_llvm_mingw llvm-mingw.tar.xz llvm-mingw.tar.xz
RUN mkdir -p /opt/llvm-mingw && tar -xf llvm-mingw.tar.xz --strip-components=1 -C /opt/llvm-mingw && rm llvm-mingw.tar.xz
ENV PATH="/opt/llvm-mingw/bin:$PATH"
COPY win32_cross_compile/x86_64_toolchain.cmake /x86_64_toolchain.cmake
COPY win32_cross_compile/i686_toolchain.cmake /i686_toolchain.cmake
COPY win32_cross_compile/aarch64_toolchain.cmake /aarch64_toolchain.cmake

FROM ubuntu:$UBUNTU_VER AS make_juce
RUN apt-get update -qq && \
apt-get install -qqy --no-install-recommends \
cmake build-essential pkg-config libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libfreetype6-dev libfontconfig1-dev libcurl4-openssl-dev libasound2-dev libglu1-mesa-dev && \
apt-get clean -y && \
rm -rf /var/lib/apt/lists/*
COPY --from=get_juce JUCE JUCE
COPY win32_cross_compile/make_juce.sh make_juce.sh
RUN ./make_juce.sh

FROM wgetter AS msys2_deps
RUN apt-get update -qq && \
apt-get install -qqy --no-install-recommends \
zstd && \
apt-get clean -y && \
rm -rf /var/lib/apt/lists/*
COPY win32_cross_compile/get_fluidsynth_deps.sh get_fluidsynth_deps.sh
RUN ./get_fluidsynth_deps.sh

FROM toolchain AS make_fluidsynth_x86
COPY --from=msys2_deps clang32 clang32
COPY --from=get_fluidsynth fluidsynth fluidsynth
COPY win32_cross_compile/configure_fluidsynth.sh configure_fluidsynth.sh
RUN ./configure_fluidsynth.sh x86
COPY win32_cross_compile/build_fluidsynth.sh build_fluidsynth.sh
RUN ./build_fluidsynth.sh x86

FROM toolchain AS make_fluidsynth_x64
COPY --from=msys2_deps clang64 clang64
COPY --from=get_fluidsynth fluidsynth fluidsynth
COPY win32_cross_compile/configure_fluidsynth.sh configure_fluidsynth.sh
RUN ./configure_fluidsynth.sh x64
COPY win32_cross_compile/build_fluidsynth.sh build_fluidsynth.sh
RUN ./build_fluidsynth.sh x64

FROM toolchain AS juicysfplugin_common
RUN apt-get update -qq && \
apt-get install -qqy --no-install-recommends \
libfreetype6-dev libfontconfig1 && \
apt-get clean -y && \
rm -rf /var/lib/apt/lists/*
COPY --from=make_juce /linux_native/ /linux_native/
COPY --from=msys2_deps /clang64/ /clang64/
COPY --from=make_fluidsynth_x64 /clang64/include/fluidsynth.h /clang64/include/fluidsynth.h
COPY --from=make_fluidsynth_x64 /clang64/include/fluidsynth/ /clang64/include/fluidsynth/
COPY --from=make_fluidsynth_x64 /clang64/lib/pkgconfig/fluidsynth.pc /clang64/lib/pkgconfig/fluidsynth.pc
# FluidSynth 2.5.x installs the static lib as libfluidsynth-3.a (matches
# `Libs: -lfluidsynth-3` in fluidsynth.pc). Older releases used libfluidsynth.a.
COPY --from=make_fluidsynth_x64 /clang64/lib/libfluidsynth-3.a /clang64/lib/libfluidsynth-3.a
COPY win32_cross_compile/fix_mingw_headers.sh fix_mingw_headers.sh
RUN ./fix_mingw_headers.sh
COPY win32_cross_compile/attrib_noop.sh /usr/local/bin/attrib
COPY win32_cross_compile/juce_vst3_helper_noop.sh /usr/local/bin/juce_vst3_helper
RUN chmod +x /usr/local/bin/attrib /usr/local/bin/juce_vst3_helper
WORKDIR juicysfplugin
COPY --from=get_vst2_sdk /VST2_SDK/ /VST2_SDK/
COPY resources/Logo512.png resources/Logo512.png
COPY cmake/Modules/FindPkgConfig.cmake cmake/Modules/FindPkgConfig.cmake
COPY Source/ Source/
COPY JuceLibraryCode/JuceHeader.h JuceLibraryCode/JuceHeader.h
COPY CMakeLists.txt CMakeLists.txt
COPY win32_cross_compile/configure_juicysfplugin.sh configure_juicysfplugin.sh

FROM juicysfplugin_common AS juicysfplugin_x64
RUN /juicysfplugin/configure_juicysfplugin.sh x64
COPY win32_cross_compile/make_juicysfplugin.sh make_juicysfplugin.sh
RUN /juicysfplugin/make_juicysfplugin.sh x64

# Keep the classic distribute stage so ./distribute/bundle_win32.sh 3.1.0
# still works against `docker build --tag=llvm-mingw`.
FROM ubuntu:$UBUNTU_VER AS distribute
COPY --from=juicysfplugin_x64 /juicysfplugin/build_x64/JuicySFPlugin_artefacts/ /x64/

# Final target for BuildKit --output type=local,dest=./out
# Layout mirrors what bundle_win32.sh produces, so downstream tooling is stable.
FROM scratch AS output
COPY --from=juicysfplugin_x64 \
  /juicysfplugin/build_x64/JuicySFPlugin_artefacts/Release/VST/libjuicysfplugin.dll \
  /win_x64/VST2/libjuicysfplugin.dll
COPY --from=juicysfplugin_x64 \
  /juicysfplugin/build_x64/JuicySFPlugin_artefacts/Release/Standalone/juicysfplugin.exe \
  /win_x64/Standalone/juicysfplugin.exe
COPY --from=juicysfplugin_x64 \
  /juicysfplugin/build_x64/JuicySFPlugin_artefacts/Release/VST3/juicysfplugin.vst3/Contents/x86_64-win/juicysfplugin.vst3 \
  /win_x64/VST3/juicysfplugin.vst3
COPY LICENSE.txt /win_x64/LICENSE.txt
COPY licenses_of_dependencies /win_x64/licenses_of_dependencies
COPY distribute/README.x64.txt /win_x64/README.txt

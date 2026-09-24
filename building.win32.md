# Building the Windows VST2 DLL

The `build-fix` branch cross-compiles from Linux to Windows x64 in a fully
self-contained Docker build. Nothing needs to be installed locally beyond
Docker with BuildKit.

## One command

```bash
DOCKER_BUILDKIT=1 docker buildx build -f win32.Dockerfile \
  --target output --output type=local,dest=./out .
```

Output lands in `./out/win_x64/` (VST2, VST3, Standalone, licenses).

First build is slow (~15–40 min) because JUCE and FluidSynth are compiled from
source. Subsequent builds hit the BuildKit layer cache.

## CI

Builderr (`.builderr.yml`) runs the same command on every push and publishes
`libjuicysfplugin.dll` plus its `.sha256` as build artifacts.

## Behind a proxy or with unreliable host DNS

Pass the proxy through and share the host network stack:

```bash
DOCKER_BUILDKIT=1 docker buildx build -f win32.Dockerfile --network=host \
  --build-arg HTTP_PROXY=$HTTP_PROXY --build-arg HTTPS_PROXY=$HTTPS_PROXY \
  --target output --output type=local,dest=./out .
```

## Classic two-step flow

Still supported for the ZIP bundle:

```bash
DOCKER_BUILDKIT=1 docker build . -f win32.Dockerfile --tag=llvm-mingw
./distribute/bundle_win32.sh 3.1.0
```

## What the build does that stock upstream 3.1.0 did not

- Fetches Steinberg VST 2.4 headers from a public GPL/BSD mirror
  (Steinberg no longer distributes them, and the fork must not either).
- Bumps llvm-mingw 20220209 → 20260616 and JUCE 6.1.5 → 7.0.12 so the
  toolchain still finds current msys2 packages.
- Adds `pcre2` and switches `gettext` → `gettext-runtime` in the msys2
  package list; both split after 3.1.0 was tagged.
- Builds FluidSynth with `GLIB_STATIC_COMPILATION` so its object files do
  not reference `__imp_g_*` symbols that a static libglib cannot supply.
- Patches one JUCE 7.0.12 templated constructor that Clang 20+ rejects.
- Symlinks `Windows.h` → `windows.h` for a VST3 SDK sample that assumes a
  case-insensitive filesystem.
- Ships `juce_vst3_helper` and `attrib` no-op shims so JUCE's post-build
  step does not try to run cross-compiled `.exe`s under Linux.

Read the diff against upstream `3.1.0` for the full list.

## Licensing note

The DLL is GPL-3 (JUCE, FluidSynth) plus a VST 2.4 SDK dependency. Steinberg
requires a signed license to distribute new VST2 plugins. Do not publish the
resulting binary without a licensing decision.

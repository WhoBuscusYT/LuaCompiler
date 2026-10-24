Third-party source provenance
=============================

Original LuaCompiler engine orchestration, asset handling, scene/camera math,
render batching, lighting and frame recording are Lua code under runtime/lc.
Native graphics.c is a small SDL3 window/event bridge. Dependencies below are
vendored source and must retain their licenses; they are not LuaCompiler originals.

SDL3
----

- Upstream: https://github.com/libsdl-org/SDL
- Version/tag: release-3.4.10 (SDL-release-3.4.10-0-g8e37db5e7).
- Source: unchanged official SDL dependency source already present in the local
  Z# checkout's CMake dependency cache; copied into third_party/SDL.
- License: SDL zlib license, SDL/LICENSE.txt.
- Windows x64 static /MT build; video/events/timers enabled, native renderers,
  OpenGL, audio, camera and gamepad subsystems disabled for this first backend.
- Vulkan is loaded at runtime from the installed graphics driver.

MoonVulkan
----------

- Upstream: https://github.com/stetre/moonvulkan
- Commit: ff7fc6644e703150a713a9c8575b20eca08fb655 (master snapshot).
- License: MIT, moonvulkan/LICENSE; bundled OpenBSD tree.h keeps its BSD notice.
- Windows x64 /MT static linkage, using upstream's MINGW/Win32 implementation
  paths with MSVC and Lua 5.4.9. Small local portability/safe-loading patches are
  recorded in moonvulkan/LUACOMPILER-PATCHES.md and marked in the source.
- Its constructors.lua helper is bundled under runtime/moonvulkan unchanged.
- The Lua application API targets the replaceable lc.backends.vulkan layer.

Shaders
-------

- Original shader sources: runtime/lc/shaders/default.vert and default.frag.
- Precompiled SPIR-V generated with official Khronos glslang 16.6.0 for Vulkan1.0:
  https://github.com/KhronosGroup/glslang/releases/tag/16.6.0
- Windows development compiler archive was verified against its GitHub release
  asset SHA-256 digest. No shader compiler is required by normal builds/apps.
- Regenerate: glslang -V default.vert -o default.vert.spv, likewise default.frag.

Architecture inspection
-----------------------

The local Z# native SDL3/Vulkan implementation was inspected read-only. Suitable
ideas retained are SDL Vulkan windows, Vulkan swapchain recreation, packed
clip-position/RGBA/UV batches and precompiled SPIR-V. LuaCompiler's renderer and
shaders were written separately; engine policy, cameras, lighting and batching
remain Lua-owned rather than importing Z#'s native renderer.

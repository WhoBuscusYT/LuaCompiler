# LuaCompiler 1.0.0.0

LuaCompiler is a Windows Lua 5.4 application/game packager. It now builds a
single **standalone x64 EXE** for console, native Windows UI, or Vulkan 2D/3D,
containing the standard Lua 5.4 runtime,
project scripts, and assets. The generated app needs no installed Lua, Lua DLL,
C compiler, or external project files. It uses normal Windows system DLLs.
The application and graphics framework is written primarily in Lua. Native
bindings supply Win32 controls, SDL3 windows/input, and Vulkan operations.
Audio and physics engines are not included.

Lua owns packaging, updates, module search policy, UI callbacks, scenes, input,
assets, math, and Vulkan rendering orchestration. The launcher's trusted Lua
bootstrap is embedded when the template is rebuilt, so even console applications
without the framework archive use the same module policy. Native code retains
bundle validation, direct loading from mapped files, operating-system interfaces,
and resource lifetime management. See [the language audit](docs/language-audit.md)
for reproducible source counts and the original/vendor distinction.

## Build a project

The compiler machine needs standard Lua 5.4, Windows PowerShell and curl. The
prebuilt `Launcher.exe` is included; a C compiler is needed only to rebuild that
template. Keep all compiler modules, VERSION, Launcher.exe and its checksum sidecar
together. `luacompiler.cmd` uses the modules beside it and forwards exit codes.

From CMD or PowerShell in your project:

```
luacompiler build
luacompiler build "C:\path with spaces\MyProject" MyApp
luacompiler build "C:\path\MyProject" MyApp scripts/Start.lua
luacompiler version
luacompiler update
```

If the compiler directory is not in PATH, use its full command path. For example
in PowerShell: `& "C:\tools\LuaCompiler\luacompiler.cmd" build`.

The default entry script is exactly `Main.lua`, including case. The optional
third build argument selects another bundled script. Relative project paths are
resolved against the invoking directory. Only the selected entry executes
automatically; other scripts execute when imported or explicitly called.

Output is `build/MyApp.exe` and `build/MyApp.lcb`; the default name is `Game`.
The builder writes a temporary executable, validates the embedded bundle and
compiles the entry without running application code, then publishes it. A failed
build preserves the previous executable. It returns `{Ready=true, Output=...,
Executable=..., Bundle=..., FileCount=..., Entry=...}` only on success.
Programmatic use remains `Compiler.Build(project, {ExeName="MyApp", Entry="Main.lua"})`.

## Application scripts and embedded assets

Example project:

```
MyProject/
    Main.lua
    modules/
        greeting.lua
    assets/
        message.txt
```

```lua
-- Main.lua
local greeting = require("modules.greeting")
print(greeting.message())
local bytes, message = lcb.read("assets/message.txt")
assert(bytes, message)
print(bytes)
print("Your name?")
local name = io.read("*l")
print("Hello", name)
return 0
```

`require("foo.bar")` searches embedded `foo/bar.lua` and then
`foo/bar/init.lua`. Preloaded and standard Lua modules work. Disk searchers,
native C-module searchers and `package.loadlib` are disabled; external Lua
installations cannot silently supply missing project modules. The built-in UI,
SDL3, and MoonVulkan bindings are statically registered. Arbitrary extension DLLs
are not loaded by the embedded module searcher.

`lcb` is global and also available as `require("lcb")`:

- `lcb.read(path)` returns the exact binary contents as a Lua string, or `nil,error`.
- `lcb.exists(path)` returns a boolean.
- `lcb.files()` returns bundled filenames in bundle order.
- `lcb.license` contains Lua's copyright and MIT permission text.

Lua-facing filenames and arguments use UTF-8. Paths must match stored spelling
and case; either slash direction is accepted. No files are extracted. Standard
`io.open`, `loadfile`, and `dofile` remain filesystem APIs; use embedded `require`
and `lcb.read` for bundled content. The standard libraries can deliberately
access the operating system; this is not a sandbox.

`arg[0]` contains the executable path; `arg[1]` onward and entry `...` contain
application arguments. Console input/output use standard streams. Lua errors
print tracebacks and exit 1. An integer entry return value in 0..255 becomes the
process exit status; other successful returns exit 0. `os.exit` retains standard
Lua behavior. UTF-8 BOM and shebang source headers are supported. Scripts are
loaded as source text, not precompiled bytecode.

The launcher reserves `--luacompiler-validate` to check the complete embedded
bundle and compile its entry without executing it; success prints
`LuaCompiler executable valid`. `--luacompiler-license` prints the embedded Lua
license. The raw launcher template supports `--luacompiler-probe` for the builder.

## LCB v1 and executable layout

The existing LCB v1 is unchanged. All integer fields are little-endian with no
padding or terminators:

| Field | Bytes |
| --- | --- |
| Magic `LCB1` | 4 |
| Format version 1, uint32 | 4 |
| File count, uint32 | 4 |
| Each record: path byte length, uint32 | 4 |
| Each record: content byte length, uint64 | 8 |
| Path bytes | path byte length |
| Raw content | content byte length |

Entries are sorted; files are streamed in 64 KiB chunks. Empty files and binary
assets retain exact bytes. Discovery skips `build` and `.git` directories at any
depth, plus `.lcb`/`.exe` files, ignoring case. Links/junctions, traversal,
absolute bundle paths, empty components, reserved names, invalid Windows filename
characters, duplicates and file/directory collisions are refused.

The executable layout is:

```
[static launcher][unchanged LCB v1][UTF-8 entry path][64-byte footer]
```

The footer contains `LCBEXE1\0`, uint64 bundle offset, uint64 bundle size, uint32
entry byte length, uint32 path code page, and 32 SHA-256 bytes over bundle+entry.
The native reader validates offsets, lengths, version, file count, every record,
encoding, unsafe/duplicate/colliding paths, exact consumption and checksum before
execution. Limits: 1 GiB bundle, 100,000 files, 32,768 bytes per path/entry. The
checksum detects corruption; it is not a publisher signature. See
[native/README.md](native/README.md) for the complete format contract.

Stock Windows Lua uses its active ANSI code page for source filesystem names.
Spaces and representable Unicode filenames work; lossy conversions are rejected.
The EXE records that code page so it does not depend on the end user's setting.
Its own executable path and runtime APIs/arguments support Unicode through Windows
wide-character APIs. Full arbitrary-Unicode source discovery still requires a
Unicode-capable compiler-side Lua runtime or filesystem layer.

## Automatic updates and recovery

Each `build` performs one automatic update check. A valid installed compiler
continues building while offline. Failed checks also permit builds if the local
installation is usable. `version` reads local VERSION without networking.
`update` exits nonzero on offline/failed checks; build errors also exit nonzero.

`Updater.UpdateCheck()` returns `{Status, Message, Usable, Version}`. Status is
`current`, `updated`, `offline`, or `failed`; HTTP/configuration errors are failed,
while network-resolution/connection/timeouts are offline. Curl has 5-second
connection and 20-second request limits. Downloads target the directory holding
the updater, so isolated test copies do not overwrite LOCALAPPDATA.

Before release, set VERSION and run:

```
lua tools/release.lua "C:\path\to\LuaCompiler"
```

Publish matching SHA256SUMS and every listed component together, including the
launcher, sidecar and Lua license. Updates verify all hashes, Lua syntax, launcher
PE headers, launcher sidecar and its probe before replacement. Originals are
backed up in `.update-stage`; VERSION is replaced last. Ordinary installation
failures roll back original bytes. A pending transaction blocks builds until
recovered. Multiple file replacements cannot be one filesystem transaction;
power loss/process termination can require recovery. Stop other compiler
processes, then run the source package's tool:

```
lua tools/recover.lua "C:\path\to\installed\LuaCompiler"
```

Checksums over the HTTPS source provide integrity, not signed releases. The
initial `LuaCompiler.lua` bootstrap installer is still a separate downloader.
Older installations must acquire the new launcher files together with the modules.
No live release publication or fresh installer run is part of the automated tests.

## Rebuild the launcher

The official standard Lua 5.4.9 source is vendored under `native/lua-5.4.9`.
Its source archive SHA-256 is
`2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6`.
To rebuild the x64 template, install Visual Studio C++ Build Tools and run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File native/build.ps1
```

The script statically links Lua, SDL3, MoonVulkan, and the MSVC runtime (`/MT`), probes the result,
and updates `Launcher.exe` and `Launcher.exe.sha256`. Applications import only
Windows system DLLs; games load the system Vulkan driver when first used.
Lua's MIT license is included in the source, compiler package,
and generated executable. Re-run `tools/release.lua` before publishing changes.

## Tests

Use new, nonexistent scratch paths. Tests retain their fixtures and reports.
Python is a development-test tool only, never an app or packager dependency.

```
lua tests/run.lua "C:\path\to\LuaCompiler" "C:\scratch\regression"
lua tests/recovery.lua "C:\path\to\LuaCompiler" "C:\scratch\recovery"
python tests/standalone.py "C:\path\to\LuaCompiler" "C:\scratch\standalone"
```

The Lua suite checks recursive discovery, exact extracted bytes, current-directory
builds, output failures, isolated offline/failed/successful updates and recovery.
The independent standalone suite inspects PE imports and overlay bytes, copies
apps alone into unrelated directories with System32-only PATH, tests modules,
assets, console IO, Unicode, selected entries, arguments, errors, exit statuses,
rebuild preservation, and malformed/truncated/corrupted executable rejection.
A separate clean Windows VM and live GitHub release deployment remain untested.

## Native desktop and Vulkan framework

The default build mode remains `console`. Additional modes embed the Lua framework
and shaders from the verified `Runtime.lcb` archive into the application's LCB v1
bundle. Projects must not shadow framework paths such as `lc/ui.lua`.

```
luacompiler build examples/NativeUI NativeUI Main.lua --mode gui
luacompiler build examples/Vulkan2D Vulkan2D Main.lua --mode vulkan2d
luacompiler build examples/Vulkan3D Vulkan3D Main.lua --mode vulkan3d
```

These modes create Windows GUI executables with no console window. Add `--console`
to keep a console during development. A console project can include the framework
with `--runtime`. Programmatic equivalents are `Mode`, `Console`, and `Runtime`
fields in `Compiler.Build(project, config)`. Mode selects packaging and subsystem;
the project chooses its scene/camera through the public API.

- `require('lc.ui')`: native windows, buttons, labels, text inputs, checkboxes,
  dropdowns, menus, dialogs, and Lua callbacks. See [UI API](docs/ui-api.md).
- `require('lc.game')` and `require('lc.scene')`: Lua game loop, input, scenes,
  transforms, cameras, assets, shapes, sprites, meshes, lighting and draw batching.
  See [game API](docs/game-api.md).
- `lc.backends.vulkan`: replaceable MoonVulkan renderer. Actual Vulkan handles
  textured triangles, alpha blending, perspective division, depth, synchronization,
  resize and GPU resources. Scene behavior and render orchestration remain Lua.

The Windows x64 deployment target is Windows 10/11. Console and native UI apps
do not initialize Vulkan. Games require a Vulkan-capable GPU and its installed
Vulkan driver (`vulkan-1.dll` in Windows System32). No Lua, SDL DLL, MoonVulkan DLL,
C compiler, shader compiler, or separate project assets are needed on the end
user's machine. Only this machine's Windows/Intel drivers have been tested so far.

LuaCompiler currently supports BMP/PPM textures, basic OBJ importing, per-vertex
directional/ambient lighting, and embedded default SPIR-V shaders. CPU transforms,
one frame in flight, and adjacent draw batching form the initial implementation.
GPU instancing, general project-defined shader pipelines, PNG/JPEG decoding,
advanced materials, animation, audio and physics remain future work.

Build the native template with the command above; Visual Studio's CMake component
is required for static SDL3. Then regenerate framework and distribution checksums:

```
lua tools/runtime.lua "C:\path\to\LuaCompiler"
lua tools/release.lua "C:\path\to\LuaCompiler"
```

Ship `Runtime.lcb`, its checksum sidecar, and `THIRD-PARTY-LICENSES.txt` alongside
the existing compiler components. The updater stages and validates them before
replacement and still publishes VERSION last. It checks native framework
capabilities so an older console-only launcher cannot silently pass validation.
Normal project builds use the prebuilt launcher and archive.

Third-party sources are separated under `third_party/` and `native/lua-5.4.9` and
marked vendored in `.gitattributes`. See [provenance and local patches](third_party/SOURCES.md).
Generated EXEs contain license notices, available with `--luacompiler-license`
or `lcb.third_party_licenses`.

Additional development checks:

```
lua tests/engine.lua "C:\path\to\LuaCompiler"
lua tests/runtime.lua "C:\path\to\LuaCompiler" "C:\scratch\runtime"
python tests/desktop.py "C:\path\to\LuaCompiler" "C:\scratch\desktop"
```

The desktop suite executes real native controls and real Vulkan 2D/3D frames,
resizes swapchains, captures GPU output, and runs copied executables with only
Windows System32 in PATH. `--self-test --frames 8` runs each game example for a
bounded smoke test; `--capture frame.bmp` saves an actual GPU readback.

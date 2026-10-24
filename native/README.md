# Windows console launcher

`launcher.c` is the console subsystem launcher for LuaCompiler's first standalone
executables. Compile it with the standard Lua 5.4 sources, excluding `lua.c` and
`luac.c`, and link the Lua runtime and C runtime statically. With MSVC use `/MT`
and link `bcrypt.lib` and `shell32.lib`; with MinGW use a static runtime and link
`bcrypt` and `shell32`. No Lua DLL, Lua installation, compiler, or external
project files are needed on the target computer. Windows system DLLs are used.

The target is Windows Vista or newer, subject to the chosen compiler runtime's
own Windows support. The distributed launcher should be built and tested for
the architecture it advertises. The Lua sources retain their own license.

## Executable layout

The build pipeline appends data to the console PE stub:

```
[PE launcher][LCB v1 bundle][UTF-8 entry path][64-byte footer]
```

All integer footer fields are little endian:

| Byte offset | Field |
| --- | --- |
| 0 | 8 bytes `LCBEXE1\0` |
| 8 | uint64 absolute bundle offset |
| 16 | uint64 bundle byte length |
| 24 | uint32 UTF-8 entry path byte length |
| 28 | uint32 Windows code page for LCB path bytes; 0 means current ACP |
| 32 | 32-byte SHA-256 digest of bundle bytes followed by entry path bytes |

The entry path must immediately follow the bundle; the footer must immediately
follow the entry path. LCB v1 remains unchanged: `LCB1`, uint32 version 1, uint32
file count, then records containing uint32 path length, uint64 file length, path
bytes and raw file bytes. Paths written by the existing Windows Lua compiler use
its active code page; record that numeric code page in the footer rather than
relying on the end user's ACP. UTF-8 LCB paths use code page 65001.

Limits are 1 GiB per bundle, 100,000 files, and 32,768 bytes per path or entry
path. The launcher validates bounds, exact record consumption, the checksum,
encoding, relative paths, Windows reserved device names, duplicate paths and
file/directory collisions before creating the Lua state. Integrity checks detect
corruption; the digest is not a publisher signature. Nothing is extracted.

## Lua application contract

The builder chooses a project entry script, defaulting to `Main.lua`. Only this
entry executes automatically. Bundled files retain their exact content bytes.
Scripts are loaded as Lua source text, including Lua's UTF-8 BOM and first-line
shebang handling. The entry receives UTF-8 arguments in
`arg` (`arg[0]` is the executable path), and in `...` without `arg[0]`.
Standard Lua libraries and console input/output are available.

`require("foo.bar")` loads `foo/bar.lua`, then `foo/bar/init.lua` from the bundle.
Preloaded modules work. Disk Lua searchers, native C-module searchers and
`package.loadlib` are disabled; `package.path` and `package.cpath` are empty.
Module and asset paths must match the stored spelling, including case. Paths
accept either slash direction and reject unsafe components. Lua-facing paths
and command-line arguments use UTF-8 even when the bundle used another code page.

The global `lcb` table is also available as `require("lcb")`:

```lua
local bytes, message = lcb.read("assets/sound.bin") -- binary Lua string or nil,error
assert(bytes, message)
assert(lcb.exists("assets/sound.bin"))             -- boolean
for _, path in ipairs(lcb.files()) do print(path) end -- UTF-8 paths, bundle order
```

`io.open` remains a normal filesystem API; use `lcb.read` for embedded assets.
The application may deliberately read/write external files with the standard
libraries; this launcher is not a sandbox. A successful entry with no integer
return value exits 0. An integer return value must be in 0..255 and becomes the
process exit code. Lua failures print a traceback and exit 1. `os.exit` retains
standard Lua behavior, including Lua's platform-specific exit status handling.
The Lua copyright and MIT permission text is embedded in every executable,
available as `lcb.license` and through `--luacompiler-license` (also on the raw
stub, without a project bundle).

## Build validation protocol

The raw stub accepts `--luacompiler-probe`, prints exactly
`LuaCompiler launcher 1 Lua 5.4`, and exits 0. A completed executable accepts
`--luacompiler-validate`, fully validates its embedded bundle and compiles its
entry without executing project code, prints exactly
`LuaCompiler executable valid`, and exits 0. Errors go to stderr and return 1.
Completed applications reject the template probe without executing their entry.
These option strings are reserved by the launcher. Final publishing must occur
only after the temporary executable passes this validation.

## Desktop framework extension

The base template remains a console PE so the original validation protocol stays
compatible. Builder changes the output PE subsystem to Windows GUI for `gui`,
`vulkan2d`, and `vulkan3d` modes, unless a debug console was requested. The CRT entry
point and the LCB v1 overlay/footer do not change. GUI runtime errors show a native
message dialog; reserved diagnostic operations use stderr and exit codes.

`--luacompiler-capabilities` is a second reserved **raw-template-only** probe. The
current template prints `LuaCompiler runtime 1 console gui vulkan2d vulkan3d`.
It initializes neither SDL nor Vulkan. Framework builds and updater validation
require this response in addition to the existing probe/checksum.

`ui.c` implements Win32 operations and queues events without invoking Lua inside
window procedures. `graphics.c` supplies SDL3 window, input and clock operations.
MoonVulkan and SDL3 are static libraries; all three module loaders are registered
lazily in Lua's preload table. The Vulkan driver is loaded from Windows System32
only when the Vulkan backend is required. Console/UI apps have no Vulkan startup
dependency. The current supported deployment target is Windows 10/11 x64.

Framework Lua files and precompiled shaders live under `runtime/`. Rebuild their
flat `Runtime.lcb` with `tools/runtime.lua`; Builder merges its verified records
into the application bundle and refuses project/framework collisions. The runtime
archive and license text are updater components, with VERSION still installed last.

`native/build.ps1` builds Lua plus `graphics-build.ps1` dependencies, then links
the launcher and UI with `/MT`. Use `-SkipGraphics` only after the dependency
libraries are already current. Visual Studio C++ tools and its CMake component
are development requirements; ordinary packaging uses the supplied template.
See `third_party/SOURCES.md` for versions, licenses, portability patches, and shader
rebuilding. Native build products remain under the ignored `native/build/` folder.

## Lua and native boundary

`bootstrap.lua` owns bundled module name resolution and package search policy.
`build.ps1` embeds this trusted source into a generated header under `build/`;
the header is a build product, not a second hand-maintained implementation.
It is part of the launcher template, including for console builds without
`Runtime.lcb`, and cannot be replaced by a project file of the same name.

The bootstrap receives a private C loader that compiles source directly from
the validated memory mapping. It does not copy module contents through
`lcb.read`, reparse the bundle in Lua, or expose a new public loading API.
Bundle bounds, checksums, path encoding, Windows argument conversion, and handle
cleanup remain native. UI callback and scene/render orchestration already live
in `runtime/lc`; the native UI/SDL/Vulkan layers remain platform bindings.

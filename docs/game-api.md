# LuaCompiler games: Lua 5.4, SDL3 and Vulkan

The public game API is Lua. SDL3 supplies a native window, timing and input. The
Vulkan backend submits real Vulkan commands through MoonVulkan. There is no
OpenGL, Direct3D or software-rendering fallback.

The Windows executable includes Lua, SDL3, MoonVulkan, these framework modules,
the default SPIR-V shaders and the project's LCB v1 assets. A compatible Vulkan
loader and graphics driver are operating-system prerequisites; they are not
project files and are not embedded. Normal project builds use the prebuilt
launcher. Building that launcher from source requires the documented native
toolchain.

## First game

```lua
local Game = require('lc.game')
local Scene = require('lc.scene')
local cube

return Game.run {
    title = 'My Lua game', width = 960, height = 600, mode = '3d',
    start = function(game)
        cube = game.scene:entity {
            mesh = Scene.cube(2), color = {0.3, 0.8, 1, 1},
        }
    end,
    update = function(game, delta)
        cube:rotate(0, delta, 0)
        if game.input:pressed('escape') then game:quit() end
    end,
}
```

Build the project with the `vulkan3d` mode described in the main build
documentation. `examples/Vulkan2D` and `examples/Vulkan3D` provide complete
projects. The 3D example draws three textured/lit meshes with perspective and
depth testing. Both examples accept `--frames N` for a bounded run,
`--self-test` for eight frames including a resize, and `--capture output.bmp`
for a GPU-rendered image of the first frame. A capture is saved by the backend
when that frame is rendered; requesting a capture alone does not render a frame.

## Loop and lifecycle

`Game.run(options)` creates the renderer, runs the application, closes its GPU
resources and returns an integer exit code. Returning this value from `Main.lua`
propagates it through the standalone launcher. Lua exceptions still produce a
failed process exit. `Game.new(options):loop()` is the equivalent two-step form.

Options:

| Option | Meaning |
| --- | --- |
| `title`, `width`, `height` | Initial window title and dimensions. |
| `resizable` | Defaults to `true`. |
| `mode` | `'3d'` selects a default perspective camera; otherwise the default camera is orthographic. |
| `scene`, `clear` | Optional initial scene, or default-scene RGBA clear color. |
| `vsync` | Reserved preference; the initial Vulkan backend always uses FIFO (synchronized) presentation. |
| `maxDelta` | Maximum simulation step, in seconds; default `0.1`. Long pauses are clamped. |
| `targetFPS` | Optional additional Lua-side frame pacing. |
| `maxFrames` | Optional positive integer frame limit, useful for smoke tests. |
| `start(game)` | Called once after renderer creation. Create/upload assets here. |
| `update(game, delta)` | Called before each rendered frame. Delta is measured in seconds. |
| `event(game, event)` | Receives every backend event. |
| `afterFrame(game)` | Called after rendering. |
| `stop(game)` | Called after normal loop exit. Renderer cleanup also occurs after errors. |

`game:quit(code)` requests exit with code `0..255`, default `0`.
`game:resize(width, height)` requests a native window resize.
`game:capture(path)` requests a BMP from the next rendered frame.
`game:setScene(scene)` changes the active scene.
`game:close()` is idempotent; normal `run`/`loop` usage closes automatically.
`game.width`, `game.height`, `game.frame`, `game.delta` and `game.elapsed` expose
current viewport and simulation state. Minimized windows do not render frames.

The engine uses a variable time step. It does not implement a physics solver,
fixed-step simulation, audio, a job system or automatic scene serialization.

## Input

`game.input:down(key)`, `:pressed(key)` and `:released(key)` query lower-case SDL
key names, for example `'left'`, `'space'` and `'escape'`. Queries are
case-insensitive. A held/repeated key produces one press transition.

Mouse queries are `:mouseDown(button)`, `:mousePressed(button)` and
`:mouseReleased(button)`, with button `1` as the default. State fields are
`mouseX`, `mouseY`, `mouseDX`, `mouseDY`, `wheelX` and `wheelY`. Press/release and
movement deltas reset each frame. Focus-loss events release held input.

## Scenes, transforms and geometry

```lua
local scene = Scene.new {
    camera = Scene.perspective {
        position = {3, 2, 5}, target = {0, 0, 0},
        fov = math.rad(60), near = 0.1, far = 100,
    },
    clear = {0.025, 0.04, 0.075, 1},
    light = {
        direction = {-0.6, -1, -0.5}, ambient = 0.23, intensity = 0.77,
        color = {1, 1, 1, 1},
    },
}
```

`Scene.perspective` is a right-handed camera that looks toward its `target`;
`up` defaults to `{0,1,0}`. Angles are radians. Projection uses Vulkan depth
`0..1` and preserves homogeneous clip coordinates until the GPU's perspective
divide. `Scene.orthographic{x,y,width,height,near,far}` uses screen coordinates:
the top-left is `(0,0)` and Y increases downwards. Omitted orthographic width and
height track the viewport after resizing.

Create an entity with `scene:entity{...}`. Options are `mesh`, `position`,
`rotation`, `scale`, `color`, `texture`, `layer`, `visible`, `depth`, `lit`,
`transparent`, `parent` and `update(entity, delta, game)`. Position, rotation and
scale are three-element arrays. Color is RGBA in `0..1`. The default transform
is identity; depth testing and lighting default to enabled.

Transforms apply scale, then X/Y/Z rotation, then translation. Parent transforms
compose above child transforms. `entity:setPosition`, `:setRotation`, `:rotate`,
`:setScale`, `:setParent` and `:remove` are conveniences; changing numeric array
elements directly also invalidates the transform cache. Parents must belong to
the same scene, and cycles are rejected. Removing a parent detaches its children.
Nonuniform scaling uses an inverse-transpose normal matrix for lighting; a lit
mesh with a singular/zero scale is rejected.

Built-in meshes are `Scene.cube(size)`, `Scene.rectangle(width,height)` and
`Scene.circle(radius,segments)`. A custom mesh has this structure:

```lua
local mesh = {vertices = {
    -- x, y, z, normal-x, normal-y, normal-z, u, v
    {-1, -1, 0, 0, 0, 1, 0, 1},
    { 1, -1, 0, 0, 0, 1, 1, 1},
    { 0,  1, 0, 0, 0, 1, 0.5, 0},
}}
```

Each three vertices form one triangle. UV `(0,0)` addresses the top-left of the
texture. `scene:sprite{width,height,texture,...}` creates an unlit rectangle with
depth testing disabled. Supply `mesh = Scene.circle(...)` for a circle instead.
Sprite rotation uses `rotation = {0,0,angle}`. Sprites support scaling, RGBA
alpha and layers.

Increasing `layer` values draw later. Opaque 3D objects draw before transparent
ones within a layer. Transparent 3D entities are sorted by camera distance,
retain depth testing and disable depth writes. Set `transparent = true` for a
texture with alpha, because the engine cannot infer its intended material use.
Object-level sorting does not correctly solve every intersecting or
self-overlapping translucent mesh. Use separate layers/materials where needed.
2D sprites always preserve layer/insertion order and use alpha blending.

`scene.stats` contains `entities`, `triangles` and `batches` from the last
generated frame. An entity with no mesh can serve as a transform parent.

## Assets and materials

`game.assets:read('relative/path')` returns raw bytes. A standalone game reads
through `lcb.read`; it does not need loose project assets. When these modules are
run under a development Lua interpreter without `lcb`, reads use the current
directory. Asset paths must be relative, use `/`, and contain no traversal.

`game.assets:texture(path)` decodes and caches uncompressed Windows BMP
(24/32-bit) or binary P6 PPM (8-bit RGB) images and uploads RGBA pixels. BMP row
padding, top-down/bottom-up order and 32-bit alpha are handled. PNG/JPEG and
compressed BMP are not supported. Limits are 8192 pixels per dimension and
16,777,216 pixels total.

`game.assets:upload{width,height,pixels}` uploads a raw RGBA byte string.
`game.assets:checker(width,height,cell,colorA,colorB)` creates a procedural
texture; checker colors are four **byte** values `0..255`, unlike entity colors.
Textures expose `width`, `height` and an opaque backend `handle`.

`game.assets:mesh(path)` imports OBJ positions, normals, UVs and faces. It
supports positive/negative indices and triangle-fan conversion of convex faces.
Absent normals are generated per triangle. Concave polygon tessellation,
material libraries, animation, skeletal skinning and other mesh formats are not
implemented. Bytes, mesh data and textures are cached by path. `:clearCache()`
drops Lua cache references; GPU allocations stay owned by the renderer until it
closes.

Directional plus ambient lighting is calculated per vertex in Lua. The Vulkan
fragment shader samples the texture and multiplies its color/alpha by the
interpolated vertex color. There are no shadows or physically based materials.
An optional entity `shade(vertex)` callback returns an RGBA color, and receives
world `position`, world `normal` (when lit), `color` and `uv`. This is a Lua
material callback, not a general GPU shader-language compiler. The default
vertex/fragment SPIR-V programs are embedded framework assets; project-defined
GPU pipeline/shader interfaces remain future work.

## Backend boundary and performance

`Game.new{backend = otherBackend}` selects an object exposing `new(config)`.
The resulting renderer implements `size`, `poll`, `time`, `sleep`, `render`,
`texture`, `resize`, `capture` and `close` as methods. The default is
`require('lc.backends.vulkan')`.

`render(commands,clearRGBA)` receives triangle batches. Each command contains
`vertices` (a packed little-endian float32 string), `texture` (or `nil`), `depth`
and `depthWrite`. Each vertex is 40 bytes: homogeneous clip `x,y,z,w`, color
`r,g,b,a`, then `u,v`. `depthWrite = false` retains testing when `depth = true`.
This boundary keeps scene logic independent of the specific Lua/Vulkan binding.

Lua caches unchanged entity transforms and merges adjacent draws with matching
texture/depth state. The backend owns Vulkan synchronization, image layouts,
swapchain recreation and resource destruction. The first implementation favors
correct cleanup and simple synchronization over peak throughput. Geometry is
transformed, lit and packed on the CPU each frame; GPU instancing, retained
geometry buffers and multiple frames in flight are not implemented. Large scenes
will need profiling and a richer batching interface before production use.

## Tests

`lua tests/engine.lua <compiler-root>` tests matrix conventions, normals, scene
ordering, input, BMP/PPM/OBJ handling, cleanup and both example scripts against a
deterministic fake backend. These tests are **not** proof of GPU rendering.
Separate standalone Vulkan example runs and captures are required to verify
the native integration on an actual driver. Refer to the current development
test report for the runs that were actually executed and their limitations.

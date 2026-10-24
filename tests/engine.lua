-- Run with Lua 5.4: lua tests/engine.lua ABSOLUTE_COMPILER_ROOT
local root = assert(arg[1], 'Pass the compiler root directory')
package.path = root .. '/runtime/?.lua;' .. package.path
local Math, Input = require('lc.math'), require('lc.input')
local Assets, Scene, Game = require('lc.assets'), require('lc.scene'), require('lc.game')
local checks = 0
local function check(value, message)
    assert(value, message or 'Check failed')
    checks = checks + 1
end
local function rejects(callback, message)
    local ok = pcall(callback)
    check(not ok, message or 'Expected an error')
end
local function near(a, b)
    return math.abs(a - b) < 1e-5
end

local point = Math.transform(Math.compose({3, 4, 5}, {0, 0, math.pi / 2}, {2, 3, 4}), {1, 0, 0})
check(near(point[1], 3) and near(point[2], 6) and near(point[3], 5), 'TRS transform order')
local matrix = Math.perspective(math.rad(60), 16 / 9, 0.1, 100)
local nearPoint, farPoint = Math.transform(matrix, {0, 0, -0.1}), Math.transform(matrix, {0, 0, -100})
check(near(nearPoint[3] / nearPoint[4], 0), 'Vulkan near depth is zero')
check(near(farPoint[3] / farPoint[4], 1), 'Vulkan far depth is one')
check(Math.transform(matrix, {0, 1, -2})[2] < 0, 'Perspective Y flipped for Vulkan viewport')
local ortho = Math.orthographic(0, 800, 0, 600, -1000, 1000)
local top, bottom = Math.transform(ortho, {0, 0, 0}), Math.transform(ortho, {800, 600, 0})
check(near(top[1], -1) and near(top[2], -1) and near(top[3], 0.5), '2D top-left')
check(near(bottom[1], 1) and near(bottom[2], 1), '2D bottom-right')
local viewed = Math.transform(Math.lookAt({0, 0, 5}, {0, 0, 0}), {0, 0, 0})
check(near(viewed[3], -5), 'Look-at camera')
local transformedNormal = Math.transformNormal(Math.normalMatrix(Math.scaling(2, 1, 3)), {1, 1, 0})
check(near(transformedNormal[1] / transformedNormal[2], 0.5), 'Inverse transpose normal with nonuniform scale')
local normalModel = Math.compose({1, 2, 3}, {0.7, 1, 0.3}, {2, 3, 4})
local actualNormal = Math.transformNormal(Math.normalMatrix(normalModel), {1, -1, 1})
check(near(Math.dot(actualNormal, Math.transform(normalModel, {1, 1, 0}, 0)), 0)
    and near(Math.dot(actualNormal, Math.transform(normalModel, {0, 1, 1}, 0)), 0),
    'Rotated nonuniformly scaled normals remain perpendicular to both surface tangents')
rejects(function() Math.normalize({0, 0, 0}) end)
rejects(function() Math.perspective(0, 1, 0.1, 10) end)
rejects(function() Math.perspective(1, 0, 0.1, 10) end)
rejects(function() Math.perspective(1, 1, 1, 0.1) end)
rejects(function() Math.number(0 / 0) end)
rejects(function() Math.normalMatrix(Math.scaling(0, 1, 1)) end)

local input = Input.new()
input:feed {type = 'key', key = 'Space', down = true}
check(input:down('SPACE') and input:pressed('space'), 'Platform key normalization')
input:beginFrame()
input:feed {type = 'key', key = 'space', down = true}
check(input:down('space') and not input:pressed('space'), 'Repeated keys do not press twice')
input:feed {type = 'keyup', key = 'space'}
check(input:released('space') and not input:down('space'), 'Key release')
input:feed {type = 'mousebutton', button = 1, down = true}
check(input:mouseDown() and input:mousePressed(), 'Mouse button')
input:feed {type = 'mousemove', x = 10, y = 15}
input:feed {type = 'mousemove', x = 15, y = 12}
check(input.mouseDX == 15 and input.mouseDY == 12, 'Mouse deltas accumulate')
input:feed {type = 'mousewheel', x = 1, y = -2}
check(input.wheelX == 1 and input.wheelY == -2, 'Mouse wheel')
input:feed {type = 'blur'}
check(not input:mouseDown() and input:mouseReleased(), 'Focus loss releases held input')
input:beginFrame()
check(not input:released('space') and input.mouseDX == 0 and input.wheelY == 0, 'Per-frame state reset')

local function bmp(width, height, bits, pixels)
    return 'BM' .. string.pack('<I4I2I2I4', 54 + #pixels, 0, 0, 54)
        .. string.pack('<I4i4i4I2I2I4I4i4i4I4I4', 40, width, height, 1, bits, 0, #pixels, 0, 0, 0, 0)
        .. pixels
end
local bitmap = bmp(1, 2, 24, '\255\0\0\0' .. '\0\0\255\0')
local decoded = Assets.decodeBMP(bitmap)
check(decoded.width == 1 and decoded.height == 2, 'BMP dimensions')
check(decoded.pixels == '\255\0\0\255\0\0\255\255', 'BMP BGR, padded rows and bottom-up conversion')
check(Assets.decodeBMP(bmp(1, -1, 32, '\1\2\3\4')).pixels == '\3\2\1\4', 'Top-down BMP alpha')
for length = 0, #bitmap - 1 do
    rejects(function() Assets.decodeBMP(bitmap:sub(1, length)) end, 'Truncated BMP rejected')
end
rejects(function() Assets.decodeBMP(bmp(0, 1, 24, '')) end)
local ppm = Assets.decodePPM('P6\n# texture\n2 1\n255\n\255\0\0\0\255\0')
check(ppm.pixels == '\255\0\0\255\0\255\0\255', 'PPM decoding')
rejects(function() Assets.decodePPM('P6 1 1 255\n\0') end)
local obj = 'v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\nf -4/1 -3/2 -2/3 -1/4\n'
local mesh = Assets.decodeOBJ(obj)
check(#mesh.vertices == 6, 'OBJ polygon triangulation and relative indexes')
check(mesh.vertices[1][6] == 1 and mesh.vertices[1][8] == 1, 'OBJ generated normal and flipped texture V')
check(#Assets.decodeOBJ('v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 0 1\nf 1//1 2//1 3//1').vertices == 3,
    'OBJ explicit normals without UVs')
rejects(function() Assets.decodeOBJ('v 0 0 0\nf 1 2 3') end)
rejects(function() Assets.decodeOBJ('v 0 0 0\nf 1 1 1') end)
rejects(function() Assets.decodeOBJ('v 0 0 0') end)
local uploaded, reads = 0, 0
local assets = Assets.new({texture = function(_, w, h, bytes)
    check(#bytes == w * h * 4, 'Uploaded RGBA size')
    uploaded = uploaded + 1
    return uploaded
end}, function(path) reads = reads + 1; return bitmap end)
local texture = assets:texture('assets/test.bmp')
check(assets:texture('assets/test.bmp') == texture and reads == 1 and uploaded == 1, 'Asset cache')
check(assets:checker(4, 4, 2).width == 4, 'Procedural texture')
for _, path in ipairs({'../a', '/a', 'a//b', 'C:/a', 'a\\b', './a', 'a/../b'}) do
    rejects(function() assets:read(path) end, 'Unsafe asset path rejected')
end

local scene = Scene.new()
local first = scene:sprite {width = 100, height = 100, position = {100, 100, 0}, layer = 1}
local second = scene:sprite {width = 20, height = 20, position = {200, 200, 0}, layer = 2}
local commands = scene:commands(800, 600)
check(#commands == 1 and #commands[1].vertices == 12 * 40 and not commands[1].depth, '2D triangle batching')
local x, y, z, w = string.unpack('<ffff', commands[1].vertices)
check(near(x, -0.875) and near(y, -5 / 6) and near(z, 0.5) and w == 1, 'Packed 2D clip coordinates')
second.texture = {handle = 27}
commands = scene:commands(800, 600)
check(#commands == 2 and commands[2].texture == 27, 'Textures split batches while preserving layers')
first.layer = 3
check(scene:commands(800, 600)[1].texture == 27, 'Layer order')
second.visible = false
check(#scene:commands(800, 600) == 1 and scene.stats.entities == 1, 'Hidden entities')
check(scene:commands(400, 300)[1].vertices ~= commands[1].vertices, 'Camera adapts to resize')
local parent = scene:entity {position = {10, 0, 0}}
first:setParent(parent)
check(first:matrix()[13] == 110, 'Parent transform')
local cached = first:matrix()
check(first:matrix() == cached, 'Unchanged transform cache')
parent.position[1] = 20
check(first:matrix()[13] == 120 and first:matrix() ~= cached, 'Parent change invalidates cache')
rejects(function() parent:setParent(first) end, 'Parent cycle rejected')
rejects(function() first:setParent(Scene.new():entity()) end, 'Cross-scene parent rejected')
parent:remove()
check(first.parent == nil and first:matrix()[13] == 100, 'Removed parents detach children')
first:remove()
check(#scene.entities == 1, 'Entity removal')
check(#Scene.circle(10, 8).vertices == 24, 'Circle triangles')
check(#Scene.cube(2).vertices == 36, 'Six cube faces')
rejects(function() Scene.rectangle(-1, 1) end)
rejects(function() Scene.circle(10, 2) end)

local scene3d = Scene.new {camera = Scene.perspective(), light = {direction = {0, 0, -1}, ambient = 0.2, intensity = 0.8}}
scene3d:entity {mesh = Scene.cube(2)}
commands = scene3d:commands(800, 600)
check(#commands == 1 and commands[1].depth and #commands[1].vertices == 36 * 40, '3D depth command')
local _, _, depth, homogeneous, r, g, b = string.unpack('<fffffff', commands[1].vertices)
check(homogeneous > 1 and depth / homogeneous > 0 and depth / homogeneous < 1, 'Real homogeneous 3D perspective')
check(near(r, 1) and near(g, 1) and near(b, 1), 'Front face directional lighting')
local _, _, _, _, back = string.unpack('<fffff', commands[1].vertices, 6 * 40 + 1)
check(near(back, 0.2), 'Back face ambient lighting')
check(scene3d.stats.triangles == 12, '3D triangle count')
local transparentNear = scene3d:entity {mesh = Scene.cube(), color = {1, 0, 0, 0.4},
    position = {0, 0, 2}, texture = {handle = 101}}
local transparentFar = scene3d:entity {mesh = Scene.cube(), color = {0, 1, 0, 0.4},
    position = {0, 0, -2}, texture = {handle = 102}}
commands = scene3d:commands(800, 600)
check(commands[1].depthWrite and commands[2].texture == 102 and commands[3].texture == 101,
    'Opaque first; transparent objects sorted far to near')
check(commands[2].depth and not commands[2].depthWrite and commands[3].depth and not commands[3].depthWrite,
    'Transparent 3D tests existing depth without writing depth')

local function backend(events)
    local state = {closed = 0, rendered = 0, time = 0, width = 800, height = 600, slept = 0}
    return {new = function()
        return {
            size = function() return state.width, state.height end,
            time = function() state.time = state.time + 0.016; return state.time end,
            sleep = function(_, amount) state.slept = state.slept + amount end,
            poll = function() local result = events or {}; events = nil; return result end,
            render = function(_, list)
                state.rendered = state.rendered + 1
                state.firstCommands = state.firstCommands or list
                state.commands = list
            end,
            texture = function() return 1 end,
            resize = function(_, width, height) state.width, state.height = width, height end,
            capture = function(_, path) state.capture = path end,
            close = function() state.closed = state.closed + 1 end,
        }
    end}, state
end
local driver, state = backend()
local starts, stops, updates = 0, 0, 0
local result = Game.run {backend = driver, maxFrames = 4, targetFPS = 30,
    start = function(game) starts = starts + 1; game.scene:sprite {width = 10, height = 10} end,
    update = function(game, delta)
        updates = updates + 1
        check(delta >= 0 and delta <= 0.1, 'Bounded delta time')
        if updates == 2 then game:resize(640, 480) end
    end,
    stop = function(game) stops = stops + 1; check(game.width == 640, 'Public resize') end,
}
check(result == 0 and starts == 1 and stops == 1 and updates == 4, 'Game callbacks and bounded run')
check(state.closed == 1 and state.rendered == 4, 'Normal GPU cleanup exactly once')
check(state.slept > 0, 'Frame pacing')
driver, state = backend()
local originalCreate, submissions = driver.new, 0
driver.new = function()
    local renderer = originalCreate()
    local render = renderer.render
    renderer.render = function(self, list)
        submissions = submissions + 1
        if submissions == 1 then return false end -- e.g. swapchain out-of-date
        render(self, list)
        return true
    end
    return renderer
end
check(Game.run {backend = driver, maxFrames = 3, start = function(game) game:capture('frame.bmp') end} == 0,
    'Capture and skipped swapchain frame run')
check(state.rendered == 3 and submissions == 4, 'Skipped submissions do not count as rendered frames')
check(state.capture == 'frame.bmp', 'Public GPU capture forwards requested path')
driver, state = backend()
rejects(function() Game.run {backend = driver, update = function() error('injected update failure') end} end)
check(state.closed == 1, 'GPU cleanup after Lua failure')
driver, state = backend()
local originalNew = driver.new
driver.new = function()
    local renderer = originalNew()
    renderer.render = function() error('injected Vulkan submission failure') end
    return renderer
end
rejects(function() Game.run {backend = driver} end)
check(state.closed == 1, 'GPU cleanup after backend submission failure')
driver, state = backend()
rejects(function() Game.run {backend = driver, start = function() error('injected startup failure') end} end)
check(state.closed == 1, 'GPU cleanup after application startup failure')
driver, state = backend {{type = 'quit'}}
check(Game.run {backend = driver} == 0 and state.rendered == 0 and state.closed == 1, 'Native quit event')
driver, state = backend()
check(Game.run {backend = driver, start = function(game) game:quit(23) end} == 23, 'Game exit code')
driver, state = backend()
local game = Game.new {backend = driver}
game:close(); game:close()
check(state.closed == 1, 'Idempotent close')
rejects(function() game:loop() end)
rejects(function() Game.new {backend = driver, width = 0} end)
rejects(function() Game.arguments {'--frames', '0'} end)
check(Game.arguments {'--self-test'}.maxFrames == 8, 'Bounded smoke test flag')

-- Exercise complete example scripts against a deterministic fake renderer.
-- These checks validate Lua orchestration, not Vulkan or display output.
local previousBackend, previousLCB, previousArg, previousPrint = package.loaded['lc.backends.vulkan'], lcb, arg, print
for _, name in ipairs({'Vulkan2D', 'Vulkan3D'}) do
    driver, state = backend()
    package.loaded['lc.backends.vulkan'] = driver
    lcb = {read = function(path)
        local file = assert(io.open(root .. '/examples/' .. name .. '/' .. path, 'rb'))
        local bytes = assert(file:read('a'))
        file:close()
        return bytes
    end}
    arg = {'--self-test'}
    local report
    print = function(message) report = message end
    local ok, code = pcall(assert(loadfile(root .. '/examples/' .. name .. '/Main.lua')))
    print = previousPrint
    check(ok and code == 0, 'Example orchestration: ' .. name .. ': ' .. tostring(code))
    check(state.rendered == 8 and state.closed == 1, 'Example frames and cleanup: ' .. name)
    check(report and report:match('_OK frames=8'), 'Example self-check callback: ' .. name)
    check(state.firstCommands[1].vertices ~= state.commands[1].vertices, 'Animated example geometry: ' .. name)
end
package.loaded['lc.backends.vulkan'], lcb, arg = previousBackend, previousLCB, previousArg
print(('PASS %d Lua engine checks'):format(checks))

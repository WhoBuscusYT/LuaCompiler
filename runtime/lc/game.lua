-- Public game loop. A backend is replaceable without changing scene/game code.
local Scene = require('lc.scene')
local Assets = require('lc.assets')
local Input = require('lc.input')
local Math = require('lc.math')
local Game = {}
Game.__index = Game

local function positiveInteger(value, name)
    assert(math.type(value) == 'integer' and value > 0, name .. ' must be a positive integer')
    return value
end

function Game.new(options)
    options = options or {}
    local width = positiveInteger(options.width or 960, 'Width')
    local height = positiveInteger(options.height or 540, 'Height')
    local targetFPS = options.targetFPS
    if targetFPS then assert(Math.number(targetFPS) > 0, 'Target FPS must be positive') end
    local maxDelta = Math.number(options.maxDelta or 0.1)
    assert(maxDelta > 0, 'Maximum delta time must be positive')
    if options.maxFrames then positiveInteger(options.maxFrames, 'Maximum frames') end
    local scene = options.scene or Scene.new({camera = options.mode == '3d'
        and Scene.perspective() or Scene.orthographic(), clear = options.clear})
    assert(getmetatable(scene) == Scene, 'Expected a LuaCompiler scene')
    local backend = options.backend or require('lc.backends.vulkan')
    assert(type(backend) == 'table' and type(backend.new) == 'function', 'Invalid graphics backend')
    local renderer = backend.new({width = width, height = height,
        title = options.title or 'LuaCompiler', resizable = options.resizable ~= false,
        vsync = options.vsync ~= false, validation = options.validation == true})
    local self = setmetatable({renderer = renderer, options = options, width = width, height = height,
        running = false, closed = false, exitCode = 0, frame = 0, elapsed = 0, delta = 0,
        input = Input.new(), maxDelta = maxDelta, targetFPS = targetFPS}, Game)
    self.assets = Assets.new(renderer, options.readAsset)
    self.scene = scene
    return self
end

function Game:setScene(scene)
    assert(getmetatable(scene) == Scene, 'Expected a LuaCompiler scene')
    self.scene = scene
    return scene
end

function Game:quit(code)
    code = code or 0
    assert(math.type(code) == 'integer' and code >= 0 and code <= 255,
        'Application exit code must be an integer from 0 to 255')
    self.exitCode, self.running = code, false
end

function Game:resize(width, height)
    positiveInteger(width, 'Width'); positiveInteger(height, 'Height')
    assert(not self.closed, 'Game is closed')
    assert(self.renderer.resize, 'The selected graphics backend does not support programmatic resize')
    self.renderer:resize(width, height)
end

function Game:capture(path)
    assert(not self.closed, 'Game is closed')
    assert(type(path) == 'string' and #path > 0 and not path:find('%z'), 'Invalid capture output path')
    assert(self.renderer.capture, 'The selected graphics backend does not support image capture')
    self.renderer:capture(path)
end

function Game:close()
    if self.closed then return end
    self.closed, self.running = true, false
    self.assets:clearCache()
    self.renderer:close()
end

function Game:step(delta)
    assert(not self.closed, 'Game is closed')
    self.delta = Math.clamp(Math.number(delta), 0, self.maxDelta)
    self.elapsed = self.elapsed + self.delta
    self.input:beginFrame()
    local events = self.renderer:poll()
    for _, event in ipairs(events) do
        self.input:feed(event)
        if self.options.event then self.options.event(self, event) end
    end
    if self.input.quit then self:quit(); return false end
    self.width, self.height = self.renderer:size()
    if self.width <= 0 or self.height <= 0 then
        self.renderer:sleep(10)
        return false
    end
    if self.options.update then self.options.update(self, self.delta) end
    if not self.running then return false end
    self.scene:update(self.delta, self)
    if not self.running then return false end
    local rendered = self.renderer:render(self.scene:commands(self.width, self.height), self.scene.clear)
    if rendered == false then return false end
    self.frame = self.frame + 1
    if self.options.afterFrame then self.options.afterFrame(self) end
    if self.options.maxFrames and self.frame >= self.options.maxFrames then self:quit() end
    return true
end

function Game:loop()
    assert(not self.closed and not self.running, 'Game has already started or closed')
    self.running = true
    local ok, failure = xpcall(function()
        if self.options.start then self.options.start(self) end
        local previous = self.renderer:time()
        while self.running do
            local now = self.renderer:time()
            self:step(now - previous)
            previous = now
            if self.targetFPS and self.running then
                local remaining = 1 / self.targetFPS - (self.renderer:time() - now)
                if remaining > 0 then self.renderer:sleep(math.floor(remaining * 1000)) end
            end
        end
        if self.options.stop then self.options.stop(self) end
    end, debug.traceback)
    local cleaned, cleanupFailure = pcall(self.close, self)
    if not ok then
        if not cleaned then failure = failure .. '\nRenderer cleanup also failed: ' .. tostring(cleanupFailure) end
        error(failure, 0)
    end
    if not cleaned then error(cleanupFailure, 0) end
    return self.exitCode
end

function Game.run(options)
    return Game.new(options):loop()
end

-- Common example switches, also useful for bounded CI smoke runs.
function Game.arguments(arguments)
    local result, index = {}, 1
    while arguments and index <= #arguments do
        if arguments[index] == '--frames' then
            result.maxFrames = positiveInteger(assert(tonumber(arguments[index + 1]),
                '--frames requires a number'), 'Maximum frames')
            index = index + 1
        elseif arguments[index] == '--self-test' then
            result.selfTest = true
        elseif arguments[index] == '--capture' then
            result.capture = assert(arguments[index + 1], '--capture requires an output BMP path')
            index = index + 1
        end
        index = index + 1
    end
    if result.selfTest and not result.maxFrames then result.maxFrames = 8 end
    return result
end

return Game

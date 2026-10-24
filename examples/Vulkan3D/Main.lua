local Game = require('lc.game')
local Scene = require('lc.scene')
local flags = Game.arguments(arg)
local cube, satellite, resized

return Game.run {
    title = 'LuaCompiler - Vulkan 3D', width = 960, height = 600, mode = '3d',
    maxFrames = flags.maxFrames,
    start = function(game)
        game:setScene(Scene.new {
            camera = Scene.perspective {position = {3.2, 2.2, 5}, target = {0, 0, 0}, near = 0.1, far = 100},
            clear = {0.025, 0.04, 0.075, 1},
            light = {direction = {-0.6, -1, -0.5}, ambient = 0.23, intensity = 0.77},
        })
        local texture = game.assets:texture('assets/checker.bmp')
        cube = game.scene:entity {mesh = Scene.cube(2), texture = texture,
            rotation = {0.2, 0.35, 0}, color = {1, 0.95, 0.85, 1}}
        satellite = game.scene:entity {mesh = Scene.cube(0.6),
            position = {2, 0, 0}, color = {0.3, 0.8, 1, 1}}
        game.scene:entity {mesh = Scene.cube(1), position = {0, -1.5, 0},
            scale = {5, 0.12, 5}, color = {0.3, 0.35, 0.42, 1}}
    end,
    update = function(game, delta)
        if game.input:pressed('escape') then game:quit(); return end
        if flags.capture and game.frame == 0 then game:capture(flags.capture) end
        cube:rotate(delta * 0.35, delta * 0.65, delta * 0.12)
        satellite:setPosition(math.cos(game.elapsed) * 2.5, math.sin(game.elapsed * 1.7) * 0.5,
            math.sin(game.elapsed) * 2.5)
        satellite:rotate(delta, delta * 0.7, 0)
        if game.input:down('left') then game.scene.camera.position[1] = game.scene.camera.position[1] - delta * 2 end
        if game.input:down('right') then game.scene.camera.position[1] = game.scene.camera.position[1] + delta * 2 end
        if flags.selfTest and game.frame == 2 and not resized then game:resize(820, 560); resized = true end
    end,
    stop = function(game)
        if flags.selfTest then
            assert(game.frame >= 3, 'The graphics smoke test requires at least three frames')
            assert(game.scene.stats.triangles == 36, 'Expected three real 3D cube meshes')
            print('VULKAN3D_OK frames=' .. game.frame .. ' triangles=' .. game.scene.stats.triangles)
        end
    end,
}

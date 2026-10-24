local Game = require('lc.game')
local Scene = require('lc.scene')
local flags = Game.arguments(arg)
local sprite, orbit, circle, resized

return Game.run {
    title = 'LuaCompiler - Vulkan 2D', width = 960, height = 540,
    maxFrames = flags.maxFrames, clear = {0.035, 0.055, 0.09, 1},
    start = function(game)
        local texture = game.assets:texture('assets/checker.bmp')
        sprite = game.scene:sprite {texture = texture, width = 140, height = 140,
            position = {270, 270, 0}, color = {1, 1, 1, 0.9}, layer = 2}
        orbit = game.scene:sprite {width = 100, height = 100, position = {0, 0, 0},
            color = {0.95, 0.35, 0.18, 0.7}, layer = 3}
        circle = game.scene:sprite {mesh = Scene.circle(80, 64), position = {650, 270, 0},
            color = {0.1, 0.75, 0.95, 0.8}, layer = 1}
        game.scene:sprite {width = 920, height = 3, position = {480, 465, 0},
            color = {0.3, 0.45, 0.65, 1}, layer = 0}
    end,
    update = function(game, delta)
        if game.input:pressed('escape') then game:quit(); return end
        if flags.capture and game.frame == 0 then game:capture(flags.capture) end
        local movement = (game.input:down('right') and 1 or 0) - (game.input:down('left') and 1 or 0)
        sprite.position[1] = sprite.position[1] + movement * delta * 220
        sprite:rotate(0, 0, delta * 0.7)
        orbit:setPosition(game.width / 2 + math.cos(game.elapsed * 1.2) * 140,
            game.height / 2 + math.sin(game.elapsed * 1.2) * 100, 0)
        orbit:rotate(0, 0, -delta)
        local scale = 1 + math.sin(game.elapsed * 2) * 0.15
        circle:setScale(scale, scale, 1)
        if flags.selfTest and game.frame == 2 and not resized then game:resize(800, 500); resized = true end
    end,
    stop = function(game)
        if flags.selfTest then
            assert(game.frame >= 3, 'The graphics smoke test requires at least three frames')
            assert(game.scene.stats.triangles >= 70 and game.scene.stats.batches >= 2)
            print('VULKAN2D_OK frames=' .. game.frame .. ' triangles=' .. game.scene.stats.triangles)
        end
    end,
}

-- CosmoLife -- configuration for the LOVE runtime.

function love.conf(t)
    t.identity = "cosmolife"
    t.version = "11.4"
    t.console = false

    t.window.title = "CosmoLife"
    t.window.width = 1280
    t.window.height = 720
    t.window.minwidth = 960
    t.window.minheight = 540
    t.window.resizable = true
    t.window.vsync = 1
    t.window.msaa = 0          -- the retro look prefers hard polygon edges
    t.window.depth = 0         -- we render into our own depth canvas
    t.window.highdpi = true

    t.modules.joystick = true
    t.modules.physics = false  -- all physics in this game is bespoke
    t.modules.touch = false
    t.modules.video = false
end

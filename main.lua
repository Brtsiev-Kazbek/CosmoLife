-- CosmoLife -- entry point.
--
--   love .            run the game
--   luajit tests/run.lua   run the head-less test suite
--
-- Everything below this file is plain Lua modules under src/; nothing is
-- loaded from disk at runtime except this source, because every asset in the
-- game -- ships, cities, planets, sounds -- is generated.

local Game = require("src.game")
local Menu = require("src.states.menu")

local game
local selftest, frame

function love.load(args)
    love.graphics.setDefaultFilter("nearest", "nearest", 1)
    love.graphics.setLineStyle("rough")
    love.keyboard.setKeyRepeat(true)

    game = Game.new()
    game.manager:push(Menu.new())

    -- `love . --new` skips the title screen, which is handy while developing;
    -- `love . --selftest` drives the scripted smoke test in tests/selftest.lua
    for _, a in ipairs(args or {}) do
        if a == "--new" then
            game:newGame(os.time() % 1e7, "Jameson")
            local Flight = require("src.states.flight")
            game.manager:switch(Flight.new())
        elseif a == "--selftest" then
            selftest = require("tests.selftest")
            frame = 0
        end
    end
end

function love.update(dt)
    if selftest then
        frame = frame + 1
        -- a fixed step keeps the scripted run reproducible
        game:update(1 / 60)
        selftest.run(game, frame)
        return
    end
    game:update(dt)
end

function love.draw() game:draw() end

function love.resize(w, h) game:resize(w, h) end

function love.keypressed(key, scancode, isrepeat) game:keypressed(key, scancode, isrepeat) end
function love.keyreleased(key) game:keyreleased(key) end
function love.textinput(text) game:textinput(text) end
function love.mousepressed(x, y, b) game:mousepressed(x, y, b) end
function love.mousereleased(x, y, b) game:mousereleased(x, y, b) end
function love.mousemoved(x, y, dx, dy) game:mousemoved(x, y, dx, dy) end
function love.wheelmoved(x, y) game:wheelmoved(x, y) end

--- A crash should tell you what broke without dumping you to a black screen.
function love.errorhandler(msg)
    msg = tostring(msg)
    local trace = debug.traceback("", 2)
    io.write("\nERROR: ", msg, "\n", trace, "\n")
    io.flush()

    -- an automated run has nobody to press a key: fail loudly and stop
    if selftest then
        love.event.quit(1)
        return
    end

    if not love.window or not love.graphics or not love.event then return end
    if not love.graphics.isActive() and not love.graphics.getCanvas() then
        if not love.window.isOpen() then return end
    end

    love.graphics.reset()
    love.graphics.setCanvas()
    love.graphics.setShader()
    love.graphics.setColor(1, 1, 1, 1)
    local font = love.graphics.setNewFont(14)

    local text = table.concat({
        "CosmoLife hit an error.",
        "",
        msg,
        "",
        trace,
        "",
        "ESC to quit, R to return to the title screen.",
    }, "\n")

    local function draw()
        local w = love.graphics.getWidth()
        love.graphics.clear(0.05, 0.04, 0.06)
        love.graphics.setColor(0.95, 0.7, 0.65, 1)
        love.graphics.printf(text, 40, 40, w - 80)
        love.graphics.present()
    end

    while true do
        love.event.pump()
        for e, a in love.event.poll() do
            if e == "quit" then return
            elseif e == "keypressed" and a == "escape" then return
            elseif e == "keypressed" and a == "r" then
                local Menu = require("src.states.menu")
                game = Game.new()
                game.manager:push(Menu.new())
                return
            end
        end
        draw()
        if love.timer then love.timer.sleep(0.02) end
    end
end

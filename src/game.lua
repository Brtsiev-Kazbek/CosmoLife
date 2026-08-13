-- The game object: owns the shared services and routes LOVE's callbacks into
-- the state stack.

local class = require("src.lib.class")
local config = require("src.config")
local Renderer = require("src.render.renderer")
local Camera = require("src.render.camera")
local Sky = require("src.render.sky")
local ui = require("src.ui.widgets")
local hud = require("src.render.hud")
local World = require("src.sim.world")
local Manager = require("src.states.manager")
local settings = require("src.settings")
local input = require("src.input")
local lighting = require("src.render.lighting")
local flux = require("lib.flux")

local Game = class("Game")

function Game:init()
    ui.load()
    settings.load()
    input.load()
    self.renderer = Renderer.new()
    self.camera = Camera.new()
    self.camera.fov = config.render.fov
    self.sky = Sky.new(1337)
    self.lightingPreset = settings.get("lightingPreset")
    self:applySettings()
    self.manager = Manager.new(self)
    self.world = nil
    self.showHelp = false
    self.debug = false
    self.fps = 0
    self.frameTime = 0
end

--- Starts a brand new commander.
function Game:newGame(seed, name)
    self.world = World.new({ seed = seed })
    self.world.player.name = name or "Commander"
    local start = self.world.galaxy:findStartSystem()
    self.world:enterSystem(start)
    self.world.player:addLog("Commission granted. Ship assigned.", 0, "info")
    hud.clear()
    return self.world
end

--- Loads the save file; returns ok, message.
function Game:loadGame()
    local world = World.new({})
    local ok, err = world:readSave()
    if not ok then return false, err end
    self.world = world
    hud.clear()
    return true
end

function Game:saveGame()
    if not self.world then return false, "nothing to save" end
    return self.world:writeSave()
end

-- ---------------------------------------------------------------------------
-- LOVE callbacks
-- ---------------------------------------------------------------------------

--- Pushes persisted settings into the live systems.  Called at startup and
--- whenever the settings screen changes something.
function Game:applySettings()
    local r = self.renderer
    r.settings.post = settings.get("post")
    r.settings.scanline = settings.get("scanline")
    r.settings.vignette = settings.get("vignette")
    r.settings.aberration = settings.get("aberration")
    r.env.bands = settings.get("lightBands")
    self.lightingPreset = settings.get("lightingPreset")
    self.camera.fov = math.rad(settings.get("fov"))
    self.camera.mode = settings.get("defaultView")
end

--- Applies the current lighting preset for this frame's sun direction.
function Game:applyLighting()
    lighting.apply(self.renderer.env, self.lightingPreset or "cinematic", self.camera)
    -- a preset may override the band count; the explicit setting wins
    self.renderer.env.bands = settings.get("lightBands")
end

function Game:update(dt)
    -- a long stall (window drag, disk hitch) must not teleport the ship
    dt = math.min(dt, 1 / 20)
    input.update()
    flux.update(dt)
    self.frameTime = self.frameTime * 0.9 + dt * 0.1
    self.fps = love.timer.getFPS()
    hud.update(dt)
    self.manager:update(dt)
end

function Game:draw()
    self.manager:draw()
    if self.debug then self:drawDebug() end
end

function Game:drawDebug()
    local r = self.renderer
    local lines = {
        string.format("fps %d   frame %.1f ms", self.fps, self.frameTime * 1000),
        string.format("draws %d   tris %d", r.stats.draws, r.stats.triangles),
    }
    if self.world then
        lines[#lines + 1] = string.format("day %.2f   system %s", self.world.day,
            self.world.stub and self.world.stub.name or "-")
    end
    love.graphics.setFont(ui.font("small"))
    for i, l in ipairs(lines) do
        love.graphics.setColor(0, 0, 0, 0.6)
        love.graphics.rectangle("fill", 8, 8 + (i - 1) * 15, ui.font("small"):getWidth(l) + 8, 15)
        love.graphics.setColor(0.6, 1, 0.8, 1)
        love.graphics.print(l, 12, 8 + (i - 1) * 15)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function Game:resize(w, h)
    self.renderer:resize(w, h)
    self.manager:resize(w, h)
end

function Game:keypressed(key, scancode, isrepeat)
    if key == "f10" then
        local SettingsState = require("src.states.settings")
        self.manager:push(SettingsState.new(), self.manager:current())
        return
    end
    if key == "f11" then
        local full = love.window.getFullscreen()
        love.window.setFullscreen(not full)
        return
    end
    if key == "f3" then self.debug = not self.debug return end
    if key == "f4" then
        self.renderer.settings.post = not self.renderer.settings.post
        return
    end
    if key == "f2" then
        self.renderer.settings.wireframe = not self.renderer.settings.wireframe
        return
    end
    self.manager:keypressed(key, scancode, isrepeat)
end

function Game:keyreleased(key) self.manager:keyreleased(key) end
function Game:textinput(t) self.manager:textinput(t) end
function Game:mousepressed(x, y, b) self.manager:mousepressed(x, y, b) end
function Game:mousereleased(x, y, b) self.manager:mousereleased(x, y, b) end
function Game:mousemoved(x, y, dx, dy) self.manager:mousemoved(x, y, dx, dy) end
function Game:wheelmoved(x, y) self.manager:wheelmoved(x, y) end

return Game

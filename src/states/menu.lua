-- Title screen.
--
-- The background is a live 3D scene rather than a picture: a procedurally
-- generated ship turning slowly over a procedurally generated world, which is
-- an honest advertisement for what the game is made of.

local class = require("src.lib.class")
local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local Rng = require("src.lib.rng")
local shipsGen = require("src.procgen.ships")
local bodies = require("src.render.bodies")

local Menu = class("MenuState")

local C = palette.colors

function Menu:init() self.drawUnderlying = false end

function Menu:enter()
    self.time = 0
    self.seed = os.time and os.time() % 100000 or 4242
    local roles = shipsGen.roles
    local rng = Rng.new(self.seed, "title")
    self.showcase = shipsGen.generate(rng:int(1, 1e6), rng:pick(roles))
    self.body = {
        seed = rng:int(1, 1e6),
        terrain = rng:pick({ "terran", "desert", "ice", "volcanic", "barren", "toxic" }),
        radius = 3.2e6,
        atmosphere = 0.8,
        type = "terran",
        giant = false,
    }
    self.shipPos = vec3(0, 0, 0)
    self.shipBasis = { right = vec3(1, 0, 0), up = vec3(0, 1, 0), fwd = vec3(0, 0, -1) }

    self:buildMenu()
end

function Menu:buildMenu()
    local items = {}
    items[#items + 1] = { label = "New commander", action = function() self:newGame() end }
    local World = require("src.sim.world")
    self.hasSave = World.new({}):hasSave()
    items[#items + 1] = {
        label = "Continue", disabled = not self.hasSave,
        action = function() self:loadGame() end,
    }
    items[#items + 1] = { label = "Controls", action = function() self.showHelp = not self.showHelp end }
    items[#items + 1] = { label = "Quit", action = function() love.event.quit() end }
    self.menu = ui.menu(items, { visible = 6 })
end

function Menu:newGame()
    local seed = math.floor((os.time and os.time() or 1) % 1e7)
    self.game:newGame(seed, "Jameson")
    local Flight = require("src.states.flight")
    self.manager:switch(Flight.new())
end

function Menu:loadGame()
    local ok, err = self.game:loadGame()
    if not ok then
        self.error = "Could not load: " .. tostring(err)
        return
    end
    local Flight = require("src.states.flight")
    self.manager:switch(Flight.new())
end

function Menu:update(dt)
    self.time = self.time + dt
end

function Menu:keypressed(key)
    if key == "escape" then
        if self.showHelp then self.showHelp = false return end
        love.event.quit()
        return
    end
    if self.menu then self.menu:keypressed(key) end
end

function Menu:draw()
    local renderer = self.game.renderer
    local camera = self.game.camera
    local w, h = renderer.width, renderer.height
    local t = self.time

    -- a slowly turning ship in orbit over a planet
    local env = renderer.env
    env.sunDir:set(-0.55, -0.35, -0.75):normalize()
    env.sunColor = { 1.0, 0.95, 0.88 }
    env.ambient = { 0.10, 0.11, 0.15 }
    env.atmos = 0
    env.fogAmount = 0
    env.nebula = 1
    env.worldUp:set(0, 1, 0)

    camera.pos:set(math.sin(t * 0.08) * 26, 7 + math.sin(t * 0.14) * 2.5, 34)
    local fwd = vec3(-camera.pos.x, -camera.pos.y + 1.5, -camera.pos.z):normalize()
    camera.fwd:copyFrom(fwd)
    camera.up:set(0, 1, 0)
    mat4.orthonormalize(camera.right, camera.up, camera.fwd)

    local b = self.shipBasis
    b.fwd:set(math.sin(t * 0.16), math.sin(t * 0.07) * 0.12, math.cos(t * 0.16))
    b.up:set(math.sin(t * 0.09) * 0.13, 1, 0)
    mat4.orthonormalize(b.right, b.up, b.fwd)

    renderer:beginFrame(camera)
    renderer:draw(self.showcase.model, self.shipPos, b, { scale = 18 / math.max(self.showcase.length, 1) })
    -- planet far below
    local planetPos = vec3(camera.pos.x * 0.2, -self.body.radius - 900000, -self.body.radius * 0.6)
    renderer:draw(bodies.planet(self.body, 48), planetPos, nil, { scale = self.body.radius })
    local atmo = bodies.atmosphere(self.body)
    if atmo then
        renderer:draw(atmo, planetPos, nil, {
            scale = self.body.radius * 1.03, additive = true, alpha = 0.5, layer = renderer.LAYER_FAR,
        })
    end
    renderer:endFrame(function()
        self.game.sky:draw(camera, w, h, 1)
    end)
    renderer:present()

    -- title
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", 0, h * 0.5 - 190, 460, 380)
    love.graphics.setColor(1, 1, 1, 1)

    ui.text("COSMOLIFE", 60, h * 0.5 - 170, C.uiPrimary, "title")
    ui.text("an elite in an endless galaxy", 66, h * 0.5 - 96, C.uiDim, "normal")
    ui.rule(66, h * 0.5 - 64, 320)

    if self.menu then self.menu:draw(90, h * 0.5 - 40, 300, 34, "large") end

    ui.text("v" .. config.version, 66, h - 54, C.uiDim, "small")
    ui.text(self.showcase.roleName .. " class  -  " .. self.showcase.name, 66, h - 34, C.uiDim, "small")

    if self.error then
        ui.text(self.error, 66, h * 0.5 + 130, C.uiDanger, "small")
    end

    if self.showHelp then
        local lines = {
            "W S            pitch",
            "A D            roll",
            "Q E            yaw",
            "R F            throttle up / down",
            "Z X            full / zero throttle",
            "SHIFT          boost",
            "J (hold)       frame shift cruise",
            "SPACE          fire",
            "T / Y / G      target / hostile / scan",
            "L              landing gear",
            "ENTER          dock or enter",
            "U              disembark on foot",
            "TAB            galaxy map",
            "N / C / I      log / colonies / ship",
            "V              cockpit or chase view",
            "F5 / F9        save / load",
            "F1             this list in flight",
        }
        local pw = 420
        local ph = #lines * 19 + 60
        local px, py = w - pw - 60, (h - ph) * 0.5
        ui.panel(px, py, pw, ph, "CONTROLS")
        for i, l in ipairs(lines) do
            ui.text(l, px + 24, py + 34 + (i - 1) * 19, C.uiText, "small")
        end
    end
end

return Menu

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
local input = require("src.input")
local i18n = require("src.i18n")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local Rng = require("src.lib.rng")
local shipsGen = require("src.procgen.ships")
local bodies = require("src.render.bodies")

local Menu = class("MenuState")

local C = palette.colors
local L = i18n.format

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
    -- offset to the right of the title panel so the two do not fight for the
    -- same part of the frame
    self.shipPos = vec3(9, 0, 0)
    self.shipBasis = { right = vec3(1, 0, 0), up = vec3(0, 1, 0), fwd = vec3(0, 0, -1) }

    self:buildMenu()
end

function Menu:buildMenu()
    local items = {}
    items[#items + 1] = { label = L("New commander"), action = function() self:newGame() end }
    local World = require("src.sim.world")
    self.hasSave = World.new({}):hasSave()
    items[#items + 1] = {
        label = L("Continue"), disabled = not self.hasSave,
        action = function() self:loadGame() end,
    }
    items[#items + 1] = { label = L("Controls"), action = function() self.showHelp = not self.showHelp end }
    items[#items + 1] = { label = L("Quit"), action = function() love.event.quit() end }
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
        self.error = L("Could not load: {reason}", { reason = tostring(err) })
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

    -- Framing.
    --
    -- The showcase used to sit 34 units from a ship normalised to 18 units
    -- long, which filled two thirds of the frame; and its yaw swept through
    -- zero, so at the top of every cycle the camera was staring at a hull's
    -- flat stern -- a white rectangle with no silhouette to read. It is now
    -- framed at a distance proportional to the ship, off to the right of the
    -- title panel, and the yaw is biased so it never presents a flat face.
    local shipLength = 16
    local scale = shipLength / math.max(self.showcase.length, 1)
    local dist = shipLength * 2.9

    local orbit = math.sin(t * 0.08) * 0.35
    camera.pos:set(math.sin(orbit) * dist, 5.5 + math.sin(t * 0.14) * 1.6, math.cos(orbit) * dist)
    local fwd = vec3(-camera.pos.x, -camera.pos.y + 1.0, -camera.pos.z):normalize()
    camera.fwd:copyFrom(fwd)
    camera.up:set(0, 1, 0)
    mat4.orthonormalize(camera.right, camera.up, camera.fwd)

    -- three-quarter view: yaw swings around 0.9 rad rather than through zero
    local yaw = 0.9 + math.sin(t * 0.13) * 0.5
    local b = self.shipBasis
    b.fwd:set(math.sin(yaw), math.sin(t * 0.07) * 0.10, math.cos(yaw))
    b.up:set(math.sin(t * 0.09) * 0.13, 1, 0)
    mat4.orthonormalize(b.right, b.up, b.fwd)

    renderer:beginFrame(camera)
    renderer:draw(self.showcase.model, self.shipPos, b, { scale = scale })
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
    -- the backdrop has to reach the version and showcase lines at the bottom,
    -- which at any height above 488 used to sit outside it on the bare 3D view
    local boxTop = h * 0.5 - 190
    local boxH = math.max(380, h - 14 - boxTop)
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", 0, boxTop, 480, boxH)
    love.graphics.setColor(1, 1, 1, 1)

    ui.text("COSMOLIFE", 60, h * 0.5 - 170, C.uiPrimary, "title")
    ui.text(L("an elite in an endless galaxy"), 66, h * 0.5 - 96, C.uiDim, "normal")
    ui.rule(66, h * 0.5 - 64, 320)

    if self.menu then self.menu:draw(90, h * 0.5 - 40, 300, 34, "large") end

    ui.text("v" .. config.version, 66, h - 54, C.uiDim, "small")
    ui.textFit(L("{class} class  -  {name}",
        { class = L(self.showcase.roleName), name = self.showcase.name }),
        66, h - 34, 400, C.uiDim, "small")

    if self.error then
        ui.paragraph(self.error, 66, h * 0.5 + 130, 400, C.uiDanger, "small")
    end

    if self.showHelp then
        -- built from the live bindings, so it cannot drift out of date the way
        -- the hand-written list it replaced had
        local rows = input.controlRows(input.flightHelp)
        local pw = math.min(460, w - 520)
        local ph = #rows * 18 + 60
        local px, py = w - pw - 40, (h - ph) * 0.5
        ui.panel(px, py, pw, ph, L("CONTROLS"))
        for i, r in ipairs(rows) do
            local ry = py + 34 + (i - 1) * 18
            ui.text(L(r[1]), px + 24, ry, C.uiText, "small")
            ui.textRight(r[2], px + pw - 24, ry, C.uiPrimary, "small")
        end
    end
end

return Menu

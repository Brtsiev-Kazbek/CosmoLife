-- The galaxy map.
--
-- Drawn in 2D on purpose: a projected top-down chart with a height rail for
-- the third axis is far easier to plot a route on than a rotating 3D cloud,
-- and it is what the genre's players expect.  Panning is unbounded, because
-- so is the galaxy.

local class = require("src.lib.class")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local factions = require("src.sim.factions")
local i18n = require("src.i18n")
local commodities = require("src.sim.commodities")
local hud = require("src.render.hud")

local Map = class("GalaxyMapState")

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local C = palette.colors
local L = i18n.format

function Map:init()
    self.drawUnderlying = false
end

function Map:enter(flight)
    self.flight = flight
    self.world = self.game.world
    self.player = self.world.player
    local here = self.world.stub
    self.cx, self.cy, self.cz = here.x, here.y, here.z
    self.scale = 5.5                -- pixels per light year
    self.selected = here
    self.showRange = true
    self:refresh()
end

-- How far above and below the plane the chart looks.  The disc is thin, so
-- this covers everything reachable while keeping the sector sweep 2D-ish.
local SLAB = 44

function Map:refresh()
    local radius = min((love.graphics.getWidth() * 0.5) / self.scale + 20, 240)
    self.systems = self.world.galaxy:systemsNear(self.cx, self.cy, self.cz, radius, SLAB)
    self.jumpRange = self.player.stats.jumpRange or 10
    self._viewKey = string.format("%.0f,%.0f,%.0f,%.3f", self.cx, self.cy, self.cz, self.scale)
end

--- Rebuilds the visible set only when the view actually moved.
function Map:refreshIfMoved()
    local key = string.format("%.0f,%.0f,%.0f,%.3f", self.cx, self.cy, self.cz, self.scale)
    if key ~= self._viewKey then self:refresh() end
end

function Map:screenOf(sys, w, h)
    local x = w * 0.5 + (sys.x - self.cx) * self.scale
    local y = h * 0.5 + (sys.z - self.cz) * self.scale
    return x, y
end

function Map:update(dt)
    self.world:update(dt)
    local pan = 90 / self.scale * dt * 60
    if love.keyboard.isDown("left", "a") then self.cx = self.cx - pan end
    if love.keyboard.isDown("right", "d") then self.cx = self.cx + pan end
    if love.keyboard.isDown("up", "w") then self.cz = self.cz - pan end
    if love.keyboard.isDown("down", "s") then self.cz = self.cz + pan end
    if love.keyboard.isDown("pageup") then self.cy = self.cy + pan end
    if love.keyboard.isDown("pagedown") then self.cy = self.cy - pan end
    self:refreshIfMoved()
end

function Map:nearestToCursor(w, h)
    local mx, my = love.mouse.getPosition()
    local best, bestD = nil, 26
    for _, s in ipairs(self.systems) do
        local x, y = self:screenOf(s, w, h)
        local d = sqrt((x - mx) ^ 2 + (y - my) ^ 2)
        if d < bestD then best, bestD = s, d end
    end
    return best
end

function Map:keypressed(key)
    if config.is("map", key) or config.is("pause", key) then
        self.manager:pop()
        return
    end
    if key == "return" or key == "space" then
        self:jump()
        return
    end
    if key == "=" or key == "+" or key == "kp+" then
        self.scale = min(self.scale * 1.35, 40)
        self:refresh()
    elseif key == "-" or key == "kp-" then
        self.scale = max(self.scale / 1.35, 0.4)
        self:refresh()
    elseif key == "home" then
        local here = self.world.stub
        self.cx, self.cy, self.cz = here.x, here.y, here.z
        self.selected = here
        self:refresh()
    elseif key == "r" then
        self.showRange = not self.showRange
    end
end

function Map:mousepressed(x, y, button)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local s = self:nearestToCursor(w, h)
    if s then
        self.selected = s
        if button == 2 then self:jump() end
    end
end

function Map:wheelmoved(x, y)
    if y > 0 then self.scale = min(self.scale * 1.2, 40)
    elseif y < 0 then self.scale = max(self.scale / 1.2, 0.4) end
    self:refresh()
end

function Map:jump()
    local target = self.selected
    if not target or target.id == self.world.stub.id then
        hud.message("Already here", "warn")
        return
    end
    local ok, msg = self.world:jump(target)
    if ok then
        hud.message(msg, "good")
        self.manager:pop()
        if self.flight then
            self.flight.npcs = {}
            self.flight.stationMeshes = {}
            self.flight:leaveSurface()
            self.flight:spawn({})
            self.flight.target = nil
        end
    else
        hud.message(msg, "alert")
    end
end

function Map:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.clear(0.015, 0.02, 0.03, 1)

    local here = self.world.stub

    -- jump range ring around the current system
    if self.showRange then
        local hx, hy = self:screenOf(here, w, h)
        ui.setColor(C.uiPrimary, 0.16)
        love.graphics.circle("fill", hx, hy, self.jumpRange * self.scale)
        ui.setColor(C.uiPrimary, 0.5)
        love.graphics.circle("line", hx, hy, self.jumpRange * self.scale)
    end

    -- grid
    ui.setColor(C.uiLine, 0.10)
    local step = 10 * self.scale
    if step > 8 then
        local ox = (w * 0.5 - self.cx * self.scale) % step
        local oy = (h * 0.5 - self.cz * self.scale) % step
        for x = ox, w, step do love.graphics.line(x, 0, x, h) end
        for y = oy, h, step do love.graphics.line(0, y, w, y) end
    end

    -- systems
    for _, s in ipairs(self.systems) do
        local x, y = self:screenOf(s, w, h)
        if x > -20 and x < w + 20 and y > -20 and y < h + 20 then
            local faction = factions.get(s.factionId)
            local col = faction.color
            local dy = (s.y - self.cy)
            -- height rail: the stalk shows the third axis
            ui.setColor(C.uiLine, 0.25)
            love.graphics.line(x, y, x, y - dy * self.scale)

            local r = util.clamp(2 + math.log(1 + s.population) * 0.22, 2, 8)
            local visited = self.player.knownSystems[s.id] ~= nil
            love.graphics.setColor(col[1], col[2], col[3], visited and 1 or 0.5)
            love.graphics.circle("fill", x, y - dy * self.scale, r)

            if s.id == here.id then
                ui.setColor(C.uiPrimary, 1)
                love.graphics.circle("line", x, y - dy * self.scale, r + 6)
                love.graphics.circle("line", x, y - dy * self.scale, r + 9)
            end
            if self.selected and s.id == self.selected.id then
                ui.setColor(C.uiWarn, 1)
                love.graphics.rectangle("line", x - r - 7, y - dy * self.scale - r - 7, (r + 7) * 2, (r + 7) * 2)
            end
            if self.scale > 2.4 then
                love.graphics.setColor(col[1], col[2], col[3], visited and 0.9 or 0.4)
                love.graphics.setFont(ui.font("small"))
                love.graphics.print(s.name, floor(x + r + 5), floor(y - dy * self.scale - 7))
            end
        end
    end

    -- route line
    if self.selected and self.selected.id ~= here.id then
        local hx, hy = self:screenOf(here, w, h)
        local sx, sy = self:screenOf(self.selected, w, h)
        local dist = sqrt((self.selected.x - here.x) ^ 2 + (self.selected.y - here.y) ^ 2 + (self.selected.z - here.z) ^ 2)
        ui.setColor(dist <= self.jumpRange and C.uiPrimary or C.uiDanger, 0.7)
        love.graphics.setLineWidth(1)
        love.graphics.line(hx, hy - (here.y - self.cy) * self.scale, sx, sy - (self.selected.y - self.cy) * self.scale)
    end

    -- info panel
    self:drawInfo(w - 372, 40, 332)

    -- header + footer
    ui.text(L("GALACTIC CHART"), 40, 30, C.uiPrimary, "large")
    ui.text(L("centre {x}, {y}, {z} ly     scale {scale} px/ly", {
        x = string.format("%.0f", self.cx), y = string.format("%.0f", self.cy),
        z = string.format("%.0f", self.cz), scale = string.format("%.1f", self.scale),
    }), 40, 62, C.uiDim, "small")
    ui.rule(40, h - 60, w - 80, C.uiLine, 0.4)
    ui.text(L("WASD pan   PGUP/PGDN vertical   +/- zoom   ENTER jump   TAB close"),
        40, h - 48, C.uiDim, "small")
    ui.textRight(L("FUEL") .. string.format(" %.1f / %.1f t", self.player.fuel, self.player.stats.fuel),
        w - 40, h - 48, C.amber, "small")
end

function Map:drawInfo(x, y, w)
    local s = self.selected
    if not s then return end
    local h = 330
    ui.panel(x, y, w, h, L("SYSTEM"))
    local px, py = x + 18, y + 18
    ui.text(s.name, px, py, C.uiPrimary, "large")
    py = py + 32

    local faction = factions.get(s.factionId)
    local dist = 0
    local here = self.world.stub
    dist = sqrt((s.x - here.x) ^ 2 + (s.y - here.y) ^ 2 + (s.z - here.z) ^ 2)
    local cost = self.world:fuelCost(dist)

    local rows = {
        { L("Distance"), string.format("%.2f ly", dist) },
        { L("Fuel needed"), string.format("%.1f t", cost) },
        { L("Allegiance"), L(faction.name) },
        { L("Government"), L(s.governmentName) },
        { L("Economy"), L(s.economyName) },
        { L("Population"), util.money(s.population) },
        { L("Tech level"), tostring(s.techLevel) },
        { L("Security"), string.format("%.0f%%", s.lawLevel * 100) },
        { L("Star"), L("class {c}", { c = s.starClass }) },
        { L("Frontier"), string.format("%.0f%%", (s.frontier or 0) * 100) },
    }
    for _, r in ipairs(rows) do
        ui.text(r[1], px, py, C.uiDim, "small")
        ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
        py = py + 18
    end

    py = py + 6
    if dist > self.jumpRange then
        ui.text(L("OUT OF JUMP RANGE"), px, py, C.uiDanger, "small")
    elseif cost > self.player.fuel then
        ui.text(L("NOT ENOUGH FUEL"), px, py, C.uiDanger, "small")
    elseif s.id == here.id then
        ui.text(L("CURRENT SYSTEM"), px, py, C.uiPrimary, "small")
    else
        ui.text(L("ENTER TO JUMP"), px, py, C.uiPrimary, "small")
    end
    py = py + 22

    -- war status
    local wars = self.world.diplomacy:activeWars()
    for _, war in ipairs(wars) do
        if war.a == s.factionId or war.b == s.factionId then
            local other = (war.a == s.factionId) and war.b or war.a
            ui.paragraph(L("At war with {faction:ins}", { faction = i18n.term(factions.get(other).name) }),
                px, py, w - 36, C.uiDanger, "small")
            py = py + 18
        end
    end
    if self.player.knownSystems[s.id] then
        ui.text(L("Visited"), px, py, C.uiPrimary, "small")
    else
        ui.text(L("Unvisited - long range survey"), px, py, C.uiDim, "small")
    end
end

return Map

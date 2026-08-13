-- Colony management, and the screen that founds a new one.
--
-- Founding is only offered when the player is actually standing on a landable
-- surface with the kit, the credits and the cargo aboard -- the requirements
-- are shown even when they are not met, so the goal is legible from the start.

local class = require("src.lib.class")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local colonyMod = require("src.sim.colony")
local commodities = require("src.sim.commodities")
local systemGen = require("src.procgen.system")
local hud = require("src.render.hud")
local i18n = require("src.i18n")

local Colonies = class("ColoniesState")

local C = palette.colors
local L = i18n.format

local LIST_TOP = 100
local LIST_LINE = 24
local FOOTER = 76

local function listRows()
    local h = love.graphics and love.graphics.getHeight() or 720
    return ui.rowsFor(h - LIST_TOP - FOOTER, LIST_LINE)
end
local floor = math.floor

function Colonies:init() self.drawUnderlying = false end

function Colonies:enter(flight, surface, localState)
    self.flight = flight
    self.surface = surface
    self.localState = localState
    self.world = self.game.world
    self.player = self.world.player
    self.specIndex = 1
    self.specs = {}
    for id in pairs(colonyMod.specialisations) do self.specs[#self.specs + 1] = id end
    table.sort(self.specs)
    self:rebuild()
end

function Colonies:canFoundHere()
    if not self.surface or not self.flight then return false, L("not landed") end
    if not self.flight.landedOn then return false, L("must be landed") end
    local ok, why = colonyMod.canFound(self.player, self.surface.body, true)
    if not ok then return false, why end
    -- and not on top of an existing settlement
    local pos = self.localState and self.localState.pos or nil
    if pos then
        local site = self.surface:settlementAt(pos.x, pos.z)
        if site then return false, L("too close to {place}", { place = site.place.name }) end
    end
    return true
end

function Colonies:rebuild()
    local items = {}
    local canFound, why = self:canFoundHere()
    items[#items + 1] = {
        label = canFound and L("Found a colony here")
            or L("Found a colony here ({reason})", { reason = L(tostring(why)) }),
        value = util.money(config.colony.foundCost) .. " " .. L("cr"),
        disabled = not canFound,
        color = canFound and C.uiPrimary or C.uiDim,
        action = function() self:found() end,
    }
    items[#items + 1] = {
        label = "  " .. L("Specialisation: {spec}",
            { spec = L(colonyMod.specialisations[self.specs[self.specIndex]].name) }),
        value = "LEFT/RIGHT",
        disabled = true, color = C.uiDim,
    }
    for _, c in ipairs(self.player.colonies) do
        colonyMod.update(c, self.world.day)
        items[#items + 1] = {
            label = c.name,
            value = L("{tier}  pop {pop}", { tier = L(colonyMod.tierName(c.tier)),
                pop = util.money(floor(c.population)) }),
            colony = c,
        }
    end
    if #self.player.colonies == 0 then
        items[#items + 1] = { label = L("No colonies yet."), disabled = true, color = C.uiDim }
    end
    self.menu = ui.menu(items, { visible = listRows() })
end

function Colonies:found()
    local pos = self.localState and self.localState.pos
    local x = pos and pos.x or self.flight.local_.pos.x
    local z = pos and pos.z or self.flight.local_.pos.z
    local lat, lon = self.surface:localToLatLon(x, z)
    local ok, colonyOrWhy = self.world:foundColony(self.surface.body, lat, lon, nil, self.specs[self.specIndex])
    if not ok then
        hud.message(L("Cannot found: {reason}", { reason = L(tostring(colonyOrWhy)) }), "alert")
        return
    end
    hud.message(L("Colony founded: {name}", { name = colonyOrWhy.name }), "good")
    -- rebuild the surface so the new settlement appears under the ship
    self.surface:setOrigin(self.surface.originLat, self.surface.originLon,
        self.surface.body.settlements or {})
    self:rebuild()
end

function Colonies:keypressed(key)
    if config.is("colony", key) or config.is("pause", key) then
        self.manager:pop()
        return
    end
    if key == "left" then
        self.specIndex = ((self.specIndex - 2) % #self.specs) + 1
        self:rebuild()
        return
    end
    if key == "right" then
        self.specIndex = (self.specIndex % #self.specs) + 1
        self:rebuild()
        return
    end
    if self.menu then self.menu:keypressed(key) end
end

function Colonies:update(dt) self.world:update(dt) end

function Colonies:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.clear(0.02, 0.025, 0.035, 1)

    ui.text(L("COLONIAL ADMINISTRATION"), 40, 30, C.uiPrimary, "large")
    ui.textRight(self.world:dateString(), w - 40, 34, C.uiDim, "small")
    ui.rule(40, 70, w - 80, C.uiLine, 0.4)

    if self.menu then
        self.menu:setVisible(listRows())
        self.menu:draw(70, LIST_TOP, w - 380 - 70 - ui.MENU_BLEED_RIGHT - 24, LIST_LINE, "small")
    end

    -- detail panel
    local x, y, pw = w - 380, LIST_TOP, 320
    local ph = h - LIST_TOP - FOOTER
    ui.panel(x, y, pw, ph, L("DETAIL"))
    local item = self.menu and self.menu:current()
    -- a colony's history and stockpile grow without bound; clipped, they stop
    -- painting over the footer
    ui.clip(x + 1, y + 1, pw - 2, ph - 2, function()
    local px, py = x + 18, y + 18

    if item and item.colony then
        local c = item.colony
        ui.text(c.name, px, py, C.uiPrimary, "normal")
        py = py + 26
        local rows = {
            { L("World"), c.bodyName or "?" },
            { L("Tier"), L(colonyMod.tierName(c.tier)) },
            { L("Population"), util.money(floor(c.population)) },
            { L("Specialisation"), L(colonyMod.specialisations[c.specialisation].name) },
            { L("Morale"), string.format("%.0f%%", c.morale * 100) },
            { L("Supplies left"), L("{n} {n:day}", { n = floor(colonyMod.suppliesLeft(c)) }) },
            { L("Treasury"), util.money(floor(c.credits)) .. " " .. L("cr") },
            { L("Founded"), util.date(c.founded) },
        }
        for _, r in ipairs(rows) do
            ui.text(r[1], px, py, C.uiDim, "small")
            ui.textRight(r[2], x + pw - 18, py, C.uiText, "small")
            py = py + 18
        end
        py = py + 10
        ui.text(L("Stockpile"), px, py, C.uiDim, "small")
        py = py + 18
        for id, amount in pairs(c.stockpile) do
            if amount > 0.5 then
                ui.text("  " .. L(commodities.get(id).name), px, py, C.uiText, "small")
                ui.textRight(L("{n} {n:t}", { n = floor(amount) }), x + pw - 18, py, C.uiText, "small")
                py = py + 16
            end
        end
        py = py + 10
        ui.text(L("History"), px, py, C.uiDim, "small")
        py = py + 18
        for i = math.max(1, #c.history - 6), #c.history do
            local ev = c.history[i]
            py = py + ui.paragraph(util.date(ev.day) .. "  " .. ev.text, px, py, pw - 36, C.uiText, "small") + 2
        end
    else
        ui.text(L("Founding a colony"), px, py, C.uiPrimary, "normal")
        py = py + 26
        py = py + ui.paragraph(L("Land on any solid world, then commit the kit. A new outpost grows " ..
            "on what you keep delivering: provisions, water, medicine and machinery. " ..
            "Neglect it and it starves."),
            px, py, pw - 36, C.uiText, "small") + 12
        ui.text(L("Requirements"), px, py, C.uiDim, "small")
        py = py + 20
        local reqs = {
            { L("Colony Foundation Kit"), self.player:has("colonykit") },
            { util.money(config.colony.foundCost) .. " " .. L("cr"),
              self.player.credits >= config.colony.foundCost },
        }
        for id, qty in pairs(config.colony.requiredCargo) do
            reqs[#reqs + 1] = { L("{qty} {qty:t} of {cargo:gen:lc}",
                                    { qty = qty, cargo = i18n.term(commodities.get(id).name) }),
                                self.player:cargoCount(id) >= qty }
        end
        for _, r in ipairs(reqs) do
            ui.text((r[2] and "[x] " or "[ ] ") .. r[1], px, py, r[2] and C.uiPrimary or C.uiDanger, "small")
            py = py + 18
        end
        py = py + 12
        local spec = colonyMod.specialisations[self.specs[self.specIndex]]
        ui.text(L("Specialisation: {spec}", { spec = L(spec.name) }), px, py, C.uiPrimary, "small")
        py = py + 20
        for id, rate in pairs(spec.produces) do
            ui.text("  " .. L("produces {cargo:acc:lc}",
                { cargo = i18n.term(commodities.get(id).name) }), px, py, C.uiDim, "small")
            py = py + 16
        end
    end

    end)

    ui.rule(40, h - 60, w - 80, C.uiLine, 0.4)
    ui.text(L("LEFT/RIGHT specialisation   ENTER select   {key} or ESC to close",
        { key = config.keyName("colony") }), 40, h - 48, C.uiDim, "small")
end

return Colonies

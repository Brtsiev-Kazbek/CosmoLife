-- Ship information.
--
-- The `ship` action has been in the bindings table since the input rework, is
-- listed in the rebinding screen and was advertised by the help panel -- but
-- no state ever handled it, so pressing it did nothing. This is that screen.
--
-- It answers the questions the HUD gauges cannot: what is actually fitted,
-- what each module contributes, and where the hull's numbers come from.

local class = require("src.lib.class")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local equipment = require("src.sim.equipment")
local commodities = require("src.sim.commodities")
local i18n = require("src.i18n")

local ShipInfo = class("ShipInfoState")

local C = palette.colors
local L = i18n.format
local floor = math.floor

local LIST_TOP = 130
local LIST_LINE = 22
local FOOTER = 72

local function listRows()
    local h = love.graphics and love.graphics.getHeight() or 720
    return ui.rowsFor(h - LIST_TOP - FOOTER, LIST_LINE)
end

function ShipInfo:init() self.drawUnderlying = false end

function ShipInfo:enter()
    self.world = self.game.world
    self.player = self.world.player
    self:rebuild()
end

function ShipInfo:rebuild()
    local items = {}
    local slots = { "weapon", "shield", "engine", "utility", "cargo" }
    local bySlot = {}
    for _, id in ipairs(self.player.installed) do
        local e = equipment.get(id)
        if e then
            bySlot[e.slot] = bySlot[e.slot] or {}
            table.insert(bySlot[e.slot], e)
        end
    end
    for _, slot in ipairs(slots) do
        local list = bySlot[slot]
        items[#items + 1] = { label = L(slot:upper()), disabled = true, color = C.uiDim }
        if list then
            for _, e in ipairs(list) do
                items[#items + 1] = {
                    label = "  " .. L(e.name),
                    value = L("tech {n}", { n = e.tech }),
                    module = e,
                }
            end
        else
            items[#items + 1] = { label = "  " .. L("nothing fitted"), disabled = true, color = C.uiDim }
        end
    end
    self.menu = ui.menu(items, { visible = listRows(), cursor = self.menu and self.menu.cursor or 2 })
end

function ShipInfo:keypressed(key)
    if config.is("ship", key) or config.is("pause", key) then
        self.manager:pop()
        return
    end
    if self.menu then self.menu:keypressed(key) end
end

function ShipInfo:wheelmoved(x, y)
    if self.menu then self.menu:move(-y) end
end

function ShipInfo:update(dt) self.world:update(dt) end

function ShipInfo:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.clear(0.02, 0.025, 0.035, 1)

    local def = self.player.shipDef
    local s = self.player.stats

    ui.textFit(def.name, 40, 30, w * 0.5, C.uiPrimary, "large")
    ui.textFit(L("{class} class", { class = L(def.roleName) }), 40, 64, w * 0.5, C.uiDim, "small")
    ui.textRight(util.money(self.player.credits) .. " " .. L("cr"), w - 40, 34, C.amber, "small")
    ui.rule(40, 96, w - 80, C.uiLine, 0.4)

    ui.text(L("FITTED"), 70, LIST_TOP - 22, C.uiDim, "small")
    if self.menu then
        self.menu:setVisible(listRows())
        self.menu:draw(70, LIST_TOP, w - 380 - 70 - ui.MENU_BLEED_RIGHT - 24, LIST_LINE, "small")
    end

    -- right panel: the numbers the modules add up to, and what is in the hold
    local px, py, pw = w - 380, LIST_TOP - 30, 320
    local ph = h - (LIST_TOP - 30) - FOOTER
    ui.panel(px, py, pw, ph, L("DETAIL"))
    ui.clip(px + 1, py + 1, pw - 2, ph - 2, function()
        self:drawDetail(px, py, pw, s)
    end)

    ui.rule(40, h - 60, w - 80, C.uiLine, 0.4)
    ui.text(L("W/S scroll   {key} or ESC to close", { key = config.keyName("ship") }),
        40, h - 48, C.uiDim, "small")
end

function ShipInfo:drawDetail(x, y, w, s)
    local px, py = x + 18, y + 20
    local item = self.menu and self.menu:current()

    -- a selected module explains itself; otherwise show the whole hull
    if item and item.module then
        local e = item.module
        ui.textFit(L(e.name), px, py, w - 36, C.uiPrimary, "normal")
        py = py + 26
        ui.text(L(e.slot:upper()), px, py, C.uiDim, "small")
        py = py + 20
        py = py + ui.paragraph(L(e.blurb or ""), px, py, w - 36, C.uiText, "small") + 12
        ui.text(L("Value"), px, py, C.uiDim, "small")
        ui.textRight(util.money(floor(e.price * 0.55)) .. " " .. L("cr"),
            x + w - 18, py, C.amber, "small")
        return
    end

    ui.text(L("Hull"), px, py, C.uiPrimary, "normal")
    py = py + 26
    local rows = {
        { L("Hull"), string.format("%d / %d", floor(self.player.hull), floor(s.maxHull)) },
        { L("Shield"), string.format("%d / %d", floor(self.player.shield), floor(s.maxShield)) },
        { L("Fuel"), string.format("%.1f / %.1f t", self.player.fuel, s.fuel) },
        { L("Cargo"), string.format("%d / %d t", self.player:cargoUsed(), self.player:cargoCapacity()) },
        { L("Jump range"), string.format("%.1f ly", s.jumpRange) },
        { L("Top speed"), string.format("%.0f m/s", s.topSpeed) },
        { L("Agility"), string.format("%.2f", s.agility) },
        { L("Hardpoints"), tostring(s.hardpoints or 0) },
        { L("Mass"), string.format("%d t", s.mass or 0) },
        { L("Missiles"), tostring(self.player.missiles) },
    }
    for _, r in ipairs(rows) do
        ui.text(r[1], px, py, C.uiDim, "small")
        ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
        py = py + 17
    end

    py = py + 12
    ui.text(L("Hold"), px, py, C.uiDim, "small")
    py = py + 18
    local any = false
    for id, qty in pairs(self.player.cargo) do
        ui.textFit("  " .. L(commodities.get(id).name), px, py, w - 100, C.uiText, "small")
        ui.textRight(L("{n} {n:t}", { n = qty }), x + w - 18, py, C.uiText, "small")
        py = py + 16
        any = true
    end
    if not any then ui.text("  " .. L("empty"), px, py, C.uiDim, "small") end
end

return ShipInfo

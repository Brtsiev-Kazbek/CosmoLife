-- Hulls for sale, and what trading yours in is worth.
--
-- Part of the docked screen (states/port.lua); the port state comes in as an
-- explicit first argument.

local util = require("src.lib.util")
local ui = require("src.ui.widgets")
local shipsGen = require("src.procgen.ships")
local palette = require("src.render.palette")
local i18n = require("src.i18n")
local layout = require("src.port.layout")

local shipyard = {}

local C = palette.colors
local L = i18n.format
local floor = math.floor

function shipyard.buildShipyardMenu(p)
    if not p.catalogue then
        p.catalogue = shipsGen.catalogue(p.place.seed, p.place.techLevel or 6, 6)
    end
    local items = {}
    local tradeIn = floor(p.player.shipDef.stats.price * 0.62)
    items[#items + 1] = {
        label = L("Your {class} ({name})",
            { class = L(p.player.shipDef.roleName), name = p.player.shipDef.name }),
        value = L("trade-in") .. " " .. util.money(tradeIn), disabled = true, color = C.uiDim,
    }
    for _, def in ipairs(p.catalogue) do
        items[#items + 1] = {
            label = string.format("%s  %s", L(def.roleName), def.name),
            value = util.money(def.stats.price) .. " " .. L("cr"),
            shipDef = def,
            valueColor = (p.player.credits + tradeIn) >= def.stats.price and C.amber or C.uiDim,
        }
    end
    p.menu = ui.menu(items, { visible = layout.rows() })
end

function shipyard.buyShip(p)
    local item = p.menu:current()
    if not item or not item.shipDef then return end
    local tradeIn = floor(p.player.shipDef.stats.price * 0.62)
    local cost = item.shipDef.stats.price - tradeIn
    if p.player.credits < cost then p:say(L("Not enough credits."), true) return end
    if p.player:cargoUsed() > item.shipDef.stats.cargo then
        p:say(L("New ship's hold is too small for your cargo."), true)
        return
    end
    p.player:spend(cost)
    p.player:setShip(item.shipDef, false)
    p:say(L("Registered to {name}.", { name = item.shipDef.name }))
    p.player:addLog(L("Bought a {class:acc:lc}.", { class = i18n.term(item.shipDef.roleName) }),
        p.world.day, "info")
    p.catalogue = nil
    shipyard.buildShipyardMenu(p)
end

return shipyard

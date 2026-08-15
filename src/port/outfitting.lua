-- Ship modules: what is fitted, what is for sale, what it costs.
--
-- Part of the docked screen (states/port.lua); the port state comes in as an
-- explicit first argument.

local util = require("src.lib.util")
local ui = require("src.ui.widgets")
local equipment = require("src.sim.equipment")
local palette = require("src.render.palette")
local i18n = require("src.i18n")
local layout = require("src.port.layout")

local outfitting = {}

local C = palette.colors
local L = i18n.format
local floor = math.floor

function outfitting.buildOutfitMenu(p)
    local tech = p.place.techLevel or 6
    local allowIllegal = (p.place.lawLevel or 0.5) < 0.4 or p.place.blackMarket
    local items = {}
    items[#items + 1] = { label = "-- " .. L("FITTED") .. " --", disabled = true, color = C.uiDim }
    for _, id in ipairs(p.player.installed) do
        local e = equipment.get(id)
        if e then
            items[#items + 1] = {
                label = "  " .. L(e.name),
                value = L("sell") .. " " .. util.money(floor(e.price * 0.55)),
                moduleId = id, sell = true, color = C.uiText,
            }
        end
    end
    items[#items + 1] = { label = "-- " .. L("FOR SALE") .. " --", disabled = true, color = C.uiDim }
    for _, e in ipairs(equipment.available(tech, allowIllegal)) do
        items[#items + 1] = {
            label = "  " .. L(e.name),
            value = util.money(e.price) .. " " .. L("cr"),
            moduleId = e.id, sell = false,
            color = e.illegal and C.magenta or nil,
            valueColor = p.player.credits >= e.price and C.amber or C.uiDim,
        }
    end
    p.menu = ui.menu(items, { visible = layout.rows() })
end

function outfitting.toggleModule(p)
    local item = p.menu:current()
    if not item or not item.moduleId then return end
    local e = equipment.get(item.moduleId)
    if item.sell then
        local refund = floor(e.price * 0.55)
        p.player:uninstall(item.moduleId)
        p.player:earn(refund)
        p:say(L("Sold {module:acc:lc} for {cash} cr.",
            { module = i18n.term(e.name), cash = util.money(refund) }))
    else
        if p.player.credits < e.price then p:say(L("Not enough credits."), true) return end
        local ok, why = p.player:install(item.moduleId)
        if ok then
            p.player:spend(e.price)
            -- the tutorial's outfitting chapter asks for exactly this
            local rec = p.player.record
            rec.fitted = (rec.fitted or 0) + 1
            p:say(L("{module} fitted.", { module = i18n.term(e.name) }))
        else
            p:say(L("Cannot fit: {reason}", { reason = L(tostring(why)) }), true)
        end
    end
    outfitting.buildOutfitMenu(p)
end

return outfitting

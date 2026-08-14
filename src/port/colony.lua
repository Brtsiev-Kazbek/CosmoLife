-- Your own colony: what it has, what it needs and what it is becoming.
--
-- Part of the docked screen (states/port.lua); the port state comes in as an
-- explicit first argument.

local util = require("src.lib.util")
local ui = require("src.ui.widgets")
local commodities = require("src.sim.commodities")
local colonyMod = require("src.sim.colony")
local i18n = require("src.i18n")
local layout = require("src.port.layout")

local colony = {}

local L = i18n.format
local floor = math.floor

function colony.buildColonyMenu(p)
    local c = p.place.colony
    colonyMod.update(c, p.world.day)
    local items = {}
    items[#items + 1] = {
        label = L("Collect exports and taxes"),
        value = util.money(floor(c.credits)) .. " " .. L("cr"),
        action = function()
            local taken, cash = colonyMod.collect(c, p.player)
            local n = 0
            for _, q in pairs(taken) do n = n + q end
            p:say(L("Collected {qty} {qty:t} and {cash} cr.", { qty = n, cash = util.money(cash) }))
            p:rebuild()
        end }
    for _, amount in ipairs({ 10000, 50000, 200000 }) do
        items[#items + 1] = {
            label = L("Invest {amount} cr", { amount = util.money(amount) }),
            value = p.player.credits >= amount and L("available") or L("too expensive"),
            disabled = p.player.credits < amount,
            action = function()
                local ok = colonyMod.invest(c, p.player, amount)
                p:say(ok and L("Investment committed.") or L("Not enough credits."), not ok)
                p:rebuild()
            end,
        }
    end
    -- deliver supplies straight from the hold
    for id in pairs(colonyMod.NEEDS) do
        local held = p.player:cargoCount(id)
        if held > 0 then
            items[#items + 1] = {
                label = L("Unload {qty} {qty:t} of {cargo:gen:lc}",
                    { qty = held, cargo = i18n.term(commodities.get(id).name) }),
                value = L("supply"),
                action = function()
                    p.player:removeCargo(id, held)
                    colonyMod.supply(c, id, held)
                    p:say(L("Supplies delivered."))
                    p:rebuild()
                end,
            }
        end
    end
    p.menu = ui.menu(items, { visible = layout.rows() })
end

return colony

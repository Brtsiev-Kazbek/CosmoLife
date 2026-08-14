-- The overview tab: who you are, where you are and what has changed.
--
-- This is where a player checks in, so it leads with rank and standing rather
-- than with prices.
--
-- Part of the docked screen (states/port.lua); the port state comes in as an
-- explicit first argument.

local util = require("src.lib.util")
local ui = require("src.ui.widgets")
local factions = require("src.sim.factions")
local commodities = require("src.sim.commodities")
local palette = require("src.render.palette")
local i18n = require("src.i18n")
local layout = require("src.port.layout")

local summary = {}

local C = palette.colors
local L = i18n.format
local floor = math.floor

function summary.buildSummaryMenu(p)
    local items = {}
    local stats = p.player.stats
    local fuelMissing = stats.fuel - p.player.fuel
    local fuelPrice = floor(fuelMissing * 34)
    if fuelMissing > 0.05 then
        items[#items + 1] = {
            label = L("Refuel ({amount} t)", { amount = string.format("%.1f", fuelMissing) }),
            value = util.money(fuelPrice) .. " " .. L("cr"),
            action = function()
                if p.player:spend(fuelPrice) then
                    p.player.fuel = stats.fuel
                    p:say(L("Tanks full."))
                else
                    p:say(L("Not enough credits."), true)
                end
                p:rebuild()
            end,
        }
    else
        items[#items + 1] = { label = L("Refuel"), value = L("tanks full"), disabled = true }
    end

    local hullMissing = stats.maxHull - p.player.hull
    local repairPrice = floor(hullMissing * 22)
    if hullMissing > 0.5 and (p.place.services or {}).repair ~= false then
        items[#items + 1] = {
            label = L("Repair hull ({amount})", { amount = floor(hullMissing) }),
            value = util.money(repairPrice) .. " " .. L("cr"),
            action = function()
                if p.player:spend(repairPrice) then
                    p.player.hull = stats.maxHull
                    p.player.shield = stats.maxShield
                    p:say(L("Hull restored."))
                else
                    p:say(L("Not enough credits."), true)
                end
                p:rebuild()
            end,
        }
    else
        items[#items + 1] = { label = L("Repair hull"), value = L("no damage"), disabled = true }
    end

    if p.player.missiles < 6 then
        items[#items + 1] = {
            label = L("Buy missile"), value = util.money(1200) .. " " .. L("cr"),
            action = function()
                if p.player:spend(1200) then
                    p.player.missiles = p.player.missiles + 1
                    p:say(L("Missile loaded."))
                else p:say(L("Not enough credits."), true) end
                p:rebuild()
            end,
        }
    end

    local bounty = p.player:bounty(p.place.factionId)
    if bounty > 0 then
        items[#items + 1] = {
            label = L("Pay off bounty with {faction}",
                { faction = factions.get(p.place.factionId).short }),
            value = util.money(bounty) .. " " .. L("cr"), color = C.uiWarn,
            action = function()
                if p.player:spend(bounty) then
                    p.player:clearBounty(p.place.factionId)
                    p:say(L("Record cleared."))
                else p:say(L("Not enough credits."), true) end
                p:rebuild()
            end,
        }
    end

    -- rank first: the summary tab is where a player checks in, so it is where
    -- the next milestone belongs
    local progression = require("src.sim.progression")
    local rank = progression.rank(p.player)
    local nextRank = progression.next(p.player)
    items[#items + 1] = {
        label = L("Rank: {rank}", { rank = L(rank.name) }),
        value = nextRank and string.format("%d%%", math.floor(progression.progress(p.player) * 100)) or nil,
        disabled = true, color = C.uiPrimary,
    }
    if nextRank then
        local need, amount = progression.requirement(p.player)
        local line = need == "credits"
            and L("Next: {rank}, {cash} cr more", { rank = L(nextRank.name), cash = util.money(amount) })
            or L("Next: {rank}", { rank = L(nextRank.name) })
        items[#items + 1] = { label = "   " .. line, disabled = true, color = C.uiDim }
    end

    -- rank first: the summary tab is where a player checks in, so it is where
    -- the next milestone belongs
    local progression = require("src.sim.progression")
    local rank = progression.rank(p.player)
    local nextRank = progression.next(p.player)
    items[#items + 1] = {
        label = L("Rank: {rank}", { rank = L(rank.name) }),
        value = nextRank and string.format("%d%%", math.floor(progression.progress(p.player) * 100)) or nil,
        disabled = true, color = C.uiPrimary,
    }
    if nextRank then
        local need, amount = progression.requirement(p.player)
        local line = need == "credits"
            and L("Next: {rank}, {cash} cr more", { rank = L(nextRank.name), cash = util.money(amount) })
            or L("Next: {rank}", { rank = L(nextRank.name) })
        items[#items + 1] = { label = "   " .. line, disabled = true, color = C.uiDim }
    end

    items[#items + 1] = { label = L("Trade computer: best local exports"), disabled = true, color = C.uiDim }
    for _, e in ipairs(p.market:bestExports(4)) do
        local c = commodities.get(e.id)
        items[#items + 1] = {
            label = "   " .. L(c.name), value = util.money(e.price) .. " " .. L("cr"),
            disabled = true, color = C.uiDim,
        }
    end

    items[#items + 1] = {
        label = p.docked and L("Launch") or L("Step away from the terminal"),
        value = "ESC", color = C.uiPrimary,
        action = function() p:launch() end,
    }

    p.menu = ui.menu(items, { visible = layout.rows(), onSelect = function() end })
end

return summary

-- Buying and selling cargo.
--
-- The black market is the same screen with a different stock list and a
-- different attitude to legality, so it shares every line of this.
--
-- Part of the docked screen (states/port.lua); the port state comes in as an
-- explicit first argument.

local util = require("src.lib.util")
local ui = require("src.ui.widgets")
local commodities = require("src.sim.commodities")
local palette = require("src.render.palette")
local i18n = require("src.i18n")
local layout = require("src.port.layout")
local trade = require("src.sim.trade")

local market = {}

local C = palette.colors
local L = i18n.format
local floor, min, max = math.floor, math.min, math.max

--- The colour of the comparison column: only what the player can act on.
--
-- Colouring every dear row amber lit up half the shelf at the first industrial
-- station it was tried on, which is the same mistake as flagging every row --
-- a port charging over the odds for goods you are not carrying is simply not
-- your business. Amber is kept for the one case where "dear" is an instruction:
-- you are holding the stuff and this is where it sells.
local function columnColor(verdict, held)
    if verdict == "cheap" then return C.uiPrimary end
    if verdict == "dear" and held > 0 then return C.uiWarn end
    return nil
end

--- Assessments for everything on this shelf, keyed by commodity id.
--
-- Built once per rebuild and hung off the port state so the side panel does
-- not recompute what the list already worked out.
function market.assess(p)
    local out = {}
    local opts = {
        credits = p.player.credits,
        free = p.player:cargoFree(),
        colonies = p.player.colonies,
    }
    for _, id in ipairs(p.market:tradedIds()) do
        local row = trade.assess(p.market, id, opts)
        if row then out[id] = row end
    end
    p.assessed = out
    return out
end

function market.buildMarketMenu(p, black)
    local items = {}
    local law = p.place.lawLevel or 0.5
    local rows = market.assess(p)
    -- ranked over the rows this tab actually shows, so the legal market never
    -- points at something only the black market sells
    local shown = {}
    for _, id in ipairs(p.market:tradedIds()) do
        local c = commodities.get(id)
        local legality = commodities.legalityIn(c, law)
        local illicit = (legality ~= "legal")
        if illicit == (black and true or false) then
            local r = rows[id]
            shown[#shown + 1] = r
            local held = p.player:cargoCount(id)
            -- the comparison column goes first: its width jitters with the
            -- number, and everything to its right is anchored to the same edge
            local pct = r.ratio and string.format("%+d%%", floor((r.ratio - 1) * 100 + 0.5)) or "   "
            items[#items + 1] = {
                label = r.wanted > 0 and L("{name}  (colony)", { name = L(c.name) }) or L(c.name),
                value = string.format("%s   %s / %s   %d   %d",
                    pct, util.money(r.buy), util.money(r.sell), r.stock, held),
                commodity = id,
                color = illicit and C.magenta or (r.wanted > 0 and C.uiWarn or nil),
                valueColor = columnColor(r.verdict, held),
            }
        end
    end
    p.bestBuy = trade.best(shown)
    if #items == 0 then
        items[1] = {
            label = black and L("No black market trade today.") or L("Nothing traded here."),
            disabled = true,
        }
    end
    p.menu = ui.menu(items, { visible = layout.rows() })
end

function market.trade(p, sell)
    local item = p.menu:current()
    if not item or not item.commodity then return end
    local id = item.commodity
    local qty = p.quantity
    if qty == "max" then
        qty = sell and p.player:cargoCount(id) or 1e9
    end
    local cargo = i18n.term(commodities.get(id).name)
    if sell then
        local have = p.player:cargoCount(id)
        local n, total = p.market:quote(id, min(qty, have), true)
        n = min(n, have)
        if n <= 0 then p:say(L("Nothing to sell."), true) return end
        n, total = p.market:sell(id, n)
        p.player:removeCargo(id, n)
        p.player:earn(total)
        p.player.record.trades = p.player.record.trades + 1
        p.player.record.profit = p.player.record.profit + total
        p:say(L("Sold {qty} {qty:t} of {cargo:gen:lc} for {cash} cr.",
            { qty = n, cargo = cargo, cash = util.money(total) }))
    else
        local space = p.player:cargoFree()
        local price = p.market:buyPrice(id) or 1
        local affordable = floor(p.player.credits / max(price, 1))
        local n = min(qty, space, affordable, p.market:available(id))
        if n <= 0 then
            p:say(space <= 0 and L("Hold is full.") or L("Cannot afford any."), true)
            return
        end
        local bought, cost = p.market:buy(id, n)
        p.player:spend(cost)
        p.player:addCargo(id, bought)
        p.player.record.trades = p.player.record.trades + 1
        p:say(L("Bought {qty} {qty:t} of {cargo:gen:lc} for {cash} cr.",
            { qty = bought, cargo = cargo, cash = util.money(cost) }))
    end
    market.buildMarketMenu(p, p:currentTab() == "blackMarket")
end

return market

-- Judging a market at a glance.
--
-- The port screen already had every number a trading decision needs and made
-- none of the comparisons: it printed a buy price, a sell price, a stock and a
-- hold count, and left the player to remember from memory what grain costs
-- everywhere else. `c.base` is exactly that memory -- the galactic reference
-- price every local price is derived from (`economy.lua:149`) -- and the
-- `price / base` idiom already existed for the trade computer's export hints.
--
-- This module turns those numbers into the three questions a docked player
-- actually asks: what is cheap here, how much of it could I leave with, and
-- does anything I am responsible for want it. Plain arithmetic on plain
-- numbers, so the answers can be checked head-lessly instead of being read off
-- a screenshot.

local commodities = require("src.sim.commodities")

local trade = {}

local floor, min, max = math.floor, math.min, math.max

-- The bands come from the distribution, not from taste. Over 1243 rows on 7
-- economies and 12 seeds the median row sits at 1.29 of the galactic reference
-- -- most of what a world sells, it imported -- so "a bit over base" is the
-- normal case and flagging it would flag almost everything. At or under the
-- reference is the tenth percentile and genuinely worth loading; 1.45 is the
-- sixtieth and the point where the shelf is either gouging you or, if you are
-- holding the stuff, paying well.
trade.CHEAP = 1.00
trade.DEAR = 1.45

--- The local mid price as a share of what the commodity is worth everywhere.
function trade.ratio(price, base)
    if not price or not base or base <= 0 then return nil end
    return price / base
end

--- "cheap" / "fair" / "dear", from a ratio.
function trade.verdict(ratio)
    if not ratio then return "fair" end
    if ratio <= trade.CHEAP then return "cheap" end
    if ratio >= trade.DEAR then return "dear" end
    return "fair"
end

--- How many units the player could actually walk out with: the hold, the purse
--- and the shelf, whichever runs out first.
function trade.take(free, volume, credits, price, stock)
    local byHold = floor((free or 0) / max(volume or 1, 0.01))
    local byPurse = floor((credits or 0) / max(price or 1, 1))
    return max(0, min(byHold, byPurse, floor(stock or 0)))
end

--- The size of the bet: what a load bought here would be worth at the galactic
--- average. Not a promise -- nobody knows what the next port pays -- but it
--- ranks "worth the detour" against "worth a shrug", which is the actual
--- decision in front of the player.
function trade.upside(price, base, n)
    return ((base or 0) - (price or 0)) * (n or 0)
end

--- Tonnes the player's own colonies are short of `days` of cover.
--
-- A colony starves quietly while the player is elsewhere, and the one screen
-- where they are stood in front of a shelf full of provisions is the market.
function trade.wanted(colonies, id, days)
    local colonyMod = require("src.sim.colony")
    local short = 0
    for _, c in ipairs(colonies or {}) do
        short = short + (colonyMod.shortfall(c, days)[id] or 0)
    end
    return short
end

--- Everything the list needs to know about one commodity, in one table.
--
-- `opts`: credits, free (tonnes of hold), colonies, days (of colony cover).
function trade.assess(market, id, opts)
    opts = opts or {}
    local c = commodities.get(id)
    if not c then return nil end
    local mid = market:price(id)
    local buy = market:buyPrice(id)
    local ratio = trade.ratio(mid, c.base)
    local stock = market:available(id)
    local take = trade.take(opts.free, c.volume or 1, opts.credits, buy, stock)
    return {
        id = id,
        buy = buy,
        sell = market:sellPrice(id),
        stock = stock,
        base = c.base,
        ratio = ratio,
        verdict = trade.verdict(ratio),
        take = take,
        upside = trade.upside(buy, c.base, take),
        wanted = trade.wanted(opts.colonies, id, opts.days),
    }
end

--- The single row worth the player's attention, or nil when nothing here beats
--- the galactic average by enough to be worth the hold space.
function trade.best(rows)
    local best
    for _, r in ipairs(rows) do
        if r.take > 0 and r.upside > 0 and (not best or r.upside > best.upside) then
            best = r
        end
    end
    return best
end

return trade

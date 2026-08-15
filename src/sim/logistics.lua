-- Freight that actually moves.
--
-- Production chains gave worlds a reason to need each other; this is what
-- carries the goods between them. Before it, an NPC trader flew from one
-- random port to another with an empty hold and no effect on anything -- the
-- traffic was scenery, and every price in the system was the product of a
-- drift term rather than of anybody's cargo.
--
-- A run is the whole of it: buy this much of that at A, sell it at B. The
-- trader flies it; arriving settles it, and the settlement moves stock at both
-- ends -- out of the seller, into the buyer -- which is what makes prices move
-- because ships moved. A player who watches a lane long enough can predict it,
-- and a player who cuts one can profit from it.
--
-- Pure Lua on plain tables. Markets come in as arguments, so a hundred runs
-- can be settled in a test without a system, a renderer or a frame.

local production = require("src.sim.production")

local logistics = {}

local min, max, floor = math.min, math.max, math.floor

-- A hauler's hold, in tonnes. NPC hulls carry more than the player's starter
-- and less than a bulk freighter; one run has to be big enough to move a
-- market's price and small enough that a single trader is not the economy.
logistics.HOLD = 60

-- The smallest margin per tonne worth flying for. Below this a trader has
-- better things to do, and without a floor they haul rounding errors around
-- the system forever.
logistics.MIN_MARGIN = 6

--- What a world most wants delivered, and how badly.
--
-- Its production inputs first -- those are the ones that stop a factory -- and
-- then anything it is simply short of. Returns a list sorted by need, so the
-- caller can take the first that it can source.
function logistics.wants(market)
    local out = {}
    local need = production.demand(market.economyId, market.equilibrium)
    for id, perDay in pairs(need) do
        local have = market.stock[id] or 0
        local cover = perDay > 0 and have / (perDay * production.BUFFER_DAYS) or 1
        if cover < 1.4 then
            out[#out + 1] = { id = id, cover = cover, input = true }
        end
    end
    for id, eq in pairs(market.equilibrium) do
        local have = market.stock[id] or 0
        if have < eq * 0.55 and not production.isOutput(market.economyId, id) then
            out[#out + 1] = { id = id, cover = have / max(eq, 1), input = false }
        end
    end
    -- sorted, because `pairs` over a hash table is not ordered the same way
    -- twice and a galaxy whose freight depended on that would run differently
    -- on every launch
    table.sort(out, function(a, b)
        if a.cover ~= b.cover then return a.cover < b.cover end
        return a.id < b.id
    end)
    return out
end

--- The best run from `from` to `to`, or nil when there is nothing worth
--- carrying.
--
-- `to` decides what is wanted; `from` decides what can be had. The margin is
-- the buy price there against the sell price here, which is the same
-- arithmetic the player does on the market screen.
function logistics.plan(from, to, hold)
    hold = hold or logistics.HOLD
    local best
    for _, want in ipairs(logistics.wants(to)) do
        local id = want.id
        local buy = from:buyPrice(id)
        local sell = to:sellPrice(id)
        local stock = from:available(id)
        if buy and sell and stock > 4 then
            local margin = sell - buy
            local qty = min(hold, floor(stock * 0.35), to:absorbable(id))
            if margin >= logistics.MIN_MARGIN and qty > 0 then
                local value = margin * qty
                -- an input that has actually stopped a factory outranks a
                -- fatter margin on something the world merely likes having
                local urgency = want.input and (1.8 - want.cover) or 1
                local score = value * urgency
                if not best or score > best.score then
                    best = { id = id, qty = qty, margin = margin, score = score,
                             cost = buy * qty, revenue = sell * qty }
                end
            end
        end
    end
    return best
end

--- Buys the cargo at the origin. Mutates the market.
function logistics.load(from, run)
    if not run then return 0 end
    local got, cost = from:buy(run.id, run.qty)
    run.qty, run.cost = got, cost
    return got
end

--- Sells it at the destination. Mutates the market; returns the profit.
function logistics.unload(to, run)
    if not run or run.qty <= 0 then return 0 end
    local sold, revenue = to:sell(run.id, run.qty)
    run.sold, run.revenue = sold, revenue
    return revenue - (run.cost or 0)
end

return logistics

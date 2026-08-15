-- What a world makes, and what it needs to make it.
--
-- The economy has always had the shape of a production chain: an extraction
-- world `produces` ore, a refinery `consumes` ore and produces alloys, an
-- industrial world consumes alloys and produces machinery
-- (`commodities.economies`). What it never had was the *dependency*. Those
-- tables were multipliers on a restocking drift, so a refinery with no ore
-- whatsoever went on producing alloys at exactly its usual rate, and a
-- blockade, a war on the route or a player buying out every tonne of ore in
-- the system changed nothing anywhere else.
--
-- This is that dependency, and it is the difference between an economy and a
-- price table: a world only makes what its inputs allow. When the inputs run
-- short the output stops, the stock drains into ordinary demand, and the price
-- climbs -- which a player who noticed the shortage two jumps upstream can be
-- waiting for.
--
-- Pure arithmetic on plain tables. No `love`, no market object: the caller
-- passes stock and gets back factors, so a chain can be run for a hundred days
-- in a test in a millisecond.

local commodities = require("src.sim.commodities")

local production = {}

local min, max = math.min, math.max

-- Days of inputs a world keeps on hand before its output is affected at all.
--
-- Without this every market would flicker between fed and starved as its
-- inputs wobbled around the restock point, and prices would jitter with it.
-- Real plants hold a buffer, and the buffer is what makes a shortage take a
-- few days to bite -- which is exactly the window a trader is paid to fill.
production.BUFFER_DAYS = 6

-- Fraction of a commodity's equilibrium stock that a day of industry eats,
-- per unit of consumption weight.
--
-- Calibrated against the restocking flow rather than chosen: ordinary imports
-- close 9% of the gap to equilibrium per day, so a world that ate faster than
-- that would starve *itself* with nothing to blame. Measured settled supply
-- across five economies over eighty days: 0.12 leaves every world at 0.19 --
-- a galaxy in permanent famine -- 0.02 leaves them at 0.99, where nothing can
-- ever pinch. At 0.03 worlds run at about 0.8 and a broken supply line is
-- something you can see.
production.RATION = 0.03

--- What an economy needs on hand, per day, to run at full output.
--
-- Derived from the same table the output comes from, rather than a second one
-- that could disagree with it: consumption weight times the scale of the
-- world, which is what `equilibrium` already expresses.
function production.demand(economyId, equilibrium)
    local eco = commodities.economy(economyId)
    local out = {}
    for id, weight in pairs(eco.consumes) do
        -- a world only demands what it is set up to trade at all
        local eq = equilibrium[id]
        if eq and eq > 0 then out[id] = eq * weight * production.RATION end
    end
    return out
end

--- How well supplied a world is, from 0 (nothing) to 1 (running at capacity).
--
-- The worst input decides it, not the average: a factory with every input but
-- one is a factory that has stopped. That is the whole reason a single
-- interrupted route is worth a player's attention.
-- `need` is the table `demand` returns. It depends only on the economy and the
-- equilibrium, both fixed for the life of a market, so it is built once and
-- handed in: rebuilding it per simulation step cost 0.68 ms per market update
-- against 0.18 before production existed, and a market updates every frame it
-- is in.
function production.supplyOf(need, stock, days)
    local worst, limiting = 1, nil
    for id, perDay in pairs(need) do
        local have = stock[id] or 0
        local buffer = perDay * (days or production.BUFFER_DAYS)
        local cover = buffer > 0 and min(have / buffer, 1) or 1
        if cover < worst then worst, limiting = cover, id end
    end
    return worst, limiting
end

--- The same, for callers that have not cached the need table.
function production.supply(economyId, equilibrium, stock, days)
    return production.supplyOf(production.demand(economyId, equilibrium), stock, days)
end

--- Consumes a day's inputs at the given supply level. Mutates `stock`.
function production.consume(need, stock, supply, days)
    for id, perDay in pairs(need) do
        local used = perDay * supply * (days or 1)
        stock[id] = max(0, (stock[id] or 0) - used)
    end
end

--- Is this commodity something the world makes rather than merely trades?
function production.isOutput(economyId, id)
    return (commodities.economy(economyId).produces[id] or 0) > 0
end

-- What a starved world still holds of its own product, as a fraction of its
-- usual stock. Not zero: some output is scavenged, some arrives from
-- elsewhere, and a chain that could reach zero could never restart itself.
production.FLOOR = 0.25

--- Where a commodity's stock settles, given how well the world is supplied.
--
-- The level, not the rate. Gating the *rate* was the first attempt and it
-- barely moved anything: a slow approach to the same equilibrium is still the
-- same equilibrium, and sixty days of total starvation changed the price of
-- alloys by six percent. What actually happens to a plant that cannot make
-- alloys is that it stops holding alloys -- it keeps selling them and nothing
-- replaces them -- so the level is what supply decides.
--
-- Only the world's *own products* are affected: a farm still buys machinery
-- when its harvest fails, and a world that stopped holding everything the
-- moment one input ran short would be dead rather than hungry.
function production.target(economyId, id, equilibrium, supply)
    if not production.isOutput(economyId, id) then return equilibrium end
    return equilibrium * (production.FLOOR + (1 - production.FLOOR) * supply)
end

return production

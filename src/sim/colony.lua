-- Player colonies.
--
-- Founding a settlement is the long game: you plant it, keep it fed, and it
-- grows through five tiers, each unlocking more services and more output.
-- A colony is simulated analytically -- given the day it was last touched and
-- the day now, we integrate growth in one step -- so a hundred colonies cost
-- nothing while the player is elsewhere.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local config = require("src.config")
local names = require("src.procgen.names")
local commodities = require("src.sim.commodities")
local economy = require("src.sim.economy")

local colony = {}

local CFG = config.colony

--- Everything a colony needs delivered to keep growing, per 100 population
--- per day.  Running out of any of these stalls growth and then shrinks it.
local NEEDS = { provisions = 0.9, water = 0.6, medicine = 0.12, machinery = 0.15 }

--- What a colony produces once it is big enough, by chosen specialisation.
local SPECIALISATIONS = {
    mining      = { name = "Mining",       economyId = "extraction",
                    produces = { ore = 1.4, minerals = 0.9, raremetals = 0.15 } },
    farming     = { name = "Agriculture",  economyId = "agricultural",
                    produces = { grain = 1.6, provisions = 0.9, livestock = 0.4 } },
    industry    = { name = "Industry",     economyId = "industrial",
                    produces = { alloys = 0.8, machinery = 0.5, computers = 0.1 } },
    research    = { name = "Research",     economyId = "hightech",
                    produces = { computers = 0.35, supercond = 0.12, medicine = 0.3 } },
    refining    = { name = "Refining",     economyId = "refinery",
                    produces = { alloys = 1.1, deuterium = 0.6, hydrogen = 0.7 } },
}

colony.specialisations = SPECIALISATIONS

-- ---------------------------------------------------------------------------

--- Requirements check before the founding button lights up.
function colony.canFound(player, body, altitudeOk)
    if not body or not body.landable then return false, "cannot settle this body" end
    if not player:has("colonykit") then return false, "no Colony Foundation Kit fitted" end
    if player.credits < CFG.foundCost then
        return false, string.format("need %s cr", util.money(CFG.foundCost))
    end
    for id, qty in pairs(CFG.requiredCargo) do
        if player:cargoCount(id) < qty then
            return false, string.format("need %d t of %s", qty, commodities.get(id).name)
        end
    end
    if altitudeOk == false then return false, "must be landed" end
    return true
end

--- Creates a colony record.  `opts`: seed, body, latitude, longitude, name,
--- factionId, day, specialisation.
function colony.found(opts)
    local rng = Rng.new(opts.seed or 1, "colony")
    local spec = opts.specialisation
    if not spec then
        -- pick a specialisation that suits the world
        local t = opts.body and opts.body.type or "rock"
        if t == "terran" or t == "ocean" then spec = "farming"
        elseif t == "volcanic" or t == "rock" then spec = "mining"
        elseif t == "ice" then spec = "refining"
        else spec = rng:pick({ "mining", "industry", "refining" }) end
    end

    local c = {
        id = string.format("colony-%d", opts.seed or rng:int(1, 1e8)),
        seed = opts.seed or rng:int(1, 1e8),
        name = opts.name or names.settlement(opts.seed or 1),
        bodyName = opts.body and opts.body.name,
        bodySeed = opts.body and opts.body.seed,
        systemId = opts.systemId,
        latitude = opts.latitude or 0,
        longitude = opts.longitude or 0,
        factionId = opts.factionId or "independent",
        specialisation = spec,
        economyId = SPECIALISATIONS[spec].economyId,
        population = 120,
        tier = 1,
        founded = opts.day or 0,
        lastUpdate = opts.day or 0,
        -- the foundation kit lands with roughly two months of everything
        stockpile = { provisions = 80, water = 80, medicine = 15, machinery = 30, colonists = 24 },
        exports = {},
        credits = 0,
        morale = 0.7,
        defence = 0.1,
        history = { { day = opts.day or 0, text = "Foundation charter filed." } },
        player = true,
        pads = 1,
        techLevel = 4,
        lawLevel = 0.5,
        wealth = 0.7,
        services = { market = true, refuel = true, missions = false, repair = false, outfitting = false, shipyard = false },
    }
    return c
end

--- Simulates a colony forward to `day`.
function colony.update(c, day)
    local days = day - (c.lastUpdate or day)
    if days <= 0 then return c end
    c.lastUpdate = day

    local rng = Rng.new(c.seed, "colony-tick", math.floor(day))
    local steps = math.min(math.ceil(days), 60)
    local dt = days / steps

    for _ = 1, steps do
        local pop = c.population
        -- consumption.  Supply satisfaction is the mean coverage across needs,
        -- pulled down by the worst one: running out of medicine hurts, running
        -- out of everything is fatal.
        local sum, count, worst = 0, 0, 1
        for id, rate in pairs(NEEDS) do
            local need = rate * (pop / 100) * dt
            local have = c.stockpile[id] or 0
            local coverage = need > 0 and math.min(have / need, 1) or 1
            c.stockpile[id] = math.max(0, have - need)
            sum = sum + coverage
            count = count + 1
            worst = math.min(worst, coverage)
        end
        local satisfied = (count > 0) and (sum / count) * (0.65 + 0.35 * worst) or 1

        -- morale follows supply, slowly
        c.morale = util.clamp(c.morale + (satisfied - 0.65) * 0.12 * dt, 0, 1)

        -- growth (or decline)
        local growth = CFG.growthPerDay * (satisfied * 1.4 - 0.45) * (0.6 + c.morale * 0.8)
        c.population = math.max(20, pop * (1 + growth * dt))

        -- colonists in the stockpile move in
        local incoming = c.stockpile.colonists or 0
        if incoming > 0 then
            local moved = math.min(incoming, 30 * dt)
            c.stockpile.colonists = incoming - moved
            c.population = c.population + moved * 8
        end

        -- production once past subsistence
        if c.tier >= 2 and satisfied > 0.5 then
            local spec = SPECIALISATIONS[c.specialisation]
            for id, rate in pairs(spec.produces) do
                local made = rate * (c.population / 1000) * dt * (0.5 + c.morale * 0.8)
                c.exports[id] = (c.exports[id] or 0) + made
            end
        end

        -- taxes accumulate as colony credits the player can withdraw
        c.credits = c.credits + c.population * CFG.taxPerPopPerDay * 0.001 * dt * c.morale
    end

    -- tier from population
    local tier = 1
    for t = #CFG.tierPopulation, 1, -1 do
        if c.population >= CFG.tierPopulation[t] then tier = t break end
    end
    if tier > c.tier then
        c.tier = tier
        c.pads = math.min(6, 1 + tier)
        c.techLevel = math.min(12, 3 + tier * 1.4)
        c.services.missions = tier >= 2
        c.services.repair = tier >= 2
        c.services.outfitting = tier >= 3
        c.services.shipyard = tier >= 4
        c.history[#c.history + 1] = {
            day = day,
            text = string.format("Reached tier %d - population %s.", tier, util.money(math.floor(c.population))),
        }
        c.tierUpPending = true
    elseif tier < c.tier and c.population < CFG.tierPopulation[c.tier] * 0.6 then
        c.tier = tier
        c.history[#c.history + 1] = { day = day, text = "Population loss forced a downgrade." }
    end

    -- unrest when badly supplied
    if c.morale < 0.2 and not c.unrest then
        c.unrest = true
        c.history[#c.history + 1] = { day = day, text = "Unrest reported: supplies have run out." }
    elseif c.morale > 0.45 then
        c.unrest = false
    end

    return c
end

--- Delivers cargo into a colony's stockpile.
function colony.supply(c, commodityId, qty)
    c.stockpile[commodityId] = (c.stockpile[commodityId] or 0) + qty
    c.morale = util.clamp(c.morale + qty * 0.002, 0, 1)
    return qty
end

--- Collects accumulated exports and tax credits; returns cargo actually taken.
function colony.collect(c, player)
    local taken = {}
    for id, amount in pairs(c.exports) do
        local whole = math.floor(amount)
        if whole > 0 then
            local n = player:addCargo(id, whole)
            if n > 0 then
                c.exports[id] = amount - n
                taken[id] = n
            end
        end
    end
    local cash = math.floor(c.credits)
    if cash > 0 then
        player:earn(cash)
        c.credits = c.credits - cash
    end
    return taken, cash
end

--- Invests credits to accelerate growth: buys infrastructure directly.
function colony.invest(c, player, amount)
    if not player:spend(amount) then return false, "not enough credits" end
    c.morale = util.clamp(c.morale + amount / 120000, 0, 1)
    c.population = c.population * (1 + amount / 900000)
    c.defence = util.clamp(c.defence + amount / 400000, 0, 1)
    c.history[#c.history + 1] = {
        day = c.lastUpdate,
        text = string.format("Invested %s cr in infrastructure.", util.money(amount)),
    }
    return true
end

--- A market for trading at the colony, built from its current state.
function colony.market(c, day)
    local m = economy.Market.new({
        seed = c.seed,
        economyId = c.economyId,
        population = math.floor(c.population),
        techLevel = c.techLevel,
        lawLevel = c.lawLevel,
        factionId = c.factionId,
        wealth = c.wealth,
        kind = "settlement",
        day = day,
    })
    -- the colony's own exports show up as stock
    for id, amount in pairs(c.exports) do
        if m.equilibrium[id] then
            m.stock[id] = (m.stock[id] or 0) + amount
        end
    end
    return m
end

--- Days of supply left at the current population, for the UI.
function colony.suppliesLeft(c)
    local worst = math.huge
    for id, rate in pairs(NEEDS) do
        local need = rate * (c.population / 100)
        if need > 0 then
            worst = math.min(worst, (c.stockpile[id] or 0) / need)
        end
    end
    return worst == math.huge and 0 or worst
end

--- How much of each need the colony is short of `days` of cover.
--
-- `suppliesLeft` answers "how long until trouble" in one number; this answers
-- "what do I put in the hold", which is the question the market screen asks.
function colony.shortfall(c, days)
    local out = {}
    for id, rate in pairs(NEEDS) do
        local want = rate * (c.population / 100) * (days or 30)
        local short = want - (c.stockpile[id] or 0)
        if short > 0.5 then out[id] = short end
    end
    return out
end

function colony.tierName(tier)
    return ({ "Outpost", "Settlement", "Township", "City", "Metropolis" })[tier] or "Outpost"
end

--- Converts a colony record into the "port" shape the docking UI expects.
function colony.asPort(c)
    return {
        kind = "settlement",
        name = c.name,
        seed = c.seed,
        population = math.floor(c.population),
        economyId = c.economyId,
        techLevel = c.techLevel,
        lawLevel = c.lawLevel,
        factionId = c.factionId,
        wealth = c.wealth,
        latitude = c.latitude,
        longitude = c.longitude,
        tier = c.tier,
        pads = c.pads,
        services = c.services,
        player = true,
        colony = c,
        pos = { x = 0, y = 0, z = 0 },
    }
end

colony.NEEDS = NEEDS

return colony

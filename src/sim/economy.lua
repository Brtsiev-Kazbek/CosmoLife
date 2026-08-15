-- Markets.
--
-- A market never stores a price.  It stores *stock*, and derives the price
-- from stock against the local equilibrium.  Everything the player can do --
-- buying out a supply, flooding a world with grain, blockading a war zone --
-- therefore moves prices for free, and the numbers stay internally consistent
-- without any global bookkeeping.
--
--   equilibrium  what the world wants to be holding
--   stock        what it is holding right now
--   price        base * (equilibrium / stock) ^ elasticity * local modifiers

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local config = require("src.config")
local commodities = require("src.sim.commodities")
local production = require("src.sim.production")
local factions = require("src.sim.factions")

local economy = {}

local ELASTICITY = 0.42
local PRICE_MIN, PRICE_MAX = 0.32, 3.6
local SPREAD = 0.06                 -- half the bid/ask gap

local Market = class("Market")
economy.Market = Market

--- opts: economyId, population, techLevel, lawLevel, factionId, wealth,
---       kind ("station" | "settlement" | "outpost"), seed
function Market:init(opts)
    self.seed = opts.seed or 1
    self.economyId = opts.economyId or "industrial"
    self.population = math.max(20, opts.population or 5000)
    self.techLevel = util.clamp(opts.techLevel or 5, 1, 12)
    self.lawLevel = util.clamp(opts.lawLevel or 0.5, 0, 1)
    self.factionId = opts.factionId or "independent"
    self.wealth = opts.wealth or 1
    self.kind = opts.kind or "station"
    self.conflict = opts.conflict or 0

    self.stock = {}
    self.equilibrium = {}
    self.events = {}          -- { commodity -> { mul, daysLeft, text } }
    self.lastDay = opts.day or 0
    self.blackMarket = self.lawLevel < 0.45 or opts.blackMarket or false

    self:_buildBaseline()
    self:_seedStock()
end

--- Population scaling: a tiny outpost trades in tens of tonnes, a core world
--- in thousands.  Log scaling keeps the numbers readable.
function Market:_volumeScale()
    local p = self.population
    return util.clamp(6 + 26 * math.log(1 + p / 400) / math.log(60), 6, 460) * self.wealth
end

function Market:_buildBaseline()
    local eco = commodities.economy(self.economyId)
    local rng = Rng.new(self.seed, "market")
    local scale = self:_volumeScale()
    self._bias = {}

    for _, c in ipairs(commodities.list) do
        local prod = eco.produces[c.id] or 0
        local cons = eco.consumes[c.id] or 0
        local traded = prod > 0 or cons > 0

        -- everyone trades the staples; luxury and tech goods need a market
        if not traded then
            if c.category == "food" or c.category == "energy" then
                traded = rng:bool(0.75)
            elseif c.category == "tech" then
                traded = self.techLevel >= 7 and rng:bool(0.6)
            elseif c.category == "illicit" then
                traded = self.blackMarket and rng:bool(0.7)
            elseif c.category == "arms" then
                traded = rng:bool(0.45)
            elseif c.category == "people" then
                traded = self.population > 4000 and rng:bool(0.5)
            else
                traded = rng:bool(0.45)
            end
        end
        if c.category == "illicit" and not self.blackMarket then traded = false end

        if traded then
            local bias = prod - cons
            local demandSide = math.max(0, -bias)
            local supplySide = math.max(0, bias)
            -- price per unit modulates how much of it a world keeps around
            local bulk = util.clamp(400 / (c.base ^ 0.55), 0.15, 6)
            local eq = scale * bulk * (0.55 + supplySide * 0.9 + demandSide * 0.12)
            eq = eq * rng:range(0.82, 1.22)
            self.equilibrium[c.id] = math.max(4, math.floor(eq))
            -- remembered so the initial fill level can lean the same way:
            -- producers start with a glut, consumers with a shortage
            self._bias[c.id] = bias
        end
    end
end

function Market:_seedStock()
    -- Seeded per commodity rather than drawing from one stream in table order.
    -- `pairs` order over a hash table is not stable between processes, and it
    -- measurably was not: the same seed gave grain stocks from 862 to 1079 on
    -- five consecutive runs, which is the one thing this project promises never
    -- to do.  Keying the draw on the id also means adding a commodity does not
    -- shift the fill of every commodity after it.
    local rng = Rng.new(0)
    for id, eq in pairs(self.equilibrium) do
        rng:seed(self.seed, "stock", id)
        local bias = self._bias[id] or 0
        local fill = util.clamp(0.55 + bias * 0.22 + rng:range(-0.25, 0.25), 0.08, 2.2)
        self.stock[id] = math.max(0, math.floor(eq * fill))
    end
end

-- ---------------------------------------------------------------------------
-- Pricing
-- ---------------------------------------------------------------------------

--- Local modifiers that apply on top of scarcity.
function Market:_modifier(c)
    local m = 1
    if c.category == "tech" or c.id == "computers" or c.id == "robotics" then
        m = m * (1 - (self.techLevel - 6) * 0.035)
    end
    if c.category == "illicit" then
        m = m * (1 + self.lawLevel * 1.6)
    end
    if c.legality == "restricted" then
        m = m * (1 + self.lawLevel * 0.5)
    end
    -- a war zone pays for guns, medicine and food, and cannot sell luxuries
    if self.conflict > 0 then
        if c.category == "arms" then m = m * (1 + self.conflict * 0.9) end
        if c.id == "medicine" then m = m * (1 + self.conflict * 0.6) end
        if c.category == "food" then m = m * (1 + self.conflict * 0.35) end
        if c.category == "consumer" and c.category ~= "food" then m = m * (1 - self.conflict * 0.2) end
    end
    local ev = self.events[c.id]
    if ev then m = m * ev.mul end
    return m
end

--- Mid price for one unit.
function Market:price(id)
    local eq = self.equilibrium[id]
    if not eq then return nil end
    local c = commodities.get(id)
    local stock = math.max(self.stock[id] or 0, 0)
    local ratio = eq / math.max(stock, eq * 0.05)
    local scarcity = util.clamp(ratio ^ ELASTICITY, PRICE_MIN, PRICE_MAX)
    return c.base * scarcity * self:_modifier(c)
end

--- What the player pays to buy one unit here.
function Market:buyPrice(id)
    local p = self:price(id)
    if not p then return nil end
    return math.max(1, math.floor(p * (1 + SPREAD) + 0.5))
end

--- What the player receives for selling one unit here.
function Market:sellPrice(id)
    local p = self:price(id)
    if not p then return nil end
    return math.max(1, math.floor(p * (1 - SPREAD) + 0.5))
end

function Market:trades(id) return self.equilibrium[id] ~= nil end
function Market:available(id) return math.floor(self.stock[id] or 0) end

--- How many units the market is still willing to absorb before its price
--- collapses.  Keeps the player from dumping 500 tonnes into a hamlet.
function Market:absorbable(id)
    local eq = self.equilibrium[id]
    if not eq then return 0 end
    return math.max(0, math.floor(eq * 2.6 - (self.stock[id] or 0)))
end

--- Executes a purchase; returns units actually bought and the total cost.
function Market:buy(id, qty)
    if not self:trades(id) or qty <= 0 then return 0, 0 end
    local have = self:available(id)
    qty = math.min(qty, have)
    local total = 0
    -- price is recomputed per unit so bulk purchases really do walk the book
    for _ = 1, qty do
        total = total + self:buyPrice(id)
        self.stock[id] = self.stock[id] - 1
    end
    return qty, total
end

--- Executes a sale; returns units sold and the total paid to the player.
function Market:sell(id, qty)
    if not self:trades(id) or qty <= 0 then return 0, 0 end
    qty = math.min(qty, self:absorbable(id))
    local total = 0
    for _ = 1, qty do
        total = total + self:sellPrice(id)
        self.stock[id] = (self.stock[id] or 0) + 1
    end
    return qty, total
end

--- Preview of a bulk trade without mutating anything.
function Market:quote(id, qty, selling)
    if not self:trades(id) then return 0, 0 end
    local savedStock = self.stock[id]
    local n, total
    if selling then n, total = self:sell(id, qty) else n, total = self:buy(id, qty) end
    self.stock[id] = savedStock
    return n, total
end

-- ---------------------------------------------------------------------------
-- Simulation
-- ---------------------------------------------------------------------------

--- Advances the market to `day`.  Cheap enough to call lazily on arrival,
--- which is how unvisited systems stay free.
function Market:update(day)
    local days = day - self.lastDay
    if days <= 0 then return end
    self.lastDay = day
    -- long absences are collapsed: markets converge, so simulating 400 days
    -- step by step buys nothing
    local steps = math.min(math.ceil(days), 40)
    local stepDays = days / steps
    local rng = Rng.new(self.seed, "tick", math.floor(day))
    -- One drift stream per commodity, seeded once per update and kept between
    -- updates.
    --
    -- Per commodity for the same reason the initial fill is: `pairs` order is
    -- not stable between processes. Seeded once rather than per step because
    -- re-seeding is a hash and a discard, and doing it forty times per
    -- commodity per update was most of the 0.68 ms a market tick had grown to.
    -- Separate objects from `rng` so that walking the table cannot move the
    -- event roll below along with it.
    self._drift = self._drift or {}
    local drift = self._drift
    for id in pairs(self.equilibrium) do
        drift[id] = drift[id] or Rng.new(0)
        drift[id]:seed(self.seed, "drift", math.floor(day), id)
    end

    -- How well the world's own industry is fed.
    --
    -- Its outputs restock at a rate gated by this; its inputs are eaten by
    -- making them. Before this, a refinery with no ore at all produced alloys
    -- at exactly its usual rate, which meant nothing upstream of a world could
    -- ever affect it -- no blockade, no war on the route, no player buying out
    -- the ore. Recomputed each step, because the step is where the inputs are
    -- consumed.
    self._need = self._need or production.demand(self.economyId, self.equilibrium)
    local need = self._need
    local supply, limiting = production.supplyOf(need, self.stock)
    self.supply, self.limiting = supply, limiting

    for step = 1, steps do
        supply = production.supplyOf(need, self.stock)
        for id, eq in pairs(self.equilibrium) do
            local c = commodities.get(id)
            local stock = self.stock[id] or 0
            local target = production.target(self.economyId, id, eq, supply)
            local gap = target - stock
            stock = stock + gap * config.economy.restockRate * stepDays
            stock = stock + eq * drift[id]:gauss(0, c.volatility * config.economy.driftAmplitude) * stepDays
            if c.perishable then stock = stock * (1 - c.perishable * stepDays) end
            self.stock[id] = math.max(0, stock)
        end
        production.consume(need, self.stock, supply, stepDays)
    end
    self.supply, self.limiting = production.supplyOf(need, self.stock)

    for id, ev in pairs(self.events) do
        ev.daysLeft = ev.daysLeft - days
        if ev.daysLeft <= 0 then self.events[id] = nil end
    end

    -- occasional local shock: a harvest failure, a strike, a new contract
    if rng:bool(math.min(0.5, 0.06 * days)) then
        self:_rollEvent(rng, day)
    end
end

local EVENT_TEXT = {
    boom = { "%s: bumper harvest", "%s: new seam opened", "%s: surplus released from stores" },
    bust = { "%s: crop blight reported", "%s: strike halts production", "%s: convoy lost to raiders" },
}

function Market:_rollEvent(rng, day)
    local ids = {}
    for id in pairs(self.equilibrium) do ids[#ids + 1] = id end
    if #ids == 0 then return end
    table.sort(ids)
    local id = ids[rng:int(1, #ids)]
    local c = commodities.get(id)
    local bust = rng:bool(0.5)
    local mul = bust and rng:range(1.35, 2.1) or rng:range(0.55, 0.78)
    self.events[id] = {
        mul = mul,
        daysLeft = rng:range(3, 14),
        text = string.format(rng:pick(EVENT_TEXT[bust and "bust" or "boom"]), c.name),
    }
    if bust then
        self.stock[id] = (self.stock[id] or 0) * rng:range(0.3, 0.6)
    else
        self.stock[id] = (self.stock[id] or 0) + self.equilibrium[id] * rng:range(0.4, 0.9)
    end
end

--- Commodity ids this market trades, ordered for display.
function Market:tradedIds()
    local out = {}
    for _, c in ipairs(commodities.list) do
        if self.equilibrium[c.id] then out[#out + 1] = c.id end
    end
    return out
end

--- The best thing to carry away from here, as a hint for the trade computer.
function Market:bestExports(n)
    local out = {}
    for id in pairs(self.equilibrium) do
        local c = commodities.get(id)
        local p = self:price(id)
        if p and self:available(id) > 8 then
            out[#out + 1] = { id = id, ratio = p / c.base, price = self:buyPrice(id) }
        end
    end
    table.sort(out, function(a, b) return a.ratio < b.ratio end)
    local top = {}
    for i = 1, math.min(n or 5, #out) do top[i] = out[i] end
    return top
end

function Market:save()
    local stock = {}
    for k, v in pairs(self.stock) do stock[k] = math.floor(v * 100) / 100 end
    return { stock = stock, lastDay = self.lastDay, events = self.events }
end

function Market:load(data)
    if not data then return end
    if data.stock then
        for k, v in pairs(data.stock) do
            if self.equilibrium[k] then self.stock[k] = v end
        end
    end
    self.lastDay = data.lastDay or self.lastDay
    self.events = data.events or {}
end

-- ---------------------------------------------------------------------------
-- Construction helpers
-- ---------------------------------------------------------------------------

--- Builds the market for a docking location (station, settlement, outpost).
function economy.marketFor(place, system, day, conflict)
    local faction = factions.get(place.factionId or system.factionId)
    return Market.new({
        seed = place.seed,
        economyId = place.economyId,
        population = place.population,
        techLevel = place.techLevel or system.techLevel,
        lawLevel = place.lawLevel or (faction.lawLevel or 0.5),
        factionId = place.factionId or system.factionId,
        wealth = place.wealth or system.wealth or 1,
        kind = place.kind,
        day = day or 0,
        conflict = conflict or 0,
        blackMarket = place.blackMarket,
    })
end

--- Profit estimate for a route, used by the trade computer and by NPC traders.
function economy.routeProfit(from, to, cargoSpace, credits)
    local best = { profit = 0 }
    for _, id in ipairs(from:tradedIds()) do
        if to:trades(id) then
            local buy = from:buyPrice(id)
            local sell = to:sellPrice(id)
            local units = math.min(cargoSpace or 1e9, from:available(id), to:absorbable(id))
            if credits then units = math.min(units, math.floor(credits / math.max(buy, 1))) end
            local profit = (sell - buy) * units
            if profit > best.profit then
                best = { id = id, units = units, buy = buy, sell = sell, profit = profit }
            end
        end
    end
    return best
end

return economy

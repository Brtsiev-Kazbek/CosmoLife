-- The infinite galaxy.
--
-- Space is divided into cubic sectors of `SECTOR` light years.  Hashing a
-- sector's integer coordinates gives its star count and each star's offset,
-- class and character, so the galaxy is unbounded, needs no storage, and looks
-- identical on every machine.  A spiral-arm density field modulates the star
-- count, which is what stops an infinite hash field from looking like uniform
-- noise: there are dense arms, sparse gulfs, and a bright core.

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local names = require("src.procgen.names")
local factions = require("src.sim.factions")
local commodities = require("src.sim.commodities")

local Galaxy = class("Galaxy")

-- LuaJIT keeps math.atan2; 5.3+ folded it into math.atan(y, x).
local atan2 = math.atan2 or math.atan

local SECTOR = 12                -- light years per sector edge
local MAX_PER_SECTOR = 4
local DISC_SCALE = 42            -- vertical falloff of the galactic disc, ly
local ARM_COUNT = 4
local ARM_TIGHTNESS = 0.16
local CORE_RADIUS = 380          -- the bulge is small and very bright

Galaxy.SECTOR = SECTOR

local STAR_CLASSES = {
    { class = "M", weight = 62, color = { 1.00, 0.52, 0.36 }, radius = 0.42, lum = 0.06, temp = 3200 },
    { class = "K", weight = 16, color = { 1.00, 0.72, 0.46 }, radius = 0.72, lum = 0.35, temp = 4500 },
    { class = "G", weight = 10, color = { 1.00, 0.94, 0.80 }, radius = 1.00, lum = 1.00, temp = 5700 },
    { class = "F", weight = 5,  color = { 0.92, 0.94, 1.00 }, radius = 1.25, lum = 3.20, temp = 6800 },
    { class = "A", weight = 3,  color = { 0.80, 0.86, 1.00 }, radius = 1.70, lum = 14.0, temp = 8800 },
    { class = "B", weight = 1.2, color = { 0.68, 0.78, 1.00 }, radius = 3.20, lum = 90.0, temp = 16000 },
    { class = "T", weight = 1.4, color = { 0.62, 0.30, 0.28 }, radius = 0.16, lum = 0.002, temp = 1100, brown = true },
    { class = "D", weight = 1.0, color = { 0.86, 0.92, 1.00 }, radius = 0.02, lum = 0.01, temp = 12000, dwarf = true },
    { class = "N", weight = 0.25, color = { 0.75, 0.85, 1.00 }, radius = 0.005, lum = 0.4, temp = 60000, neutron = true },
}

local CLASS_TOTAL = 0
for _, c in ipairs(STAR_CLASSES) do CLASS_TOTAL = CLASS_TOTAL + c.weight end

local GOVERNMENTS = {
    { id = "anarchy",     name = "Anarchy",      law = 0.02 },
    { id = "feudal",      name = "Feudal",       law = 0.30 },
    { id = "dictatorship", name = "Dictatorship", law = 0.55 },
    { id = "corporate",   name = "Corporate",    law = 0.62 },
    { id = "confederacy", name = "Confederacy",  law = 0.70 },
    { id = "democracy",   name = "Democracy",    law = 0.82 },
    { id = "cooperative", name = "Cooperative",  law = 0.78 },
}
local GOV_BY_ID = {}
for _, g in ipairs(GOVERNMENTS) do GOV_BY_ID[g.id] = g end

-- ---------------------------------------------------------------------------

function Galaxy:init(seed)
    self.seed = seed or 20250811
    self.cache = {}          -- sector key -> array of system stubs
    self.cacheOrder = {}
    -- a chart view touches thousands of sectors; keep enough of them that
    -- panning does not thrash the cache
    self.cacheLimit = 6000
    self.territory = {}
end

local function sectorKey(x, y, z)
    return x .. "," .. y .. "," .. z
end

--- Territory lookup, memoised per sector.
--
-- Claim cells are six sectors across, so resolving ownership per sector rather
-- than per star is finer than the diagram it samples -- and it turns the most
-- expensive part of generating a stub (27 claim points) into one table lookup
-- for every star in the sector.  That is what makes opening the chart, which
-- touches thousands of sectors at once, affordable.
function Galaxy:_territory(sx, sy, sz)
    local key = sectorKey(sx, sy, sz)
    local hit = self.territory[key]
    if hit then return hit[1], hit[2], hit[3] end
    local owner, frontier, neighbour = factions.territoryAt(sx + 0.5, sy + 0.5, sz + 0.5)
    self.territory[key] = { owner, frontier, neighbour }
    return owner, frontier, neighbour
end

--- Star density at a galactic position, 0..1.
-- Logarithmic spiral arms over a disc, plus a dense core.
function Galaxy:density(x, y, z)
    local r = math.sqrt(x * x + z * z)
    local disc = math.exp(-(y * y) / (2 * DISC_SCALE * DISC_SCALE))
    if r < 1 then return disc end

    local core = math.exp(-(r / CORE_RADIUS) ^ 1.5) * 0.85
    local theta = atan2(z, x)
    -- distance in angle to the nearest arm at this radius
    local armPhase = math.log(r + 1) / ARM_TIGHTNESS
    local best = math.huge
    for i = 0, ARM_COUNT - 1 do
        local target = armPhase + i * (2 * math.pi / ARM_COUNT)
        local d = (theta - target) % (2 * math.pi)
        if d > math.pi then d = 2 * math.pi - d end
        if d < best then best = d end
    end
    local armWidth = 0.55
    local arm = math.exp(-(best * best) / (2 * armWidth * armWidth))
    local field = util.clamp(0.10 + arm * 0.85 + core, 0, 1.1)
    return util.clamp(field * disc, 0, 1)
end

--- All systems in one sector (generated on demand, then cached).
function Galaxy:sector(sx, sy, sz)
    local key = sectorKey(sx, sy, sz)
    local hit = self.cache[key]
    if hit then return hit end

    local rng = Rng.new(self.seed, sx, sy, sz)
    local cx = (sx + 0.5) * SECTOR
    local cy = (sy + 0.5) * SECTOR
    local cz = (sz + 0.5) * SECTOR
    local density = self:density(cx, cy, cz)

    local list = {}
    local expected = density * MAX_PER_SECTOR
    local count = math.floor(expected)
    if rng:float() < (expected - count) then count = count + 1 end

    for i = 1, count do
        list[i] = self:_makeStub(rng, sx, sy, sz, i)
    end

    self.cache[key] = list
    self.cacheOrder[#self.cacheOrder + 1] = key
    if #self.cacheOrder > self.cacheLimit then
        local old = table.remove(self.cacheOrder, 1)
        self.cache[old] = nil
    end
    return list
end

--- Rolls the "front page" of a system: everything the galaxy map needs.
-- The full contents (planets, stations, markets) are built lazily by
-- `procgen.system` from the same seed.
function Galaxy:_makeStub(rng, sx, sy, sz, index)
    local id = string.format("%d.%d.%d.%d", sx, sy, sz, index)
    local seed = Rng.hash(self.seed, sx, sy, sz, index)
    local srng = Rng.new(seed)

    local x = (sx + srng:float()) * SECTOR
    local y = (sy + srng:float()) * SECTOR
    local z = (sz + srng:float()) * SECTOR

    -- star class
    local roll = srng:float() * CLASS_TOTAL
    local cls = STAR_CLASSES[#STAR_CLASSES]
    for _, c in ipairs(STAR_CLASSES) do
        roll = roll - c.weight
        if roll <= 0 then cls = c break end
    end

    local owner, frontier, neighbour = self:_territory(sx, sy, sz)
    local faction = factions.get(owner)

    -- population: habitability drives it, frontier and star class temper it
    local hab = 1.0
    if cls.brown or cls.dwarf or cls.neutron then hab = 0.12 end
    if cls.class == "B" then hab = 0.35 end
    local popRoll = srng:float()
    local population = 0
    if popRoll < 0.10 * hab then
        population = 0                                    -- surveyed, unsettled
    elseif popRoll < 0.55 then
        population = math.floor(srng:range(400, 90000) * hab)
    elseif popRoll < 0.88 then
        population = math.floor(srng:range(90000, 9e6) * hab)
    else
        population = math.floor(srng:range(9e6, 4.2e9) * hab)
    end
    if owner == "independent" then population = math.floor(population * 0.45) end

    local gov
    if population == 0 then
        gov = GOV_BY_ID.anarchy
    elseif owner == "independent" then
        gov = srng:pick({ GOV_BY_ID.anarchy, GOV_BY_ID.feudal, GOV_BY_ID.confederacy, GOV_BY_ID.cooperative })
    elseif faction.ethos == "criminal" then
        gov = srng:pick({ GOV_BY_ID.anarchy, GOV_BY_ID.feudal, GOV_BY_ID.corporate })
    elseif faction.ethos == "authoritarian" then
        gov = srng:pick({ GOV_BY_ID.dictatorship, GOV_BY_ID.feudal, GOV_BY_ID.corporate })
    elseif faction.ethos == "technocratic" then
        gov = srng:pick({ GOV_BY_ID.corporate, GOV_BY_ID.cooperative, GOV_BY_ID.democracy })
    else
        gov = srng:pick({ GOV_BY_ID.democracy, GOV_BY_ID.confederacy, GOV_BY_ID.corporate, GOV_BY_ID.cooperative })
    end

    -- tech level from population, faction bias and a little luck
    local tech = 1 + math.log(1 + population / 500) / math.log(9) + (faction.techBias or 0) * 6
    tech = util.clamp(math.floor(tech + srng:range(-1.5, 1.8)), 1, 12)

    -- primary economy
    local eco
    if population < 3000 then
        eco = srng:pick({ "colony", "extraction", "extraction", "agricultural" })
    elseif tech >= 9 then
        eco = srng:pick({ "hightech", "hightech", "industrial", "service", "military" })
    elseif tech >= 6 then
        eco = srng:pick({ "industrial", "refinery", "service", "agricultural", "military", "terraforming" })
    else
        eco = srng:pick({ "agricultural", "extraction", "refinery", "colony", "tourism" })
    end

    local lawLevel = util.clamp((gov.law * 0.6 + (faction.lawLevel or 0.4) * 0.4) * (1 - frontier * 0.35), 0, 1)

    return {
        id = id,
        seed = seed,
        sector = { sx, sy, sz },
        index = index,
        name = names.system(seed),
        x = x, y = y, z = z,           -- light years
        starClass = cls.class,
        star = cls,
        factionId = owner,
        neighbourFactionId = neighbour,
        frontier = frontier,
        government = gov.id,
        governmentName = gov.name,
        lawLevel = lawLevel,
        population = population,
        techLevel = tech,
        economyId = eco,
        economyName = commodities.economy(eco).name,
        wealth = util.clamp(0.5 + tech / 14 + math.log(1 + population) / 30, 0.4, 2.2),
        visited = false,
    }
end

--- Every system within `radius` light years of a point.
--
-- The `distance` it writes onto each system is only good until the next sweep:
-- sector contents are cached and shared, so a second call from anywhere
-- rewrites the field on the same tables. Read it before doing anything else,
-- or measure the distance yourself.
--
-- `halfHeight` limits how far above and below the plane sectors are scanned.
-- The galaxy is a thin disc, so a chart looking at a 200 ly circle does not
-- need the 200 ly of empty space over it: passing a slab height turns an
-- O(n^3) sweep into an O(n^2) one and is what keeps the galaxy map cheap.
function Galaxy:systemsNear(x, y, z, radius, halfHeight)
    halfHeight = halfHeight or radius
    local out = {}
    local r2 = radius * radius
    local s0x = math.floor((x - radius) / SECTOR)
    local s1x = math.floor((x + radius) / SECTOR)
    local s0y = math.floor((y - halfHeight) / SECTOR)
    local s1y = math.floor((y + halfHeight) / SECTOR)
    local s0z = math.floor((z - radius) / SECTOR)
    local s1z = math.floor((z + radius) / SECTOR)
    for sz = s0z, s1z do
        for sy = s0y, s1y do
            for sx = s0x, s1x do
                for _, sys in ipairs(self:sector(sx, sy, sz)) do
                    local dx, dy, dz = sys.x - x, sys.y - y, sys.z - z
                    local d2 = dx * dx + dy * dy + dz * dz
                    if d2 <= r2 then
                        sys.distance = math.sqrt(d2)
                        out[#out + 1] = sys
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

--- Looks a system up by its id string, regenerating it from scratch.
function Galaxy:byId(id)
    local sx, sy, sz, i = id:match("^(-?%d+)%.(-?%d+)%.(-?%d+)%.(%d+)$")
    if not sx then return nil end
    local list = self:sector(tonumber(sx), tonumber(sy), tonumber(sz))
    return list[tonumber(i)]
end

--- Nearest system to a point -- used to pick a start world and to snap the
--- galaxy map cursor.
function Galaxy:nearest(x, y, z, maxRadius)
    local r = 20
    while r <= (maxRadius or 320) do
        local list = self:systemsNear(x, y, z, r)
        if #list > 0 then return list[1] end
        r = r * 2
    end
    return nil
end

--- Picks a pleasant starting system: inhabited, lawful, mid tech, not a
--- warzone -- so a new player has a market and a shipyard to learn on.
function Galaxy:findStartSystem()
    local rng = Rng.new(self.seed, "start")
    for attempt = 1, 400 do
        local a = rng:range(0, math.pi * 2)
        local r = rng:range(600, 900)
        local x = math.cos(a) * r
        local z = math.sin(a) * r
        local y = rng:gauss(0, 12)
        local list = self:systemsNear(x, y, z, 60)
        for _, s in ipairs(list) do
            if s.population > 200000 and s.techLevel >= 6 and s.lawLevel > 0.55
               and s.frontier < 0.5 and not s.star.neutron then
                return s
            end
        end
    end
    -- fall back to anything at all
    return self:nearest(0, 0, 800, 4000)
end

Galaxy.governments = GOVERNMENTS
Galaxy.starClasses = STAR_CLASSES

return Galaxy

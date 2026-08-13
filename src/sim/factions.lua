-- Factions, territory and diplomacy.
--
-- Territory is a Voronoi diagram over an infinite lattice of "claim points":
-- one point per 6 sector cell, its owner picked by hashing the cell.  Looking
-- up the owner of a position only needs the 27 neighbouring cells, so an
-- endless galaxy has coherent, contiguous empires with natural borders -- and
-- the distance to the second nearest claim gives us "how frontier is this
-- system", which drives piracy, garrisons and war.

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local util = require("src.lib.util")

local factions = {}

local CLAIM_CELL = 6      -- sectors per claim cell

factions.list = {
    {
        id = "federation", name = "Solar Federation", short = "FED",
        color = { 0.35, 0.58, 0.92 }, ethos = "corporate",
        blurb = "Old money, older bureaucracy. Runs the densest trade lanes and taxes every one of them.",
        lawLevel = 0.75, techBias = 0.15, tradeBias = 0.25, militaryBias = 0.1,
    },
    {
        id = "concord", name = "Terran Concord", short = "CON",
        color = { 0.85, 0.78, 0.42 }, ethos = "democratic",
        blurb = "A slow, argumentative union of chartered worlds. Good courts, thin fleets.",
        lawLevel = 0.85, techBias = 0.1, tradeBias = 0.15, militaryBias = -0.05,
    },
    {
        id = "dominion", name = "Kessari Dominion", short = "DOM",
        color = { 0.82, 0.34, 0.30 }, ethos = "authoritarian",
        blurb = "Conscription, quotas and a very efficient navy. Trade here is a privilege, not a right.",
        lawLevel = 0.65, techBias = 0.05, tradeBias = -0.1, militaryBias = 0.35,
    },
    {
        id = "syndicate", name = "Orion Syndicate", short = "SYN",
        color = { 0.62, 0.40, 0.78 }, ethos = "criminal",
        blurb = "Not a government so much as an agreement between people who own things.",
        lawLevel = 0.20, techBias = 0.0, tradeBias = 0.3, militaryBias = 0.1,
    },
    {
        id = "coalition", name = "Free Coalition", short = "FRE",
        color = { 0.40, 0.78, 0.52 }, ethos = "libertarian",
        blurb = "Independent worlds that agreed on exactly one thing: nobody else gets to tax them.",
        lawLevel = 0.35, techBias = -0.05, tradeBias = 0.2, militaryBias = -0.1,
    },
    {
        id = "conclave", name = "Aether Conclave", short = "AET",
        color = { 0.35, 0.80, 0.80 }, ethos = "technocratic",
        blurb = "Research collectives with warships. They will trade anything except an explanation.",
        lawLevel = 0.7, techBias = 0.4, tradeBias = 0.0, militaryBias = 0.05,
    },
}

factions.byId = {}
for i, f in ipairs(factions.list) do
    f.index = i
    factions.byId[f.id] = f
end

-- Pirates and the player's own colonies are not territorial powers but they
-- do need reputation slots.
factions.byId.pirates = {
    id = "pirates", name = "Pirate Clans", short = "PIR", index = 90,
    color = { 0.75, 0.35, 0.25 }, ethos = "criminal", lawLevel = 0,
    blurb = "Everyone who decided the shipping lanes were a resource.",
}
factions.byId.independent = {
    id = "independent", name = "Independents", short = "IND", index = 91,
    color = { 0.7, 0.7, 0.72 }, ethos = "neutral", lawLevel = 0.4,
    blurb = "Unclaimed systems, company towns and people who like it that way.",
}

function factions.get(id) return factions.byId[id] or factions.byId.independent end

-- ---------------------------------------------------------------------------
-- Territory
-- ---------------------------------------------------------------------------

--- The claim point of a lattice cell, in sector coordinates.
local function claimPoint(cx, cy, cz)
    local jx = Rng.hashf(cx, cy, cz, 11) - 0.5
    local jy = Rng.hashf(cx, cy, cz, 22) - 0.5
    local jz = Rng.hashf(cx, cy, cz, 33) - 0.5
    return (cx + 0.5 + jx * 0.8) * CLAIM_CELL,
           (cy + 0.5 + jy * 0.8) * CLAIM_CELL,
           (cz + 0.5 + jz * 0.8) * CLAIM_CELL
end

--- Owner of a claim cell.  Some cells are deliberately unowned, which is what
--- creates the lawless gaps between empires.
local function claimOwner(cx, cy, cz)
    local h = Rng.hashf(cx, cy, cz, 77)
    if h < 0.18 then return "independent" end
    local n = #factions.list
    local i = math.floor(Rng.hashf(cx, cy, cz, 88) * n) + 1
    return factions.list[math.min(i, n)].id
end

--- Returns owner id, frontier factor (0 = deep interior, 1 = contested border).
function factions.territoryAt(sx, sy, sz)
    local ccx = math.floor(sx / CLAIM_CELL)
    local ccy = math.floor(sy / CLAIM_CELL)
    local ccz = math.floor(sz / CLAIM_CELL)
    local best, bestD = nil, math.huge
    local secondD, secondOwner = math.huge, nil
    for oz = -1, 1 do
        for oy = -1, 1 do
            for ox = -1, 1 do
                local cx, cy, cz = ccx + ox, ccy + oy, ccz + oz
                local px, py, pz = claimPoint(cx, cy, cz)
                local dx, dy, dz = px - sx, py - sy, pz - sz
                local d = dx * dx + dy * dy * 2.2 + dz * dz  -- flattened: the galaxy is a disc
                local owner = claimOwner(cx, cy, cz)
                if d < bestD then
                    secondD, secondOwner = bestD, best
                    bestD, best = d, owner
                elseif d < secondD and owner ~= best then
                    secondD, secondOwner = d, owner
                end
            end
        end
    end
    local frontier = 0
    if secondD < math.huge and bestD > 0 then
        local ratio = math.sqrt(bestD) / math.sqrt(secondD)
        frontier = util.clamp((ratio - 0.55) / 0.45, 0, 1)
        if secondOwner == best then frontier = frontier * 0.3 end
    end
    return best or "independent", frontier, secondOwner
end

-- ---------------------------------------------------------------------------
-- Diplomacy: a live relations matrix that the world simulation evolves.
-- ---------------------------------------------------------------------------

local Diplomacy = class("Diplomacy")
factions.Diplomacy = Diplomacy

function Diplomacy:init(seed)
    self.rng = Rng.new(seed or 4242, "diplomacy")
    self.relations = {}       -- ["a|b"] = -1 .. 1
    self.wars = {}            -- ["a|b"] = { since = day, intensity = 0..1 }
    self.nextEventDay = 6
    for i = 1, #factions.list do
        for j = i + 1, #factions.list do
            local a, b = factions.list[i].id, factions.list[j].id
            self.relations[self:key(a, b)] = self.rng:range(-0.4, 0.5)
        end
    end
    -- one war is burning when the player starts; it gives the galaxy a shape
    local a = self.rng:pick(factions.list)
    local b = self.rng:pick(factions.list)
    if a.id ~= b.id then self:declareWar(a.id, b.id, 0) end
end

function Diplomacy:key(a, b)
    if a > b then a, b = b, a end
    return a .. "|" .. b
end

function Diplomacy:relation(a, b)
    if a == b then return 1 end
    if a == "pirates" or b == "pirates" then return -1 end
    return self.relations[self:key(a, b)] or 0
end

function Diplomacy:atWar(a, b)
    if a == b then return false end
    return self.wars[self:key(a, b)] ~= nil
end

function Diplomacy:declareWar(a, b, day)
    if a == b then return end
    local k = self:key(a, b)
    if self.wars[k] then return end
    self.wars[k] = { a = a, b = b, since = day or 0, intensity = self.rng:range(0.4, 1.0) }
    self.relations[k] = -1
end

function Diplomacy:makePeace(a, b, day)
    local k = self:key(a, b)
    if not self.wars[k] then return end
    self.wars[k] = nil
    self.relations[k] = -0.35
end

--- Is this system a war zone?  True when its owner fights someone who claims
--- territory nearby -- that is what puts fleets over a frontier world.
function Diplomacy:systemConflict(ownerId, neighbourId, frontier)
    if not neighbourId or ownerId == neighbourId then return 0 end
    if not self:atWar(ownerId, neighbourId) then return 0 end
    local w = self.wars[self:key(ownerId, neighbourId)]
    return util.clamp(frontier * 1.3, 0, 1) * (w and w.intensity or 1)
end

--- Advances diplomacy.  Called once per in-game day.
function Diplomacy:update(day)
    if day < self.nextEventDay then return nil end
    self.nextEventDay = day + self.rng:range(8, 26)
    local rng = self.rng

    -- relations drift toward zero, wars push them down
    for k, v in pairs(self.relations) do
        if self.wars[k] then
            self.relations[k] = math.max(-1, v - 0.05)
        else
            self.relations[k] = util.clamp(v + rng:range(-0.12, 0.14) - v * 0.05, -1, 1)
        end
    end

    -- peace talks
    for k, w in pairs(self.wars) do
        local length = day - w.since
        if length > 25 and rng:bool(0.35 + length * 0.004) then
            self:makePeace(w.a, w.b, day)
            return { type = "peace", a = w.a, b = w.b,
                     text = string.format("%s and %s have signed an armistice.",
                        factions.get(w.a).name, factions.get(w.b).name) }
        end
        w.intensity = util.clamp(w.intensity + rng:range(-0.15, 0.15), 0.2, 1)
    end

    -- new wars grow out of bad relations
    local worstK, worstV = nil, 0.0
    for k, v in pairs(self.relations) do
        if not self.wars[k] and v < worstV then worstK, worstV = k, v end
    end
    if worstK and worstV < -0.55 and rng:bool(0.45) then
        local a, b = worstK:match("([^|]+)|([^|]+)")
        self:declareWar(a, b, day)
        return { type = "war", a = a, b = b,
                 text = string.format("%s has declared war on %s.",
                    factions.get(a).name, factions.get(b).name) }
    end
    return nil
end

function Diplomacy:save()
    return { relations = self.relations, wars = self.wars, nextEventDay = self.nextEventDay }
end

function Diplomacy:load(data)
    if not data then return end
    self.relations = data.relations or self.relations
    self.wars = data.wars or {}
    self.nextEventDay = data.nextEventDay or 6
end

--- Every war currently burning, as a list.
function Diplomacy:activeWars()
    local out = {}
    for _, w in pairs(self.wars) do out[#out + 1] = w end
    table.sort(out, function(x, y) return x.since < y.since end)
    return out
end

return factions

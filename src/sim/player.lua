-- The player's commander record.
--
-- Everything here is persistent state.  The flying ship (position, velocity,
-- shields in flight) lives in the flight state and is rebuilt from this on
-- every launch, which keeps saving trivial: the commander is the save file.

local class = require("src.lib.class")
local util = require("src.lib.util")
local config = require("src.config")
local ships = require("src.procgen.ships")
local equipment = require("src.sim.equipment")
local commodities = require("src.sim.commodities")
local factions = require("src.sim.factions")

local Player = class("Player")

function Player:init(opts)
    opts = opts or {}
    self.name = opts.name or "Commander"
    self.seed = opts.seed or 1

    self.shipDef = opts.shipDef or ships.generate(self.seed, opts.role or "shuttle")
    self.installed = opts.installed or { "pulse1", "shield1", "rack1" }
    self.stats = equipment.derive(self.shipDef.stats, self.installed)

    self.credits = opts.credits or config.economy.startingCredits
    self.cargo = {}
    self.hull = self.stats.maxHull
    self.shield = self.stats.maxShield
    self.fuel = self.stats.fuel
    self.shieldCells = self.stats.shieldCells or 0
    self.missiles = 2

    self.reputations = {}
    self.bounties = {}
    self.missions = {}
    self.colonies = {}
    self.knownSystems = {}
    self.log = {}

    self.systemId = opts.systemId
    self.dockedAt = nil

    self.record = {
        kills = 0, deaths = 0, jumps = 0, trades = 0, profit = 0,
        distanceLy = 0, missionsDone = 0, missionsFailed = 0, coloniesFounded = 0,
        landings = 0, scanned = 0, dockings = 0, walked = 0,
    }
end

-- ---------------------------------------------------------------------------
-- Ship
-- ---------------------------------------------------------------------------

--- Recomputes derived stats after outfitting.  Clamps live values so a
--- downgrade cannot leave the player with more shield than capacity.
function Player:refreshStats()
    self.stats = equipment.derive(self.shipDef.stats, self.installed)
    self.hull = math.min(self.hull, self.stats.maxHull)
    self.shield = math.min(self.shield, self.stats.maxShield)
    self.fuel = math.min(self.fuel, self.stats.fuel)
end

function Player:setShip(def, keepModules)
    self.shipDef = def
    if not keepModules then
        self.installed = { "pulse1", "shield1" }
    end
    self:refreshStats()
    self.hull = self.stats.maxHull
    self.shield = self.stats.maxShield
    self.fuel = self.stats.fuel
end

function Player:install(id)
    local e = equipment.get(id)
    if not e then return false, "unknown module" end
    -- one module per slot except utilities and cargo racks
    if e.slot ~= "utility" and e.slot ~= "cargo" and e.slot ~= "weapon" then
        for i = #self.installed, 1, -1 do
            local o = equipment.get(self.installed[i])
            if o and o.slot == e.slot then table.remove(self.installed, i) end
        end
    end
    if e.slot == "weapon" then
        local count = 0
        for _, oid in ipairs(self.installed) do
            local o = equipment.get(oid)
            if o and o.slot == "weapon" then count = count + 1 end
        end
        if count >= math.max(1, self.shipDef.stats.hardpoints or 1) then
            return false, "no free hardpoint"
        end
    end
    self.installed[#self.installed + 1] = id
    self:refreshStats()
    return true
end

function Player:uninstall(id)
    for i = #self.installed, 1, -1 do
        if self.installed[i] == id then
            table.remove(self.installed, i)
            self:refreshStats()
            return true
        end
    end
    return false
end

function Player:has(id)
    for _, v in ipairs(self.installed) do if v == id then return true end end
    return false
end

function Player:weapon() return equipment.activeWeapon(self.installed) end

-- ---------------------------------------------------------------------------
-- Cargo
-- ---------------------------------------------------------------------------

function Player:cargoCapacity() return math.floor(self.stats.cargo or 0) end

function Player:cargoUsed()
    local n = 0
    for id, qty in pairs(self.cargo) do
        n = n + qty * (commodities.byId[id] and commodities.byId[id].volume or 1)
    end
    -- mission cargo occupies the hold too
    return math.floor(n)
end

function Player:cargoFree() return self:cargoCapacity() - self:cargoUsed() end

--- Adds cargo, returns how many units actually fitted.
function Player:addCargo(id, qty)
    if qty <= 0 then return 0 end
    local vol = commodities.byId[id] and commodities.byId[id].volume or 1
    local fits = math.floor(self:cargoFree() / vol)
    local n = math.min(qty, fits)
    if n > 0 then self.cargo[id] = (self.cargo[id] or 0) + n end
    return n
end

function Player:removeCargo(id, qty)
    local have = self.cargo[id] or 0
    local n = math.min(qty, have)
    if n > 0 then
        self.cargo[id] = have - n
        if self.cargo[id] <= 0 then self.cargo[id] = nil end
    end
    return n
end

function Player:cargoCount(id) return self.cargo[id] or 0 end

--- Contraband currently aboard, given a local law level.
function Player:contraband(lawLevel)
    local out, value = {}, 0
    for id, qty in pairs(self.cargo) do
        local c = commodities.byId[id]
        if c then
            local legality = commodities.legalityIn(c, lawLevel or 0.5)
            if legality == "illegal" then
                out[#out + 1] = { id = id, qty = qty, name = c.name }
                value = value + qty * c.base
            end
        end
    end
    return out, value
end

-- ---------------------------------------------------------------------------
-- Money and standing
-- ---------------------------------------------------------------------------

function Player:spend(amount)
    if amount > self.credits then return false end
    self.credits = self.credits - amount
    return true
end

function Player:earn(amount)
    self.credits = self.credits + amount
    return self.credits
end

function Player:reputation(factionId) return self.reputations[factionId] or 0 end

function Player:addReputation(factionId, delta)
    local v = util.clamp((self.reputations[factionId] or 0) + delta, -1, 1)
    self.reputations[factionId] = v
    -- helping one side of a war annoys the other
    return v
end

function Player:reputationName(factionId)
    local r = self:reputation(factionId)
    if r >= 0.75 then return "Allied" end
    if r >= 0.4 then return "Friendly" end
    if r >= 0.12 then return "Cordial" end
    if r > -0.12 then return "Neutral" end
    if r > -0.4 then return "Unfriendly" end
    if r > -0.75 then return "Hostile" end
    return "Enemy"
end

function Player:bounty(factionId) return self.bounties[factionId] or 0 end

function Player:addBounty(factionId, amount)
    self.bounties[factionId] = (self.bounties[factionId] or 0) + amount
    self:addReputation(factionId, -amount / 40000)
end

function Player:clearBounty(factionId)
    local b = self.bounties[factionId] or 0
    self.bounties[factionId] = nil
    return b
end

function Player:totalBounty()
    local n = 0
    for _, v in pairs(self.bounties) do n = n + v end
    return n
end

--- Is a faction's law enforcement hostile on sight?
function Player:isWanted(factionId)
    return (self.bounties[factionId] or 0) > 0 or self:reputation(factionId) < -0.6
end

-- ---------------------------------------------------------------------------
-- Journal
-- ---------------------------------------------------------------------------

function Player:addLog(text, day, kind)
    table.insert(self.log, 1, { text = text, day = day or 0, kind = kind or "info" })
    for i = #self.log, 61, -1 do self.log[i] = nil end
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function Player:save()
    return {
        name = self.name,
        seed = self.seed,
        shipSeed = self.shipDef.seed,
        shipRole = self.shipDef.role,
        installed = self.installed,
        credits = self.credits,
        cargo = self.cargo,
        hull = self.hull,
        shield = self.shield,
        fuel = self.fuel,
        missiles = self.missiles,
        shieldCells = self.shieldCells,
        rankSeen = self.rankSeen,
        tutorial = self.tutorial,
        reputations = self.reputations,
        bounties = self.bounties,
        missions = self.missions,
        colonies = self.colonies,
        knownSystems = self.knownSystems,
        systemId = self.systemId,
        record = self.record,
        log = self.log,
    }
end

function Player:load(data)
    if not data then return false end
    self.name = data.name or self.name
    self.seed = data.seed or self.seed
    if data.shipSeed and data.shipRole then
        self.shipDef = ships.generate(data.shipSeed, data.shipRole)
    end
    self.installed = data.installed or self.installed
    self:refreshStats()
    self.credits = data.credits or self.credits
    self.cargo = data.cargo or {}
    self.hull = math.min(data.hull or self.stats.maxHull, self.stats.maxHull)
    self.shield = math.min(data.shield or self.stats.maxShield, self.stats.maxShield)
    self.fuel = math.min(data.fuel or self.stats.fuel, self.stats.fuel)
    self.missiles = data.missiles or 0
    self.shieldCells = data.shieldCells or 0
    self.rankSeen = data.rankSeen
    self.tutorial = data.tutorial
    self.reputations = data.reputations or {}
    self.bounties = data.bounties or {}
    self.missions = data.missions or {}
    self.colonies = data.colonies or {}
    self.knownSystems = data.knownSystems or {}
    self.systemId = data.systemId
    self.record = data.record or self.record
    self.log = data.log or {}
    return true
end

--- A one line summary for the save slot list.
function Player:summary()
    return string.format("%s  -  %s  -  %s cr", self.name, self.shipDef.roleName, util.money(self.credits))
end

return Player

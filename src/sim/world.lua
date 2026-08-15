-- The world: the clock, the galaxy, and everything persistent hanging off it.
--
-- One object owns the simulation so the render states stay thin.  The rule
-- that keeps an infinite galaxy affordable is *lazy, dated state*: nothing is
-- simulated until the player looks at it, and when they do, it is fast
-- forwarded from the day it was last touched to today.

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local config = require("src.config")
local serialize = require("src.lib.serialize")
local Galaxy = require("src.procgen.galaxy")
local systemGen = require("src.procgen.system")
local factions = require("src.sim.factions")
local economy = require("src.sim.economy")
local missionsMod = require("src.sim.missions")
local rumoursMod = require("src.sim.rumours")
local logisticsMod = require("src.sim.logistics")
local colonyMod = require("src.sim.colony")
local Player = require("src.sim.player")
local names = require("src.procgen.names")
local i18n = require("src.i18n")
local progression = require("src.sim.progression")

local World = class("World")

local SAVE_FILE = "cosmolife-save.lua"

function World:init(opts)
    opts = opts or {}
    self.seed = opts.seed or 20250811
    self.galaxy = Galaxy.new(self.seed)
    self.diplomacy = factions.Diplomacy.new(self.seed)
    self.day = opts.day or 0
    self.player = opts.player or Player.new({ seed = self.seed })

    self.markets = {}          -- portKey -> Market
    self.boards = {}           -- portKey -> mission board
    self.rumourCache = {}      -- portKey -> what the bar is saying
    self.news = {}
    self.system = nil          -- the expanded current system
    self.stub = nil
    self.visited = {}

    self.timeScale = 1
    self.paused = false
end

-- ---------------------------------------------------------------------------
-- Clock
-- ---------------------------------------------------------------------------

--- Advances the world clock.  `dt` is real seconds.
function World:update(dt)
    if self.paused then return end
    local before = self.day
    self.day = self.day + (dt / config.economy.dayLength) * self.timeScale
    if math.floor(self.day) > math.floor(before) then
        self:onNewDay(math.floor(self.day))
    end
    if self.system then
        systemGen.updateOrbits(self.system, self.day)
    end
    self:checkPromotion()
end

--- Announces a rank promotion once, when it happens.
function World:checkPromotion()
    local rank = progression.check(self.player)
    if not rank then return end
    local unlock = progression.UNLOCKS[rank.id]
    self.player:addLog(i18n.format("Promoted to {rank}.", { rank = i18n.translate(rank.name) }),
        self.day, "good")
    local hud = package.loaded["src.render.hud"]
    if hud then
        hud.message(i18n.format("Rank: {rank}", { rank = i18n.translate(rank.name) }), "good")
        if unlock then hud.message(i18n.translate(unlock), "info") end
    end
end

function World:onNewDay(day)
    local event = self.diplomacy:update(day)
    if event then self:addNews(event.text, "war") end

    for _, c in ipairs(self.player.colonies) do
        colonyMod.update(c, day)
        if c.tierUpPending then
            c.tierUpPending = nil
            self:addNews(string.format("%s has grown into a %s.", c.name, colonyMod.tierName(c.tier)), "colony")
            self.player:addLog(string.format("%s reached tier %d.", c.name, c.tier), day, "colony")
        end
        if c.unrest and not c.unrestReported then
            c.unrestReported = true
            self:addNews(string.format("Unrest on %s: supplies have run out.", c.name), "alert")
        elseif not c.unrest then
            c.unrestReported = false
        end
    end

    self:runFreight(day)
    rumoursMod.expire(self.player, day)

    local failed = missionsMod.expire(self.player, day)
    for _, m in ipairs(failed) do
        local title = missionsMod.title(m)
        self:addNews(i18n.format("Contract expired: {title}", { title = title }), "alert")
        self.player:addLog(i18n.format("Failed: {title}", { title = title }), day, "alert")
    end

    -- markets of the current system keep ticking while the player is here
    for _, m in pairs(self.markets) do m:update(day) end
end

--- A day's freight between the system's ports.
--
-- The visible traders are only ever a handful of ships crossing millions of
-- kilometres; measured in the selftest, one completes a run in fifteen seconds
-- of flight. If that were the only freight, the production chains would starve
-- while the player watched, and a lane would mean nothing.
--
-- So the haulage that would be happening anyway happens anyway: a few runs a
-- day, planned and settled against the same markets by the same code the NPC
-- traders use, whether or not anyone is in the room. The ships in the window
-- are instances of this, not a separate economy -- which is the only way a
-- galaxy this size can be alive without being simulated in full.
function World:runFreight(day)
    local sys = self.system
    if not sys then return end
    local ports = systemGen.ports(sys)
    if #ports < 2 then return end

    -- deterministic: same day, same system, same freight
    local rng = Rng.new(sys.seed or 1, "freight", math.floor(day))
    local runs = util.clamp(math.floor(#ports * 0.8), 1, 6)
    for _ = 1, runs do
        local a = rng:int(1, #ports)
        local b = rng:int(1, #ports)
        if a ~= b then
            local from, to = self:market(ports[a]), self:market(ports[b])
            local run = logisticsMod.plan(from, to)
            if run then
                logisticsMod.load(from, run)
                logisticsMod.unload(to, run)
            end
        end
    end
end

function World:addNews(text, kind)
    table.insert(self.news, 1, { text = text, day = self.day, kind = kind or "info" })
    for i = #self.news, 41, -1 do self.news[i] = nil end
end

function World:dateString() return util.date(self.day) end

-- ---------------------------------------------------------------------------
-- Systems
-- ---------------------------------------------------------------------------

--- Enters a system, expanding it and bringing its economy up to date.
function World:enterSystem(stub)
    if not stub then return nil end
    self.stub = stub
    self.system = systemGen.build(stub, self.diplomacy, self.day)
    self.player.systemId = stub.id
    self.visited[stub.id] = true
    self.player.knownSystems[stub.id] = {
        name = stub.name, x = stub.x, y = stub.y, z = stub.z,
        faction = stub.factionId, economy = stub.economyId, day = self.day,
    }

    -- attach the player's own colonies that live in this system
    for _, c in ipairs(self.player.colonies) do
        if c.systemId == stub.id then
            colonyMod.update(c, self.day)
            local port = colonyMod.asPort(c)
            -- find the body it sits on
            for _, b in ipairs(systemGen.landables(self.system)) do
                if b.seed == c.bodySeed then
                    port.body = b
                    port.bodyName = b.name
                    b.settlements = b.settlements or {}
                    b.settlements[#b.settlements + 1] = port
                    break
                end
            end
            self.system.settlements[#self.system.settlements + 1] = port
        end
    end
    systemGen.updateOrbits(self.system, self.day)

    missionsMod.recordSurvey(self.player, stub.id)
    return self.system
end

--- Key under which a port's mutable state is stored.
function World:portKey(port)
    return string.format("%s|%s", self.stub and self.stub.id or "?", tostring(port.seed))
end

--- The market for a port, created on first use and fast forwarded to today.
function World:market(port)
    local key = self:portKey(port)
    local m = self.markets[key]
    if not m then
        if port.colony then
            m = colonyMod.market(port.colony, self.day)
        else
            m = economy.marketFor(port, self.system, self.day, self.system and self.system.conflict or 0)
        end
        self.markets[key] = m
    end
    m:update(self.day)
    return m
end

--- The mission board for a port; regenerated when it goes stale.
function World:board(port)
    local key = self:portKey(port)
    local entry = self.boards[key]
    if not entry or (self.day - entry.day) > 3 then
        port.market = self:market(port)
        port.hasColonies = #self.player.colonies > 0
        entry = {
            day = self.day,
            list = missionsMod.generate(port, self.system, self.galaxy, self.diplomacy, self.day),
        }
        self.boards[key] = entry
    end
    -- drop anything already accepted
    local out = {}
    for _, m in ipairs(entry.list) do
        if m.state == "offered" then out[#out + 1] = m end
    end
    return out
end

--- What is being said at a port, cached the same way the contract board is.
--
-- Talk goes stale slower than a contract board: three days for contracts, five
-- for gossip, which is also what stops the bar rewriting itself every time the
-- player walks back in.
function World:rumours(port)
    local key = self:portKey(port)
    local entry = self.rumourCache[key]
    if not entry or (self.day - entry.day) > 5 then
        entry = {
            day = self.day,
            list = rumoursMod.generate({
                seed = port.seed or 1, day = self.day, place = port, stub = self.stub,
                galaxy = self.galaxy, diplomacy = self.diplomacy, player = self.player,
                market = self:market(port),
            }),
        }
        self.rumourCache[key] = entry
    end
    return entry.list
end

-- ---------------------------------------------------------------------------
-- Hyperspace
-- ---------------------------------------------------------------------------

--- Systems the player can reach from here with the fuel and drive they have.
function World:jumpTargets()
    if not self.stub then return {} end
    local range = self.player.stats.jumpRange or 10
    local list = self.galaxy:systemsNear(self.stub.x, self.stub.y, self.stub.z, range)
    local out = {}
    for _, s in ipairs(list) do
        if s.id ~= self.stub.id then
            s.fuelCost = self:fuelCost(s.distance)
            s.reachable = s.fuelCost <= self.player.fuel
            out[#out + 1] = s
        end
    end
    return out
end

function World:fuelCost(distanceLy)
    local range = math.max(self.player.stats.jumpRange or 10, 1)
    return util.clamp(0.6 + (distanceLy / range) ^ 1.7 * 3.4, 0.4, 24)
end

--- Performs a hyperspace jump.  Returns ok, message.
function World:jump(stub)
    if not stub then return false, "no destination" end
    local dist = 0
    if self.stub then
        local dx, dy, dz = stub.x - self.stub.x, stub.y - self.stub.y, stub.z - self.stub.z
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local range = self.player.stats.jumpRange or 10
    if dist > range + 1e-6 then
        return false, string.format("out of range (%.1f > %.1f ly)", dist, range)
    end
    local cost = self:fuelCost(dist)
    if cost > self.player.fuel then
        return false, string.format("not enough fuel (%.1f needed)", cost)
    end

    self.player.fuel = self.player.fuel - cost
    self.player.record.jumps = self.player.record.jumps + 1
    self.player.record.distanceLy = self.player.record.distanceLy + dist
    -- a jump takes time, which is how the rest of the galaxy moves on
    self.day = self.day + 0.35 + dist * 0.05
    self:onNewDay(math.floor(self.day))

    self.markets = {}
    self.boards = {}
    self.rumourCache = {}
    self:enterSystem(stub)
    self.player:addLog(string.format("Jumped %.1f ly to %s.", dist, stub.name), self.day, "nav")

    -- a course that has arrived is not a course any more
    local course = self.player.course
    if course and course.destId == stub.id then
        self.player.course = nil
    end
    return true, string.format("Arrived at %s", stub.name)
end

-- ---------------------------------------------------------------------------
-- Docking
-- ---------------------------------------------------------------------------

--- Called when the player lands or docks anywhere.
function World:onDock(port)
    self.player.dockedAt = port.name
    local rec = self.player.record
    rec.dockings = (rec.dockings or 0) + 1
    local completed = missionsMod.checkArrival(self.player, self.stub.id, port, self.day)
    for _, m in ipairs(completed) do
        local title = missionsMod.title(m)
        self:addNews(i18n.format("Contract complete: {title} (+{cash} cr)",
            { title = title, cash = util.money(m.reward) }), "good")
        self.player:addLog(i18n.format("Completed {title} for {cash} cr.",
            { title = title, cash = util.money(m.reward) }), self.day, "good")
    end
    -- docking fees and a little time
    self.day = self.day + 0.08

    local caught, fine = self:customsScan(port)
    return completed, caught, fine
end

--- Customs inspection on docking.
--
-- Smuggling had no risk side at all: `illegalRisk` and `fineRate` in the
-- config, `Player:contraband`, and the Signal Dampener's `stealth` and the
-- Concealed Hold's `smuggleSpace` were all written and read by nothing. Black
-- market runs were therefore free money, while the two expensive modules that
-- exist to mitigate the risk did nothing at all.
--
-- Returns the confiscated list and the fine, or nil when nothing was found.
function World:customsScan(port)
    local law = port.lawLevel or 0.5
    local goods, value = self.player:contraband(law)
    if #goods == 0 then return nil end

    local stats = self.player.stats or {}
    -- a concealed hold hides a fixed tonnage; only the excess is exposed
    local hidden = stats.smuggleSpace or 0
    local exposed = 0
    for _, g in ipairs(goods) do exposed = exposed + g.qty end
    exposed = math.max(0, exposed - hidden)
    if exposed <= 0 then return nil end

    -- lawful ports look harder; a signal dampener cuts the odds
    local chance = config.economy.illegalRisk * law * (1 - (stats.stealth or 0))
    local rng = Rng.new(self.seed, "customs", math.floor(self.day * 10), port.seed or 0)
    if rng:float() > chance then return nil end

    local confiscated = {}
    for _, g in ipairs(goods) do
        local take = math.min(g.qty, math.max(1, math.ceil(g.qty * exposed / math.max(g.qty, 1))))
        self.player:removeCargo(g.id, take)
        confiscated[#confiscated + 1] = { id = g.id, qty = take, name = g.name }
    end
    local fine = math.floor(value * config.economy.fineRate)
    self.player:spend(math.min(fine, self.player.credits))
    self.player:addBounty(port.factionId, math.floor(fine * 0.5))
    self.player:addLog(i18n.format("Customs seized contraband at {port}. Fine {cash} cr.",
        { port = port.name, cash = util.money(fine) }), self.day, "alert")
    return confiscated, fine
end

function World:onLaunch()
    self.player.dockedAt = nil
end

-- ---------------------------------------------------------------------------
-- Colonies
-- ---------------------------------------------------------------------------

function World:foundColony(body, lat, lon, name, specialisation)
    local ok, why = colonyMod.canFound(self.player, body, true)
    if not ok then return false, why end

    self.player:spend(config.colony.foundCost)
    for id, qty in pairs(config.colony.requiredCargo) do
        self.player:removeCargo(id, qty)
    end
    self.player:uninstall("colonykit")

    local c = colonyMod.found({
        seed = Rng.hash(self.seed, self.stub.id, body.seed, math.floor(self.day * 1000)),
        body = body,
        systemId = self.stub.id,
        latitude = lat,
        longitude = lon,
        name = name,
        factionId = "independent",
        specialisation = specialisation,
        day = self.day,
    })
    self.player.colonies[#self.player.colonies + 1] = c
    self.player.record.coloniesFounded = self.player.record.coloniesFounded + 1

    local port = colonyMod.asPort(c)
    port.body = body
    port.bodyName = body.name
    body.settlements = body.settlements or {}
    body.settlements[#body.settlements + 1] = port
    self.system.settlements[#self.system.settlements + 1] = port

    self:addNews(string.format("%s founded on %s.", c.name, body.name), "colony")
    self.player:addLog(string.format("Founded %s on %s.", c.name, body.name), self.day, "colony")
    return true, c, port
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function World:save()
    local marketData = {}
    for k, m in pairs(self.markets) do marketData[k] = m:save() end
    return {
        version = config.version,
        seed = self.seed,
        day = self.day,
        player = self.player:save(),
        diplomacy = self.diplomacy:save(),
        markets = marketData,
        news = self.news,
        visited = self.visited,
    }
end

function World:loadFrom(data)
    if not data then return false, "no data" end
    if data.seed and data.seed ~= self.seed then
        self.seed = data.seed
        self.galaxy = Galaxy.new(self.seed)
        self.diplomacy = factions.Diplomacy.new(self.seed)
    end
    self.day = data.day or 0
    self.player:load(data.player)
    self.diplomacy:load(data.diplomacy)
    self.news = data.news or {}
    self.visited = data.visited or {}

    local stub = self.player.systemId and self.galaxy:byId(self.player.systemId)
    if not stub then stub = self.galaxy:findStartSystem() end
    self:enterSystem(stub)

    if data.markets then
        for k, md in pairs(data.markets) do
            self._pendingMarkets = self._pendingMarkets or {}
            self._pendingMarkets[k] = md
        end
    end
    return true
end

--- Market state is restored lazily: the saved stock is applied the first time
--- a market is opened, so loading does not have to rebuild every port.
function World:restoreMarket(port, market)
    if not self._pendingMarkets then return end
    local key = self:portKey(port)
    local md = self._pendingMarkets[key]
    if md then
        market:load(md)
        self._pendingMarkets[key] = nil
    end
end

function World:writeSave()
    if not (love and love.filesystem) then return false, "no filesystem" end
    local ok, text = pcall(serialize.encode, self:save())
    if not ok then return false, tostring(text) end
    local written, err = love.filesystem.write(SAVE_FILE, text)
    if not written then return false, tostring(err) end
    return true
end

function World:readSave()
    if not (love and love.filesystem) then return false, "no filesystem" end
    if not love.filesystem.getInfo(SAVE_FILE) then return false, "no save file" end
    local text = love.filesystem.read(SAVE_FILE)
    local data, err = serialize.decode(text)
    if not data then return false, tostring(err) end
    return self:loadFrom(data)
end

function World:hasSave()
    return love and love.filesystem and love.filesystem.getInfo(SAVE_FILE) ~= nil
end

World.SAVE_FILE = SAVE_FILE

return World

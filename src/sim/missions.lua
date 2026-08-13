-- Mission generation and bookkeeping.
--
-- Missions are generated from the state of the galaxy rather than from a
-- table of hand written jobs: a war zone offers evacuation and arms runs, a
-- mining world wants machinery, a frontier system posts bounties.  That way
-- the board tells the player something true about where they are standing.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local config = require("src.config")
local names = require("src.procgen.names")
local commodities = require("src.sim.commodities")
local factions = require("src.sim.factions")
local i18n = require("src.i18n")

local missions = {}

local TYPES = {}

local function register(id, def)
    def.id = id
    TYPES[id] = def
    TYPES[#TYPES + 1] = def
end

-- ---------------------------------------------------------------------------
-- Mission text
--
-- A contract's title and brief are not stored as finished sentences, because
-- a save written in one language would then keep showing that language after
-- the player switches. What is stored is the template plus its arguments, and
-- the sentence is assembled at draw time.
--
-- Arguments go through `i18n.term`, so an argument that names a dictionary
-- entry ("Grain") arrives as a declinable noun and a procedural proper noun
-- ("Реен Прима") arrives as itself.
-- ---------------------------------------------------------------------------

--- Renders one of a mission's stored templates.
local function render(template, args)
    if not template then return nil end
    if not args then return i18n.translate(template) end
    local resolved = {}
    for k, v in pairs(args) do
        resolved[k] = type(v) == "string" and i18n.term(v) or v
    end
    return i18n.format(template, resolved)
end

function missions.title(m)
    -- `m.title` is the pre-rendered English kept for saves written before
    -- templates existed, and as a last resort if a template goes missing
    return render(m.titleText, m.args) or m.title or "?"
end

function missions.brief(m)
    return render(m.briefText, m.args) or m.brief or ""
end

-- ---------------------------------------------------------------------------
-- Mission types
-- ---------------------------------------------------------------------------

register("delivery", {
    name = "Delivery",
    weight = 30,
    build = function(rng, ctx)
        local dest = ctx.pickDestination(rng, 40)
        if not dest then return nil end
        local pool = {}
        for _, c in ipairs(commodities.list) do
            if c.legality == "legal" and c.category ~= "illicit" then pool[#pool + 1] = c end
        end
        local c = rng:pick(pool)
        local qty = rng:int(4, 26)
        local base = c.base * qty
        return {
            type = "delivery",
            titleText = "Deliver {qty} {qty:t} of {cargo:gen:lc} to {dest}",
            briefText = "{employer} needs {qty} {qty:t} of {cargo:gen:lc} at {dest}. " ..
                "Cargo is supplied on acceptance; you carry it there.",
            args = { qty = qty, cargo = c.name, dest = dest.name, employer = ctx.employer },
            commodity = c.id, quantity = qty,
            destSystemId = dest.id, destName = dest.name,
            reward = math.floor(base * rng:range(0.35, 0.6) + dest.distance * 55 + 900),
            days = math.ceil(dest.distance / 9) + rng:int(4, 10),
            cargoOnAccept = true,
            repGain = 0.035,
        }
    end,
})

register("supply", {
    name = "Supply Contract",
    weight = 22,
    build = function(rng, ctx)
        -- the port wants something it is short of; the player sources it
        local wanted = ctx.shortages(rng)
        if not wanted then return nil end
        local c = commodities.get(wanted)
        local qty = rng:int(6, 30)
        return {
            type = "supply",
            titleText = "Supply {qty} {qty:t} of {cargo:gen:lc}",
            briefText = "{port} is short of {cargo:gen:lc}. Bring {qty} {qty:t} back here " ..
                "and they pay well over the market.",
            args = { qty = qty, cargo = c.name, port = ctx.portName },
            commodity = c.id, quantity = qty,
            destSystemId = ctx.systemId, destName = ctx.portName,
            reward = math.floor(c.base * qty * rng:range(1.25, 1.75)),
            days = rng:int(8, 22),
            deliverHere = true,
            repGain = 0.04,
        }
    end,
})

register("bounty", {
    name = "Bounty",
    weight = 24,
    build = function(rng, ctx)
        local target = ctx.pickDestination(rng, 30) or ctx.here
        local count = rng:int(2, 6)
        local pirate = rng:bool(0.7)
        local enemy = pirate and "pirates" or (ctx.warEnemy or "pirates")
        return {
            type = "bounty",
            titleText = "Destroy {count} {short} vessels",
            briefText = "{employer} is paying per hull. {count} {faction:gen} {count:ship}, " ..
                "in {dest} or anywhere you find them.",
            args = { count = count, short = factions.get(enemy).short,
                     faction = factions.get(enemy).name, dest = target.name,
                     employer = ctx.employer },
            targetFaction = enemy,
            quantity = count, progress = 0,
            destSystemId = target.id, destName = target.name,
            reward = count * rng:int(1800, 4200),
            days = rng:int(10, 26),
            repGain = 0.05,
        }
    end,
})

register("passenger", {
    name = "Passenger",
    weight = 16,
    build = function(rng, ctx)
        local dest = ctx.pickDestination(rng, 60)
        if not dest then return nil end
        local qty = rng:int(1, 8)
        local vip = rng:bool(0.25)
        local who = names.person(rng:int(1, 1e6))
        return {
            type = "passenger",
            titleText = vip and "Escort {who} to {dest}" or "{qty} passengers to {dest}",
            briefText = vip
                and "{who} must reach {dest} discreetly. They will not explain why."
                or "{qty} travellers booked passage to {dest}. Cabins are your cargo hold.",
            args = { who = who, qty = qty, dest = dest.name },
            commodity = "colonists", quantity = qty,
            destSystemId = dest.id, destName = dest.name,
            reward = math.floor((vip and 9000 or 1400) * qty * rng:range(0.8, 1.4) + dest.distance * 80),
            days = math.ceil(dest.distance / 10) + rng:int(3, 8),
            cargoOnAccept = true,
            vip = vip,
            repGain = 0.03,
        }
    end,
})

register("smuggle", {
    name = "Smuggling",
    weight = 12,
    require = function(ctx) return ctx.lawLevel < 0.55 or ctx.blackMarket end,
    build = function(rng, ctx)
        local dest = ctx.pickDestination(rng, 40)
        if not dest then return nil end
        local c = rng:pick({ commodities.get("narcotics"), commodities.get("weapons"), commodities.get("captives") })
        local qty = rng:int(3, 14)
        return {
            type = "smuggle",
            titleText = "Run {qty} {qty:t} of {cargo:gen:lc} to {dest}",
            briefText = "No manifest, no questions. {qty} {qty:t} of {cargo:gen:lc} into {dest}. " ..
                "Customs will scan you.",
            args = { qty = qty, cargo = c.name, dest = dest.name },
            commodity = c.id, quantity = qty,
            destSystemId = dest.id, destName = dest.name,
            reward = math.floor(c.base * qty * rng:range(0.9, 1.6)),
            days = rng:int(6, 16),
            cargoOnAccept = true,
            illegal = true,
            repGain = -0.02,
            repFaction = "syndicate",
        }
    end,
})

register("survey", {
    name = "Survey",
    weight = 14,
    build = function(rng, ctx)
        local dest = ctx.pickDestination(rng, 90)
        if not dest then return nil end
        return {
            type = "survey",
            titleText = "Survey {dest}",
            briefText = "Nobody has filed a current report on {dest}. Jump in, scan what is " ..
                "there, come back.",
            args = { dest = dest.name },
            destSystemId = dest.id, destName = dest.name,
            returnHere = true,
            returnSystemId = ctx.systemId,
            reward = math.floor(1200 + dest.distance * 190 * rng:range(0.8, 1.3)),
            days = math.ceil(dest.distance / 8) + rng:int(6, 16),
            repGain = 0.03,
        }
    end,
})

register("colonysupply", {
    name = "Colony Support",
    weight = 10,
    require = function(ctx) return ctx.hasColonies end,
    build = function(rng, ctx)
        local c = commodities.get(rng:pick({ "provisions", "machinery", "medicine", "colonists", "terrakit" }))
        local qty = rng:int(8, 26)
        return {
            type = "colonysupply",
            titleText = "Ship {qty} {qty:t} of {cargo:gen:lc} to a colony",
            briefText = "Frontier settlements pay a premium for {cargo:acc:lc} delivered to " ..
                "their own pads, not to a station.",
            args = { qty = qty, cargo = c.name },
            commodity = c.id, quantity = qty,
            toColony = true,
            reward = math.floor(c.base * qty * rng:range(1.3, 1.9)),
            days = rng:int(10, 26),
            repGain = 0.04,
        }
    end,
})

register("assassination", {
    name = "Assassination",
    weight = 7,
    require = function(ctx) return ctx.lawLevel < 0.6 end,
    build = function(rng, ctx)
        local dest = ctx.pickDestination(rng, 40)
        if not dest then return nil end
        local who = names.person(rng:int(1, 1e6))
        return {
            type = "assassination",
            titleText = "Eliminate {who}",
            briefText = "{who} runs a courier out of {dest}. The contract does not care how.",
            args = { who = who, dest = dest.name },
            targetName = who,
            destSystemId = dest.id, destName = dest.name,
            quantity = 1, progress = 0,
            reward = rng:int(14000, 46000),
            days = rng:int(8, 20),
            illegal = true,
            repGain = -0.05,
        }
    end,
})

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

--- Builds the mission board for a port.
-- `galaxy` and `diplomacy` are used to find real destinations and real wars.
function missions.generate(port, sys, galaxy, diplomacy, day, count)
    local rng = Rng.new(port.seed, "missions", math.floor(day / 3))
    local stub = sys.stub or sys

    -- candidate destinations: real systems within jump range of here
    local nearby = galaxy and galaxy:systemsNear(stub.x, stub.y, stub.z, 70) or {}
    local dests = {}
    for _, s in ipairs(nearby) do
        if s.id ~= stub.id and s.population > 0 then dests[#dests + 1] = s end
    end

    local warEnemy
    if diplomacy then
        for _, w in ipairs(diplomacy:activeWars()) do
            if w.a == sys.factionId then warEnemy = w.b break end
            if w.b == sys.factionId then warEnemy = w.a break end
        end
    end

    local ctx = {
        systemId = stub.id,
        portName = port.name,
        employer = names.company(Rng.hash(port.seed, day)),
        lawLevel = port.lawLevel or sys.lawLevel or 0.5,
        blackMarket = port.blackMarket,
        warEnemy = warEnemy,
        hasColonies = (port.hasColonies == true),
        here = { id = stub.id, name = stub.name, distance = 0 },
        pickDestination = function(r, maxLy)
            local pool = {}
            for _, s in ipairs(dests) do
                if (s.distance or 0) <= maxLy then pool[#pool + 1] = s end
            end
            if #pool == 0 then return nil end
            return pool[r:int(1, #pool)]
        end,
        shortages = function(r)
            if not port.market then return commodities.list[r:int(1, #commodities.list)].id end
            local worst, worstRatio = nil, 0
            for _, id in ipairs(port.market:tradedIds()) do
                local eq = port.market.equilibrium[id]
                local st = port.market:available(id)
                local ratio = (eq - st) / math.max(eq, 1)
                if ratio > worstRatio then worst, worstRatio = id, ratio end
            end
            return worst
        end,
    }

    local board = {}
    local attempts = 0
    count = count or rng:int(4, 9)
    while #board < count and attempts < count * 6 do
        attempts = attempts + 1
        -- weighted pick over eligible types
        local pool = {}
        local total = 0
        for i = 1, #TYPES do
            local t = TYPES[i]
            if not t.require or t.require(ctx) then
                pool[#pool + 1] = t
                total = total + t.weight
            end
        end
        if total <= 0 then break end
        local r = rng:float() * total
        local chosen = pool[#pool]
        for _, t in ipairs(pool) do
            r = r - t.weight
            if r <= 0 then chosen = t break end
        end

        local m = chosen.build(rng, ctx)
        if m then
            m.id = string.format("%s-%d-%d", stub.id, math.floor(day), #board + 1)
            m.issuedDay = day
            m.expires = day + (m.days or 10)
            m.employer = ctx.employer
            m.originSystemId = stub.id
            m.originPort = port.name
            m.factionId = port.factionId or sys.factionId
            m.state = "offered"
            -- war zones pay more and are honest about why
            if sys.conflict and sys.conflict > 0.2 then
                m.reward = math.floor(m.reward * (1 + sys.conflict * 0.7))
                m.warZone = true
            end
            board[#board + 1] = m
        end
    end
    return board
end

-- ---------------------------------------------------------------------------
-- Runtime
-- ---------------------------------------------------------------------------

--- Can the player take this on right now?
function missions.canAccept(m, player)
    if #player.missions >= 8 then return false, "mission log is full" end
    if m.cargoOnAccept then
        local need = m.quantity * (commodities.byId[m.commodity] and commodities.byId[m.commodity].volume or 1)
        if player:cargoFree() < need then
            return false, string.format("need %d t of free hold", need)
        end
    end
    return true
end

function missions.accept(m, player, day)
    local ok, why = missions.canAccept(m, player)
    if not ok then return false, why end
    m.state = "active"
    m.acceptedDay = day
    if m.cargoOnAccept then
        player:addCargo(m.commodity, m.quantity)
        m.cargoLoaded = true
    end
    player.missions[#player.missions + 1] = m
    return true
end

--- Called on docking: completes anything that is finished here.
-- Returns a list of {mission, reward} for the UI to report.
function missions.checkArrival(player, systemId, port, day)
    local completed = {}
    for i = #player.missions, 1, -1 do
        local m = player.missions[i]
        local done = false
        if m.state == "active" then
            if m.type == "delivery" or m.type == "passenger" or m.type == "smuggle" then
                if m.destSystemId == systemId then
                    local removed = player:removeCargo(m.commodity, m.quantity)
                    if removed >= m.quantity then done = true end
                end
            elseif m.type == "supply" then
                if m.destSystemId == systemId and (port == nil or port.name == m.originPort) then
                    if player:cargoCount(m.commodity) >= m.quantity then
                        player:removeCargo(m.commodity, m.quantity)
                        done = true
                    end
                end
            elseif m.type == "survey" then
                if m.surveyed and m.returnSystemId == systemId then done = true end
            elseif m.type == "bounty" or m.type == "assassination" then
                if (m.progress or 0) >= m.quantity then done = true end
            elseif m.type == "colonysupply" then
                if port and port.player and player:cargoCount(m.commodity) >= m.quantity then
                    player:removeCargo(m.commodity, m.quantity)
                    done = true
                end
            end
        end
        if done then
            m.state = "complete"
            player:earn(m.reward)
            player.record.missionsDone = player.record.missionsDone + 1
            if m.repGain then
                player:addReputation(m.repFaction or m.factionId, m.repGain)
            end
            table.remove(player.missions, i)
            completed[#completed + 1] = m
        end
    end
    return completed
end

--- Marks progress on kill-type missions.
function missions.recordKill(player, factionId, targetName)
    local touched = {}
    for _, m in ipairs(player.missions) do
        if m.state == "active" then
            if m.type == "bounty" and m.targetFaction == factionId then
                m.progress = (m.progress or 0) + 1
                touched[#touched + 1] = m
            elseif m.type == "assassination" and targetName and m.targetName == targetName then
                m.progress = 1
                touched[#touched + 1] = m
            end
        end
    end
    return touched
end

function missions.recordSurvey(player, systemId)
    local touched = {}
    for _, m in ipairs(player.missions) do
        if m.state == "active" and m.type == "survey" and m.destSystemId == systemId then
            m.surveyed = true
            touched[#touched + 1] = m
        end
    end
    return touched
end

--- Expires overdue contracts.  Returns the ones that failed.
function missions.expire(player, day)
    local failed = {}
    for i = #player.missions, 1, -1 do
        local m = player.missions[i]
        if day > m.expires then
            m.state = "failed"
            player.record.missionsFailed = player.record.missionsFailed + 1
            player:addReputation(m.factionId, -0.06)
            if m.cargoLoaded then player:removeCargo(m.commodity, m.quantity) end
            table.remove(player.missions, i)
            failed[#failed + 1] = m
        end
    end
    return failed
end

--- Short status line for the mission log UI.
function missions.status(m, day)
    local left = math.floor(math.max(0, m.expires - day))
    local remaining = i18n.format("{n} {n:day} left", { n = left })
    if m.quantity and (m.type == "bounty" or m.type == "assassination") then
        return string.format("%d/%d  -  %s", m.progress or 0, m.quantity, remaining)
    end
    if m.type == "survey" then
        local state = m.surveyed and i18n.translate("scanned, return")
            or i18n.translate("not yet scanned")
        return string.format("%s  -  %s", state, remaining)
    end
    return string.format("%s  -  %s", m.destName or "?", remaining)
end

missions.types = TYPES

return missions

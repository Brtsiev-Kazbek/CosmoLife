-- Weapons, targeting and the consequences of a kill.
--
-- Firing, missiles, shield cells, the contact list the HUD and the autopilot
-- both read, target selection, the scanner, and what happens to reputation,
-- bounties and cargo when something dies.
--
-- Targeting sits here rather than in a module of its own because everything it
-- feeds is here: the contact list exists so a target can be cycled, and a
-- target exists so it can be shot, scanned or flown to.
--
-- The flight state arrives as an explicit first argument, as in the other
-- flight modules; `states/flight.lua` keeps forwarding methods.

local vec3 = require("src.lib.vec3")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local combat = require("src.sim.combat")
local npcMod = require("src.sim.npc")
local factions = require("src.sim.factions")
local salvage = require("src.sim.salvage")
local hud = require("src.render.hud")
local settings = require("src.settings")
local i18n = require("src.i18n")
local audio = require("src.audio")

local combatState = {}

local min, max, floor = math.min, math.max, math.floor
local C = palette.colors
local L = i18n.format

function combatState.updateWeapons(f, dt)
    f.fireTimer = max(0, f.fireTimer - dt)
    if config.down("fire") and f.fireTimer <= 0 and not f.landedOn then
        local w = f.player:weapon()
        local def = w.weapon
        f.fireTimer = 1 / def.rate
        local ship = f.ship
        combat.fire(f.arena, ship, w, ship.fwd.x, ship.fwd.y, ship.fwd.z, f.muzzle)
        f.muzzle = f.muzzle + 1
        f.heat = f.heat + def.energy * 0.8
        f.game.camera:addShake(0.035)
        f.firedRecently = true
        -- a mining laser is a different job and says so; the small pitch
        -- wobble stops a burst sounding like one long tone
        audio.play(def.mining and "mining" or "laser",
            { pitch = 0.94 + (f.muzzle % 5) * 0.03 })
    end
end

--- Rebuilds the contact list used by the HUD, scanner and targeting.
function combatState.updateContacts(f)
    local sys = f.world.system
    local ship = f.ship
    local list = f.contacts
    for i = #list, 1, -1 do list[i] = nil end

    local function add(entry) list[#list + 1] = entry end

    for _, e in ipairs(f.npcs) do
        if not e.dead then
            local faction = factions.get(e.faction)
            add({
                pos = e.pos, entity = e, kind = "ship",
                label = L(e.shipDef.roleName) .. " [" .. faction.short .. "]",
                color = e.hostileToPlayer and C.uiDanger or
                        (e.faction == "pirates" and C.orange or { faction.color[1], faction.color[2], faction.color[3], 1 }),
                hostile = e.hostileToPlayer,
                marker = true,
            })
        end
    end
    for _, st in ipairs(sys.stations) do
        add({ pos = st.pos, station = st, kind = "station", label = st.name, color = C.cyan, marker = true })
    end
    for _, b in ipairs(sys.bodies) do
        if b.kind == "planet" then
            add({ pos = b.pos, body = b, kind = "body", label = b.name, color = C.uiDim, marker = true })
            for _, m in ipairs(b.moons) do
                add({ pos = m.pos, body = m, kind = "body", label = m.name, color = C.uiDim, marker = false })
            end
        end
    end
    for _, p in ipairs(f.pois) do
        add({ pos = { x = p.x, y = p.y, z = p.z }, poi = p, kind = "poi",
              label = i18n.translate(p.name), color = C.uiDim, marker = true })
    end
    for _, s in ipairs(sys.settlements) do
        add({ pos = s.pos, place = s, kind = "settlement", label = s.name,
              color = s.player and C.uiPrimary or C.amber, marker = true })
    end

    for _, c in ipairs(list) do
        c.distance = vec3.distance(c.pos, ship.pos)
    end

    -- keep the current target valid
    if f.target then
        local found = false
        for _, c in ipairs(list) do
            if (c.entity and c.entity == f.target.entity)
                or (c.station and c.station == f.target.station)
                or (c.body and c.body == f.target.body)
                or (c.place and c.place == f.target.place)
                or (c.poi and c.poi == f.target.poi) then
                f.target = c
                found = true
                break
            end
        end
        if not found then f.target = nil end
    end

    if f.target then
        local t = f.target
        if t.entity then
            t.hull = (t.entity.hull or 0) / max(t.entity.stats.maxHull, 1)
            t.shield = (t.entity.shield or 0) / max(t.entity.stats.maxShield, 1)
            t.detail = t.entity.pilot
            if not t.entity.scanned then
                t.detail2 = L("unscanned")
            elseif t.entity.bounty > 0 then
                t.detail2 = L("cargo ~{cash} cr  -  bounty {bounty}", {
                    cash = util.money(t.entity.cargoValue),
                    bounty = util.money(t.entity.bounty) })
            else
                t.detail2 = L("cargo ~{cash} cr", { cash = util.money(t.entity.cargoValue) })
            end
        elseif t.station then
            t.hull, t.shield = nil, nil
            t.detail = L("{kind} station", { kind = L(t.station.stationKindName) })
            t.detail2 = L(factions.get(t.station.factionId).name)
        elseif t.body then
            t.hull, t.shield = nil, nil
            t.detail = L(t.body.typeName or "moon")
            t.detail2 = t.body.landable and L("landable") or L("no surface")
        elseif t.place then
            t.hull, t.shield = nil, nil
            t.detail = L("settlement on {body}", { body = t.place.bodyName or "?" })
            t.detail2 = L("pop {pop}", { pop = util.money(t.place.population) })
        end
    end
end

function combatState.cycleTarget(f, hostileOnly)
    local best, bestIndex = nil, 0
    local startIndex = 0
    for i, c in ipairs(f.contacts) do
        if c == f.target then startIndex = i break end
    end
    -- Range.
    --
    -- Combat contacts stay bounded by the scanner: you cannot lock a ship you
    -- cannot see. Navigation contacts -- stations, planets, settlements,
    -- points of interest -- must not be, because the player arrives 30,000 to
    -- 150,000 km from anything and the nearest station is thousands of times
    -- further away than the old 36 km clamp allowed. With the clamp in place
    -- `T` selected nothing at all from the spawn point, so the autopilot could
    -- never engage and the market, contracts, outfitting and the colony goal
    -- behind them were all unreachable without blind guesswork.
    local n = #f.contacts
    local scanRange = config.combat.scanRange * 4
    for k = 1, n do
        local i = ((startIndex + k - 1) % n) + 1
        local c = f.contacts[i]
        local ok = c.marker
        if c.kind == "ship" then ok = ok and c.distance < scanRange end
        if hostileOnly then ok = ok and c.hostile end
        if ok then
            best, bestIndex = c, i
            break
        end
    end
    f.target = best
    if best then hud.message(L("Target: {name}", { name = best.label or "?" }), "info") end
end

--- Picks the nearest station, or failing that any dockable place, as a target.
--- Used on arrival so a new pilot has somewhere to point at.
function combatState.targetNearestPort(f)
    local best, bestD = nil, math.huge
    for _, c in ipairs(f.contacts) do
        if c.station or c.place then
            if c.distance < bestD then best, bestD = c, c.distance end
        end
    end
    if best then f.target = best end
    return best
end

-- Things that used to be keys.
--
-- Scanning and firing a shield cell were bindings the player had to remember
-- to press, and both have exactly one right moment to press them: scan when a
-- target has been held in the reticle long enough for the scanner to lock, and
-- fire a cell when the shield is about to fail. A key that is only ever
-- correct at one moment is a chore, not a decision, so the ship does it.
-- Both are settings, for anyone who wants the chore back.
function combatState.updateAutomation(f, dt)
    -- scanner lock
    if settings.get("autoScan") ~= false then
        local t = f.target
        local range = f.player.stats.scanRange or config.combat.scanRange
        local unscanned = t and ((t.entity and not t.entity.scanned) or (t.body and not t.bodyScanned))
        if t and unscanned and (t.distance or 1e12) < range
            and f.game.camera:angleTo(t.pos.x, t.pos.y, t.pos.z) < 0.12 then
            f.scanHold = (f.scanHold or 0) + dt
            if f.scanHold >= 2.0 then
                f.scanHold = 0
                if t.body then t.bodyScanned = true end
                combatState.scanTarget(f)
            end
        else
            f.scanHold = 0
        end
    end

    -- shield cells, at the last moment they are still worth anything
    if settings.get("autoShieldCell") ~= false and (f.player.shieldCells or 0) > 0 then
        local maxShield = f.player.stats.maxShield or 0
        if maxShield > 0 and f.player.shield < maxShield * 0.15 then
            combatState.useShieldCell(f)
        end
    end
end

--- How long the scanner has been holding the current target, 0..1.
function combatState.scanProgress(f)
    if not f.scanHold or f.scanHold <= 0 then return 0 end
    return util.clamp(f.scanHold / 2.0, 0, 1)
end

function combatState.scanTarget(f)
    local t = f.target
    if not t then hud.message(L("No target"), "warn") return end
    if t.distance > (f.player.stats.scanRange or config.combat.scanRange) then
        hud.message(L("Out of scanner range"), "warn")
        return
    end
    if t.entity then
        t.entity.scanned = true
        f.player.record.scanned = f.player.record.scanned + 1
        hud.message(L("{pilot} scanned - {faction}, {cash} cr cargo", {
            pilot = t.entity.pilot,
            faction = L(factions.get(t.entity.faction).name),
            cash = util.money(t.entity.cargoValue) }), "good")
    elseif t.body then
        f.world.player:addLog(L("Surveyed {name}", { name = t.body.name }), f.world.day, "nav")
        hud.message(L("{name}: {kind}, gravity {g} m/s2, atmosphere {atm} atm", {
            name = t.body.name, kind = L(t.body.typeName or "moon"),
            g = string.format("%.1f", t.body.gravity or 0),
            atm = string.format("%.2f", t.body.atmosphere or 0) }), "good")
    else
        hud.message(L("Nothing to scan"), "warn")
    end
end

--- Burns one shield cell to restore the shield.
--
-- The Shield Cell Bank granted `stats.shieldCells`, the player tracked and
-- saved the count, and nothing anywhere consumed one -- 34,000 credits for a
-- number that only ever went up.
function combatState.useShieldCell(f)
    if (f.player.shieldCells or 0) <= 0 then
        hud.message(L("No shield cells"), "warn")
        return
    end
    local maxShield = f.player.stats.maxShield or 0
    if f.player.shield >= maxShield - 0.5 then
        hud.message(L("Shield already full"), "warn")
        return
    end
    f.player.shieldCells = f.player.shieldCells - 1
    f.player.shield = min(maxShield, f.player.shield + maxShield * 0.6)
    f.ship.shield = f.player.shield
    -- the recharge dumps heat, so it is not free in a long fight
    f.heat = min(1, (f.heat or 0) + 0.18)
    audio.play("shieldCell")
    hud.message(L("Shield cell fired ({n} left)", { n = f.player.shieldCells }), "good")
end

function combatState.fireMissile(f)
    if f.player.missiles <= 0 then
        hud.message(L("No missiles"), "warn")
        return
    end
    if not (f.target and f.target.entity) then
        hud.message(L("Missiles need a ship target"), "warn")
        return
    end
    f.player.missiles = f.player.missiles - 1
    local w = { weapon = { damage = 140, rate = 1, energy = 0, speed = config.combat.missileSpeed,
                           color = { 1, 0.8, 0.4 } } }
    combat.fire(f.arena, f.ship, w, f.ship.fwd.x, f.ship.fwd.y, f.ship.fwd.z, 0)
    audio.play("missile")
    hud.message(L("Missile away ({n} left)", { n = f.player.missiles }), "info")
end

function combatState.onKill(f, victim, killer)
    -- Heard for anything close enough to matter, not only for your own kills:
    -- a hull going up two kilometres away is the loudest thing in the sky, and
    -- distance is the only thing that decides whether you hear it.
    local dx = victim.pos.x - f.ship.pos.x
    local dy = victim.pos.y - f.ship.pos.y
    local dz = victim.pos.z - f.ship.pos.z
    local range = math.sqrt(dx * dx + dy * dy + dz * dz)
    if range < 9000 then
        audio.play("explosion", {
            volume = util.clamp(1 - range / 9000, 0.08, 1),
            -- further away is duller as well as quieter, which a pitch drop
            -- stands in for well enough without a filter per source
            pitch = 1 - util.clamp(range / 9000, 0, 1) * 0.25,
        })
    end
    if killer == f.ship then
        f.player.record.kills = f.player.record.kills + 1
        local faction = victim.faction
        if faction == "pirates" then
            local bounty = victim.bounty or config.combat.bountyPerKill
            f.player:earn(bounty)
            hud.message(L("Bounty claimed: {cash} cr", { cash = util.money(bounty) }), "good")
            f.player:addReputation(f.world.system.factionId, 0.02)
        else
            -- killing a lawful ship is a crime where its owners have authority
            local fine = math.floor(1200 + (victim.stats.maxHull or 100) * 6)
            f.player:addBounty(faction, fine)
            hud.message(L("Bounty issued against you: {cash} cr", { cash = util.money(fine) }), "alert")
            npcMod.alert(f.npcs, faction, f.ship.pos, 14000)
        end
        local missionsMod = require("src.sim.missions")
        local touched = missionsMod.recordKill(f.player, faction, victim.pilot)
        for _, m in ipairs(touched) do
            hud.message(string.format("%s  (%d/%d)", missionsMod.title(m), m.progress or 0, m.quantity), "good")
        end
    end
    -- A hold does not evaporate with the ship around it. The scanner has
    -- always told the player what a target was carrying; now that number can
    -- actually be collected.
    local spilled = salvage.fromWreck(f.canisters, victim)
    if spilled > 0 and killer == f.ship then
        hud.message(L("Cargo scattered - scoop it before it drifts"), "info")
    end
    victim.dead = true
end
return combatState

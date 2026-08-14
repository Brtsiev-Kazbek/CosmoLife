-- Docking, landing, disembarking and scooping: everything the context key does.
--
-- Docking at a station, entering a settlement, stepping outside and picking up
-- loose cargo used to be four keys and four prompts. They are one key and one
-- prompt now, and the decision about which of them is on offer is not made
-- here at all -- src/sim/context.lua resolves it from a plain description of
-- the situation, so the prompt the player reads and the action the key runs
-- cannot disagree.
--
-- What this module owns is the sensing (what is within reach right now) and
-- the four consequences. The flight state comes in as an explicit argument;
-- `states/flight.lua` keeps forwarding methods.

local config = require("src.config")
local stationGen = require("src.procgen.stations")
local commodities = require("src.sim.commodities")
local salvage = require("src.sim.salvage")
local context = require("src.sim.context")
local hud = require("src.render.hud")
local i18n = require("src.i18n")

local docking = {}

local sqrt = math.sqrt
local L = i18n.format

-- The relative speed a station's traffic control will accept, in m/s. It is
-- measured against the station, not against the stars: a station orbits at
-- around 100 m/s itself, so a world-frame limit left a window about twenty
-- metres per second wide between "fast enough to catch it" and "slow enough
-- to be let in".
local DOCK_SPEED_LIMIT = 120

--- What the context key would do right now.
function docking.updatePrompt(f)
    f.relativeTo = nil
    if f.warpState == "cruise" then f.dockPrompt = nil return end
    local ship = f.ship

    local s = f._ctx or {}
    f._ctx = s
    s.station, s.stationBlocked, s.blockedReason = nil, nil, nil
    s.landedPlace, s.landed, s.canister, s.canisterName = nil, nil, nil, nil
    s.key = config.keyName("interact")

    -- orbital stations
    for _, st in ipairs(f.world.system.stations) do
        local mesh = f:stationMesh(st)
        local mx, my, mz = stationGen.mouthWorld(st, mesh)
        local dx, dy, dz = ship.pos.x - mx, ship.pos.y - my, ship.pos.z - mz
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < st.size * 0.55 then
            s.station = st
            if st.derelict then
                s.stationBlocked = true
                s.blockedReason = L("{name} is derelict - no docking control", { name = st.name })
            elseif f:relativeSpeed(st.vel) > DOCK_SPEED_LIMIT then
                s.stationBlocked = true
                s.blockedReason = L("Slow to under 120 m/s to dock")
            end
            -- Inside a station's approach the HUD reports closing speed rather
            -- than speed against the stars: next to something orbiting at
            -- 100 m/s, the world-frame number tells the player nothing about
            -- whether they are allowed to dock.
            f.relativeTo = st.vel
            break
        end
    end

    if not s.station then
        if f.landedOn then
            s.landed = true
            s.landedPlace = f.landedPlace
        else
            local can = salvage.nearest(f.canisters, ship.pos.x, ship.pos.y, ship.pos.z)
            if can then
                s.canister = can
                s.canisterName = L(commodities.get(can.id).name)
            end
        end
    end

    local action = context.resolve(s)
    if not action then f.dockPrompt = nil return end
    -- the old field names are what the HUD, the hints and the self-test read
    f.dockPrompt = {
        text = action.text,
        kind = action.kind,
        blocked = action.blocked,
        station = action.kind == "dock" and action.target or nil,
        place = action.kind == "enterSettlement" and action.target or nil,
        canister = action.kind == "scoop" and action.target or nil,
        surface = action.kind == "disembark" or nil,
    }
end

--- Runs whatever the context key is offering.
function docking.act(f)
    local p = f.dockPrompt
    if not p then return false end
    if p.blocked then
        hud.message(p.text, "warn")
        return false
    end
    if p.kind == "dock" or p.kind == "enterSettlement" then
        docking.dock(f)
    elseif p.kind == "disembark" then
        docking.disembark(f)
    elseif p.kind == "scoop" then
        docking.scoop(f, p.canister)
    else
        return false
    end
    return true
end

--- Pulls a cargo canister into the hold.
function docking.scoop(f, canister)
    if not canister then return end
    local id, tonnes = salvage.scoop(f.canisters, canister, f.player)
    if not id then
        hud.message(L("Hold is full."), "warn")
        return
    end
    hud.message(L("Scooped {n} {n:t} of {cargo:gen:lc}", {
        n = tonnes, cargo = i18n.term(commodities.get(id).name) }), "good")
    local rec = f.player.record
    rec.scooped = (rec.scooped or 0) + tonnes
end

function docking.dock(f)
    local p = f.dockPrompt
    if not p or p.blocked then return end
    local Port = require("src.states.port")
    local place = p.station or p.place
    if not place then return end
    -- Port itself files the arrival, so missions and fees are counted once
    f.player.hull = f.ship.hull
    f.player.shield = f.ship.shield
    hud.message(p.station and L("Docked at {name}", { name = place.name })
        or L("Entered {name}", { name = place.name }), "good")
    f.manager:push(Port.new(), place, { flight = f, docked = true })
end

function docking.disembark(f)
    if not f.landedOn or not f.surface then
        hud.message(L("Land first"), "warn")
        return
    end
    local rec = f.player.record
    rec.walked = (rec.walked or 0) + 1
    local OnFoot = require("src.states.onfoot")
    f.manager:push(OnFoot.new(), {
        surface = f.surface,
        flight = f,
        x = f.local_.pos.x,
        z = f.local_.pos.z + 12,
    })
end

return docking

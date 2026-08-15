-- Autopilot.
--
-- This is the answer to "getting to a planet takes forever". Manual frame
-- shift already scales speed with distance to mass, but it still asks the
-- pilot to hold a heading for a minute and to judge the deceleration. The
-- autopilot does both: it aligns the nose, engages cruise, and drops out at a
-- sensible standoff distance -- close enough to see the place, far enough not
-- to be inside it.
--
-- It refuses to fly into a surface, and any manual input cancels it, so it is
-- a convenience rather than a mode you can get trapped in.
--
-- Every function here takes the flight state as its first argument rather than
-- being a method on it: the autopilot reads a lot of that state (attitude,
-- throttle, warp, target) but owns only `f.autopilot`, and being a separate
-- module makes that boundary visible. `states/flight.lua` keeps one-line
-- methods that forward here, so callers and tests are unchanged.

local util = require("src.lib.util")
local mat4 = require("src.lib.mat4")
local config = require("src.config")
local stationGen = require("src.procgen.stations")
local hud = require("src.render.hud")
local i18n = require("src.i18n")

local autopilot = {}

local sqrt, min, max = math.sqrt, math.min, math.max
local FL = config.flight
local L = i18n.format

function autopilot.toggle(f)
    if f.autopilot then
        autopilot.cancel(f, "Autopilot disengaged")
        return
    end
    if not f.target then
        hud.message(L("Autopilot needs a target"), "warn")
        return
    end
    if f.landedOn then
        hud.message(L("Autopilot cannot fly you into the ground"), "warn")
        return
    end
    f.autopilot = { target = f.target }
    hud.message(L("Autopilot engaged"), "good")
end

function autopilot.cancel(f, message)
    if not f.autopilot then return end
    f.autopilot = nil
    f.pois = {}
    f.surfacePois = {}
    f.warpState = "off"
    f.warpSpeed = 0
    f.throttle = 0
    if message then hud.message(L(message), "info") end
end

--- Standoff distance for a contact: far enough out to see it whole.
--
-- Lives in `sim/travel.lua` now, because travel assist has to drop the player
-- at the same place the autopilot would: two answers to "how close is close
-- enough" would be two different arrivals for the same station.
local standoffFor = require("src.sim.travel").standoff

--- Sheds cruise velocity when leaving frame shift.
--
-- In cruise the velocity vector is *assigned* every frame from the nose
-- direction and the cruise speed; it is not momentum the hull ever built up.
-- Dropping out simply stopped assigning it, which left a several-hundred
-- kilometre per second vector in a Newtonian integrator that can shed 90 m/s
-- per second. The ship kept that speed for the rest of the flight. Frame
-- shift is not a rocket, so leaving it returns the hull to a speed it could
-- actually have reached on its own.
function autopilot.brakeToApproach(f)
    local vel = f.surface and f.local_.vel or f.ship.vel
    local topSpeed = (f.player.stats.topSpeed or FL.maxSpeed)
    local speed = vel:length()
    if speed > topSpeed then
        vel:scale(topSpeed / speed)
    end
end

--- Points the ship at a station's docking mouth.
function autopilot.faceStationMouth(f, station)
    if f.surface then return end
    local mesh = f:stationMesh(station)
    local mx, my, mz = stationGen.mouthWorld(station, mesh)
    local ship = f.ship
    local dx, dy, dz = mx - ship.pos.x, my - ship.pos.y, mz - ship.pos.z
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then return end
    ship.fwd:set(dx / len, dy / len, dz / len)
    mat4.orthonormalize(ship.right, ship.up, ship.fwd)
end

function autopilot.update(f, dt)
    local ap = f.autopilot
    if not ap then return end

    -- the target may have gone (destroyed, out of the contact list)
    local t = f.target
    if not t then autopilot.cancel(f, "Autopilot disengaged") return end

    local ship = f.ship
    local standoff = standoffFor(t)
    local tx, ty, tz = t.pos.x, t.pos.y, t.pos.z

    -- Aim at the docking corridor, not the hull.
    --
    -- Docking needs the ship within `size * 0.55` of the *mouth*, which is a
    -- specific point on one face. Flying to the station's centre left the
    -- player parked two kilometres off whichever side they happened to
    -- approach from, with the mouth possibly round the back and nothing
    -- saying where -- "it doesn't dock". The approach point is now on the
    -- mouth's own axis, so the last stretch is a straight run down it.
    if t.station then
        local mesh = f:stationMesh(t.station)
        local mx, my, mz, nx, ny, nz = stationGen.mouthWorld(t.station, mesh)
        tx, ty, tz = mx + nx * standoff, my + ny * standoff, mz + nz * standoff
        ap.corridor = true
    else
        ap.corridor = false
    end

    -- Everything below is in the target's frame, not the world's.
    --
    -- Stations orbit at around 100 m/s. Flying to a world-space point left the
    -- ship arriving at 105 m/s next to a station doing 96 m/s in the same
    -- direction -- a nine metre per second stern chase that never closes, and
    -- the real reason docking felt impossible. What has to be planned is the
    -- *closing* speed, and what arrival has to leave behind is a ship keeping
    -- station rather than one merely slow against the stars.
    local tvx, tvy, tvz = 0, 0, 0
    if t.station and t.station.vel then
        -- stations publish their own orbital velocity; use it rather than
        -- differencing a position that also moves with the aim-point offset
        tvx, tvy, tvz = t.station.vel[1], t.station.vel[2], t.station.vel[3]
        ap.targetVel = ap.targetVel or { 0, 0, 0 }
        ap.targetVel[1], ap.targetVel[2], ap.targetVel[3] = tvx, tvy, tvz
        ap.lastTx, ap.lastTy, ap.lastTz = tx, ty, tz
    elseif ap.lastTx then
        local idt = dt > 1e-6 and (1 / dt) or 0
        tvx = (tx - ap.lastTx) * idt
        tvy = (ty - ap.lastTy) * idt
        tvz = (tz - ap.lastTz) * idt
    end
    if not (t.station and t.station.vel) then
        ap.lastTx, ap.lastTy, ap.lastTz = tx, ty, tz
        ap.targetVel = ap.targetVel or { 0, 0, 0 }
        -- smooth it: a one-frame difference of an orbiting body is noisy
        local k = util.clamp(dt * 6, 0, 1)
        ap.targetVel[1] = ap.targetVel[1] + (tvx - ap.targetVel[1]) * k
        ap.targetVel[2] = ap.targetVel[2] + (tvy - ap.targetVel[2]) * k
        ap.targetVel[3] = ap.targetVel[3] + (tvz - ap.targetVel[3]) * k
    end

    local dx, dy, dz = tx - ship.pos.x, ty - ship.pos.y, tz - ship.pos.z
    local dist = sqrt(dx * dx + dy * dy + dz * dz)
    -- the aim point is already offset by the standoff, so arriving *at* it is
    -- the goal rather than stopping short of it
    if ap.corridor then standoff = max(t.station.size * 0.35, 250) end

    -- Arrival is a swept test, not a point test.
    --
    -- At cruise the ship can cover ten kilometres in a frame while a station's
    -- standoff sphere is two across: testing `dist <= standoff` once per frame
    -- meant the ship stepped straight over the sphere without ever registering
    -- arrival, then turned around and did it again from the other side. That
    -- is the "flies past and never docks" behaviour. Comparing against the
    -- previous distance catches a crossing however fast it happened.
    local closing = (ap.lastDist or dist) - dist
    if dist <= standoff or (ap.lastDist and ap.lastDist > standoff and dist > ap.lastDist
        and closing < 0 and ap.wasClose) then
        autopilot.cancel(f)
        autopilot.brakeToApproach(f)
        -- match the target's motion, so the player is alongside it rather than
        -- watching it slide away
        if not f.surface then
            ship.vel:set(ap.targetVel[1], ap.targetVel[2], ap.targetVel[3])
        end
        -- leave the nose pointed down the corridor, so the mouth is in front
        -- of the player rather than somewhere behind them
        if t.station then autopilot.faceStationMouth(f, t.station) end
        hud.message(L("Autopilot: arrived"), "good")
        return
    end
    ap.wasClose = ap.wasClose or dist < standoff * 6
    ap.lastDist = dist

    -- align the nose with the target
    local basis = f.surface and f.local_ or ship
    local ax, ay, az = dx / dist, dy / dist, dz / dist
    if f.surface then
        ax, ay, az = f.surface:dirToLocal(ax, ay, az)
    end
    local dot = ax * basis.fwd.x + ay * basis.fwd.y + az * basis.fwd.z
    -- steer: pitch and yaw towards the bearing, roll left alone
    local ex = ax * basis.right.x + ay * basis.right.y + az * basis.right.z
    local ey = ax * basis.up.x + ay * basis.up.y + az * basis.up.z
    local turn = 2.2 * dt
    basis.fwd:addScaled(basis.right, util.clamp(ex * 3, -1, 1) * turn)
    basis.fwd:addScaled(basis.up, util.clamp(ey * 3, -1, 1) * turn)
    basis.fwd:normalize()
    -- the surface frame is left-handed, so the cross product has to be told
    mat4.orthonormalize(basis.right, basis.up, basis.fwd, f:frameHanded())

    local aligned = util.clamp((dot - 0.9) / 0.1, 0, 1)
    local remaining = max(dist - standoff, 0)

    -- Speed planning.
    --
    -- The old version set the throttle from remaining distance alone and let
    -- the mass-lock ceiling decide the cruise speed. Near a station that
    -- ceiling is set by the planet the station orbits, so it was several
    -- hundred kilometres per second -- a speed the hull sheds at 90 m/s^2 and
    -- therefore needs two million kilometres to lose. The autopilot now picks
    -- the fastest speed it can still stop from, which is what a pilot does.
    local stats = f.player.stats
    local accel = FL.linearAccel * (stats.thrust or 1)
    local topSpeed = stats.topSpeed or FL.maxSpeed

    -- Braking curve with a terminal speed: solve for the speed that can still
    -- be shed to `arrivalSpeed` over the distance left. Aiming at zero meant
    -- arriving at whatever was left over; aiming at the docking gate means
    -- the ship crosses the standoff sphere already slow enough to dock.
    -- terminal *closing* speed: slow enough that the last stretch is gentle,
    -- but not so slow that a station orbiting at 100 m/s outruns the approach
    local arrivalSpeed = 45
    local subLight = sqrt(arrivalSpeed * arrivalSpeed + 2 * accel * remaining * 0.85)
    local approachSpeed = min(topSpeed * 0.9, subLight)

    local ceiling, clearance = f:warpCeiling()
    -- In cruise, velocity is set rather than accumulated, and it decays at
    -- `warpAccel` per second -- so what has to be stoppable is the *distance
    -- covered while decaying*, roughly speed / warpAccel. Keep the cruise
    -- speed under what that allows, and the drop-out is never a surprise.
    local cruiseSpeed = min(ceiling, remaining * FL.warpAccel * 0.45)
    -- Leaving cruise hands the hull back its own top speed, and that still has
    -- to be shed before the standoff sphere: stay sub-light once the room left
    -- is only just enough to brake from it.
    local brakeRoom = (topSpeed * topSpeed - arrivalSpeed * arrivalSpeed) / (2 * accel)
    local worthCruising = cruiseSpeed > topSpeed * 1.5
        and remaining > brakeRoom * 2.2
        and clearance > FL.warpMinAltitude and aligned > 0.6

    if worthCruising then
        if f.warpState == "off" then
            f.warpState = "spool"
            f.warpSpool = 0
        elseif f.warpState == "spool" then
            f.warpSpool = f.warpSpool + dt
            if f.warpSpool >= FL.warpSpoolTime then f.warpState = "cruise" end
        end
        -- throttle is the fraction of the ceiling the autopilot wants
        f.throttle = aligned * util.clamp(cruiseSpeed / max(ceiling, 1), 0.05, 1)
    else
        if f.warpState ~= "off" then
            f.warpState = "off"
            f.warpSpeed = 0
            autopilot.brakeToApproach(f)
        end
        -- sub-light: aim at the speed we can still stop from, and use reverse
        -- thrust when already going faster than that
        -- desired world velocity: the target's own motion, plus a closing
        -- component along the bearing
        local wantX = ap.targetVel[1] + (dx / dist) * approachSpeed
        local wantY = ap.targetVel[2] + (dy / dist) * approachSpeed
        local wantZ = ap.targetVel[3] + (dz / dist) * approachSpeed
        local wantAlong = wantX * basis.fwd.x + wantY * basis.fwd.y + wantZ * basis.fwd.z
        local along = ship.vel.x * basis.fwd.x + ship.vel.y * basis.fwd.y + ship.vel.z * basis.fwd.z
        if along > wantAlong + 20 then
            f.throttle = -0.4
        else
            f.throttle = aligned * util.clamp(wantAlong / max(topSpeed, 1), 0, 1)
        end
    end

    ap.distance = dist
    ap.remaining = remaining
    ap.speed = f.speed
end

autopilot.standoffFor = standoffFor

return autopilot

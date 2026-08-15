-- Scripted smoke test for the parts that need a real GPU and a real LOVE.
--
--     love . --selftest
--
-- It starts a new commander and then drives the game through every rendering
-- path in turn -- space, descent, surface, on foot, a building interior, the
-- docked screens, the galaxy map and a hyperspace jump -- drawing every frame
-- and reporting the first failure of each step.  Exit code is non-zero if any
-- step failed, so it can gate a release.

local selftest = {}

local steps = {}
local function step(atFrame, name, fn)
    steps[#steps + 1] = { frame = atFrame, name = name, fn = fn }
end

local results = {}
local function record(name, ok, err)
    results[#results + 1] = { name = name, ok = ok, err = err }
    io.write(ok and "  ok    " or "  FAIL  ", name, ok and "" or ("   " .. tostring(err)), "\n")
    io.flush()
end

-- ---------------------------------------------------------------------------

step(2, "new commander in flight", function(game)
    game:newGame(20250811, "Selftest")
    local Flight = require("src.states.flight")
    game.manager:switch(Flight.new())
    local f = game.manager:current()
    assert(f.ship, "no ship")
    assert(game.world.system, "no system")
end)

-- Which way does the mouse turn you?
--
-- Asked of the cockpit, because mouse flight steers the ship rather than the
-- camera and is therefore a separate code path with its own chance of a sign
-- error. The test is deliberately not algebra: it puts a landmark where the
-- screen shows it on the right, moves the mouse right, and requires the
-- landmark to come *towards* the centre. Nothing about the frame's handedness,
-- the view matrix or the projection can be wrong without this failing.
step(19, "mouse flight turns the way the mouse moves", function(game)
    local f = game.manager:current()
    local camera = game.camera
    local w, h = game.renderer.width, game.renderer.height
    f:setMouseFlight(true)

    -- a landmark 2 km off to the right of where the nose points
    local s = f.ship
    local mx = s.pos.x + s.right.x * 700 + s.fwd.x * 2000
    local my = s.pos.y + s.right.y * 700 + s.fwd.y * 2000
    local mz = s.pos.z + s.right.z * 700 + s.fwd.z * 2000
    local function x() return (camera:project(mx, my, mz, w, h)) end
    local before = x()

    f:centreStick()
    f:mousemoved(0, 0, 60, 0)               -- mouse to the right
    for _ = 1, 30 do f:update(1 / 60) end
    local after = x()
    assert(before and after, "the landmark was not on screen to begin with")
    assert(after < before, string.format(
        "cockpit: mouse right turned away from the right-hand landmark (%.0f -> %.0f px)",
        before, after))

    -- and pitch: a landmark above the nose should come down towards centre
    local ux = s.pos.x + s.up.x * 700 + s.fwd.x * 2000
    local uy = s.pos.y + s.up.y * 700 + s.fwd.y * 2000
    local uz = s.pos.z + s.up.z * 700 + s.fwd.z * 2000
    local function y() local _, sy = camera:project(ux, uy, uz, w, h) return sy end
    local by = y()
    f:centreStick()
    f:mousemoved(0, 0, 0, -60)              -- mouse up
    for _ = 1, 30 do f:update(1 / 60) end
    local ay = y()
    assert(by and ay, "the high landmark was not on screen to begin with")
    assert(ay > by, string.format(
        "cockpit: mouse up turned away from the landmark above the nose (%.0f -> %.0f px)",
        by, ay))
    f:centreStick()
end)

step(20, "fly in normal space", function(game)
    local f = game.manager:current()
    f.throttle = 1
    f.ship.angular:set(0.2, 0.1, 0)
    assert(f.speed ~= nil, "no speed computed")
end)

step(40, "target and scan", function(game)
    local f = game.manager:current()
    f:cycleTarget(false)
    f:scanTarget()
end)

-- A *ship* target, so the world-space indicator and the lead ring are drawn.
--
-- The lesson from the canister crash: a draw path that only runs in one
-- situation has to be given that situation, or it is never executed by any
-- test and the player is the first to run it. The indicator only appears for a
-- contact with an `entity`, and nothing else in this run selects one.
step(57, "a ship target draws the lead ring", function(game)
    local f = game.manager:current()
    -- Put one there rather than hoping traffic obliges: the whole point is to
    -- execute the code, and "no ship was nearby today" is exactly how the
    -- canister crash stayed hidden.
    local npcMod = require("src.sim.npc")
    local p = f.ship.pos
    local e = npcMod.create({
        -- a trader, not a pirate: a hostile spawn makes the tutorial chain
        -- react and this step is about the drawing, not about the sim
        seed = 8181, systemSeed = f.world.system.seed, kind = "trader",
        faction = "independent",
        x = p.x + f.ship.fwd.x * 900, y = p.y + f.ship.fwd.y * 900, z = p.z + f.ship.fwd.z * 900,
    })
    -- moving across the line of fire, so the lead point is somewhere other
    -- than the hull and the ring has to be computed rather than short-circuited
    e.vel:set(f.ship.right.x * 180, f.ship.right.y * 180, f.ship.right.z * 180)
    f.npcs[#f.npcs + 1] = e
    f:updateContacts()

    local ship
    for _, c in ipairs(f.contacts) do
        if c.entity == e then ship = c break end
    end
    assert(ship, "the spawned ship did not appear in the contact list")
    f.target = ship
    assert(f.target.entity.vel, "a ship contact has no velocity to lead")

    -- and the lead really is off the hull, which is what makes the ring worth
    -- drawing at all
    local aimMod = require("src.sim.aim")
    local lx, ly, lz = aimMod.lead(
        e.pos.x - p.x, e.pos.y - p.y, e.pos.z - p.z,
        e.vel.x - f.ship.vel.x, e.vel.y - f.ship.vel.y, e.vel.z - f.ship.vel.z,
        f.player:weapon().weapon.speed or 2400)
    assert(lx, "no intercept on a ship crossing at 180 m/s")
    local dx, dy, dz = lx - (e.pos.x - p.x), ly - (e.pos.y - p.y), lz - (e.pos.z - p.z)
    local off = math.sqrt(dx * dx + dy * dy + dz * dz)
    io.write(string.format("    TARGET lead sits %.0f m off the hull\n", off))
    io.flush()
    assert(off > 10, string.format("the lead point is only %.1f m off the hull", off))
end)

-- A contract with a destination in this system must light it up.
--
-- The tracker could always say where to go and the flight state put the answer
-- in the HUD context, where nothing read it -- so the game knew where your
-- contract was and never showed you. This gives the player such a contract and
-- checks the marker exists; the frames after it are what draw it.
step(58, "the objective is marked in the world", function(game)
    local f = game.manager:current()
    f:updateObjective()
    f:updateObjectiveMarker()

    local m = f.objectiveMarker
    assert(m, "the current objective points at nothing: " ..
        tostring(f.objective and f.objective.id))

    -- it has to be *at* something, not merely non-nil
    local best, bestD
    for _, c in ipairs(f.contacts) do
        local d = math.sqrt((c.pos.x - m[1]) ^ 2 + (c.pos.y - m[2]) ^ 2 + (c.pos.z - m[3]) ^ 2)
        if not bestD or d < bestD then best, bestD = c, d end
    end
    io.write(string.format("    DIAG-OBJ '%s' marks %s, %.0f m off\n",
        tostring(f.objective and f.objective.id), tostring(best and best.label), bestD or -1))
    io.flush()
    assert(bestD and bestD < 1, "the marker is not on any contact")
end)

-- The frames between 57 and here drew the indicator and the ring; had either
-- thrown, the run would already be over.
step(62, "the ship target survived a drawn frame", function(game)
    local f = game.manager:current()
    assert(f.target and f.target.entity, "the ship target was lost before it was drawn")
    assert(f.objectiveMarker, "the objective marker was lost before it was drawn")
    for i = #f.npcs, 1, -1 do
        if f.npcs[i].seed == 8181 then table.remove(f.npcs, i) end
    end
    f.target = nil
    f:updateContacts()
end)

step(43, "the tutorial gives a first objective", function(game)
    -- A new commander used to be given nothing at all: no target, no prompt,
    -- no goal. The chain must produce a step immediately and advance as the
    -- player does the thing it asks for.
    local f = game.manager:current()
    assert(f.objectives, "flight has no objective tracker")
    local obj = f.objective
    assert(obj, "no objective was offered to a new commander")
    assert(obj.source == "tutorial", "the first objective is not from the tutorial")

    local tutorial = require("src.sim.tutorial")
    local state = game.world.player.tutorial
    assert(state, "tutorial state was not created")

    -- Earlier steps of this run already set throttle and picked a target, so
    -- the chain should have skipped those rather than replaying them -- that
    -- skipping is the behaviour being checked here.
    assert(state.index > 1, "the chain replayed a step the player had already done")

    -- satisfying the current step must advance the chain
    local step = tutorial.STEPS[state.index]
    local before = state.index
    if step.id == "autopilot" then
        f:targetNearestPort()
        f:toggleAutopilot()
        f:updateObjective()
        f:toggleAutopilot()          -- leave it off for the next step
    elseif step.id == "look" then
        f.throttle = 1
    elseif step.id == "target" then
        f:targetNearestPort()
    end
    f:updateObjective()
    assert(state.index > before,
        "the chain did not advance after doing what step '" .. step.id .. "' asked")
end)

step(44, "a new arrival can reach a port", function(game)
    -- The whole opening of the game depends on this: from the spawn point the
    -- player must be able to select a station and hand it to the autopilot.
    -- With the old 36 km target clamp neither was possible, and the market,
    -- contracts and outfitting behind them were unreachable.
    local f = game.manager:current()
    local port = f:targetNearestPort()
    assert(port, "nothing dockable is selectable from the arrival point")
    assert(port.distance > 36000,
        "test is not exercising the clamp: port is only " .. math.floor(port.distance) .. " m away")
    local ok = f:toggleAutopilot()
    assert(f.autopilot, "autopilot refused a target at " .. math.floor(port.distance) .. " m")
    f:toggleAutopilot()
end)

step(45, "one tap on cruise flies you to the target", function(game)
    -- Travel assist, end to end, through the keys a player presses: select,
    -- tap cruise, hands off. Cruise used to be a *held* key with the throttle
    -- judged by hand, so this whole path is new and nothing else covers it.
    local f = game.manager:current()
    local input = require("src.input")
    local port = f:targetNearestPort()
    assert(port, "nothing to fly to")
    local startDist = port.distance
    assert(f.autopilot == nil, "the autopilot is running; this tests the assist")

    -- point the nose at it by hand, the way a player would
    local mat4 = require("src.lib.mat4")
    local function aim()
        local t = f.target
        local dx = t.pos.x - f.ship.pos.x
        local dy = t.pos.y - f.ship.pos.y
        local dz = t.pos.z - f.ship.pos.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        f.ship.fwd:set(dx / d, dy / d, dz / d)
        mat4.orthonormalize(f.ship.right, f.ship.up, f.ship.fwd)
    end
    -- Everything after this step is a scripted sequence that starts from the
    -- arrival point, so this one has to hand the world back exactly as it
    -- found it: flying 57 km early left the autopilot step docking from the
    -- far side of the station and thirty-seven later steps failed with it.
    local function snapshot()
        local sh = f.ship
        return {
            pos = { sh.pos.x, sh.pos.y, sh.pos.z },
            vel = { sh.vel.x, sh.vel.y, sh.vel.z },
            fwd = { sh.fwd.x, sh.fwd.y, sh.fwd.z },
            up = { sh.up.x, sh.up.y, sh.up.z },
            right = { sh.right.x, sh.right.y, sh.right.z },
            throttle = f.throttle, warpState = f.warpState, warpSpeed = f.warpSpeed,
        }
    end
    local function restore(sn)
        local sh = f.ship
        sh.pos:set(sn.pos[1], sn.pos[2], sn.pos[3])
        sh.vel:set(sn.vel[1], sn.vel[2], sn.vel[3])
        sh.fwd:set(sn.fwd[1], sn.fwd[2], sn.fwd[3])
        sh.up:set(sn.up[1], sn.up[2], sn.up[3])
        sh.right:set(sn.right[1], sn.right[2], sn.right[3])
        f.throttle, f.warpState, f.warpSpeed = sn.throttle, sn.warpState, sn.warpSpeed
        f.warpWanted, f.travelEta = false, nil
    end
    local saved = snapshot()

    aim()
    f.throttle = 1
    f:keypressed(input.keyName("warp"):lower())
    assert(f.warpWanted, "tapping cruise did not latch it on")

    local sawCruise, sawEta, arrived = false, false, false
    for _ = 1, 5000 do
        aim()
        game:update(1 / 60)
        if f.warpState == "cruise" then sawCruise = true end
        if f.travelEta then sawEta = true end
        if sawCruise and f.warpState == "off" then arrived = true break end
    end
    assert(sawCruise, "the drive never reached cruise from a single tap")
    assert(sawEta, "no time-to-arrival was ever computed")
    assert(arrived, "the assist never dropped out")

    local t = f:targetNearestPort()
    local standoff = require("src.sim.travel").standoff(t)
    assert(t.distance < standoff * 2.5, string.format(
        "dropped out %.0f m from a %.0f m standoff (started %.0f m out)",
        t.distance, standoff, startDist))
    local rel = f:relativeSpeed(t.station and t.station.vel)
    assert(rel < 900, string.format("arrived doing %.0f m/s relative to the station", rel))
    io.write(string.format("    DIAG-ASSIST start=%.0f m  dropped at %.0f m, %.0f m/s relative\n",
        startDist, t.distance, rel))
    io.flush()
    restore(saved)
    f:targetNearestPort()
end)

step(46, "autopilot arrives without overshooting", function(game)
    -- The failure this guards against: at cruise the ship covered ~10 km per
    -- frame while a station's standoff sphere is ~2 km across, so it stepped
    -- over the sphere, kept the cruise velocity after dropping out, and sailed
    -- past forever. Fly the whole approach and check it converges.
    local f = game.manager:current()
    local port = f:targetNearestPort()
    assert(port, "nothing to fly to")
    local startDist = port.distance
    assert(f.autopilot == nil, "autopilot was already running")
    f:toggleAutopilot()
    assert(f.autopilot, "autopilot refused to engage")

    local closest = math.huge
    local arrived = false
    for _ = 1, 4000 do
        game:update(1 / 60)
        if not f.autopilot then arrived = true break end
        local t = f.target
        if t then closest = math.min(closest, t.distance or math.huge) end
    end

    assert(arrived, string.format(
        "autopilot never arrived: got within %.0f m of a %.0f m start", closest, startDist))

    -- What matters is the speed *relative to the station*: it orbits at about
    -- 100 m/s itself, so a low world speed next to it is a stern chase and a
    -- matched world speed is station-keeping.
    local speed = f.ship.vel:length()
    local rel = f:relativeSpeed(port.station and port.station.vel)
    assert(rel < 120, string.format(
        "arrived doing %.0f m/s relative to the station; the docking gate is 120", rel))
    io.write(string.format(
        "    DIAG-AP start=%.0f m  arrived: %.0f m/s world, %.0f m/s relative  closest=%.0f m\n",
        startDist, speed, rel, closest))
    io.flush()
    -- The point of arriving on the corridor: a player who simply flies at the
    -- mouth they can now see must reach a dock prompt. The station spins and
    -- orbits, so steer at the mouth each frame the way a pilot would.
    local stationGen = require("src.procgen.stations")
    local station = port.station
    assert(station, "the nearest port was not a station")
    local mat4 = require("src.lib.mat4")
    for _ = 1, 1800 do
        local mesh = f:stationMesh(station)
        local mx, my, mz = stationGen.mouthWorld(station, mesh)
        local dx, dy, dz = mx - f.ship.pos.x, my - f.ship.pos.y, mz - f.ship.pos.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        f.ship.fwd:set(dx / d, dy / d, dz / d)
        mat4.orthonormalize(f.ship.right, f.ship.up, f.ship.fwd)
        f.throttle = (d > 600) and 0.55 or 0
        game:update(1 / 60)
        if f.dockPrompt and not f.dockPrompt.blocked then break end
    end
    assert(f.dockPrompt, "no dock prompt after flying at the mouth from where the autopilot left us")
    assert(not f.dockPrompt.blocked,
        "reached the mouth but could not dock: " .. tostring(f.dockPrompt.text))

    -- The corridor the HUD draws in the world. Sitting at the mouth with the
    -- station targeted is exactly when it must exist, and the frames drawn
    -- after this step are what execute the drawing of it.
    local c = f.corridor
    assert(c, "no docking corridor at the mouth with the station targeted")
    assert(c.radius > 0, "the corridor has no width")
    assert(not c.tooFast, string.format(
        "the corridor says %.0f m/s is too fast, but docking was allowed", c.speed))
    local nlen = math.sqrt(c.nx * c.nx + c.ny * c.ny + c.nz * c.nz)
    assert(math.abs(nlen - 1) < 1e-3, "the corridor axis is not a unit vector: " .. nlen)
    io.write(string.format("    DIAG-CORRIDOR radius=%.0f m  closing=%.0f m/s  range=%.0f m\n",
        c.radius, c.speed, c.distance))
    io.flush()

    selftest.autopilotSpeed = speed
    selftest.autopilotClosest = closest
end)

-- A planet with air, framed from far enough away to see its limb.
--
-- The atmosphere used to be a sphere of flat translucent colour, which reads
-- as a bubble; the scattering that makes it read as air -- brighter where the
-- view grazes the limb, dark on the night side, warm at the terminator -- is
-- view dependent and so lives in the shader. That means the only way to check
-- it is to render it and look, which is what the screenshot is for.
step(52, "a planet with air is framed for the camera", function(game)
    local f = game.manager:current()
    local systemGen = require("src.procgen.system")
    local bodiesMod = require("src.render.bodies")

    local best
    for _, b in ipairs(systemGen.landables(game.world.system)) do
        if not b.giant and (b.atmosphere or 0) > 0.2 then
            if not best or (b.atmosphere or 0) > (best.atmosphere or 0) then best = b end
        end
    end
    if not best then return end
    selftest.airWorld = best

    assert(bodiesMod.atmosphere(best), "a world with air produced no atmosphere shell")
    io.write(string.format("    DIAG-AIR shell uniform=%s  clouds=%s  atm=%.2f  terrain=%s\n",
        tostring(game.renderer.shader and game.renderer.shader:hasUniform("u_shell")),
        tostring(bodiesMod.clouds(best) ~= nil), best.atmosphere or 0, tostring(best.terrain)))
    io.flush()

    -- park across the terminator: sun to one side, so both the lit limb and
    -- the night side are in frame
    local sun = game.world.system.star.pos
    local ax, ay, az = best.pos.x - sun.x, best.pos.y - sun.y, best.pos.z - sun.z
    local l = math.sqrt(ax * ax + ay * ay + az * az)
    ax, ay, az = ax / l, ay / l, az / l
    -- a perpendicular, so the camera looks along the day/night line
    local px, py, pz = -az, 0, ax
    local pl = math.sqrt(px * px + py * py + pz * pz)
    px, py, pz = px / pl, py / pl, pz / pl

    local d = best.radius * 3.6
    f.ship.pos:set(best.pos.x + px * d + ax * d * 0.35,
                   best.pos.y + py * d + best.radius * 0.5,
                   best.pos.z + pz * d + az * d * 0.35)
    f.ship.vel:set(0, 0, 0)
    f.throttle = 0
    if f.autopilot then f:toggleAutopilot() end
    f.ship.fwd:set(best.pos.x - f.ship.pos.x, best.pos.y - f.ship.pos.y, best.pos.z - f.ship.pos.z)
    f.ship.fwd:normalize()
    f.ship.up:set(0, 1, 0)
    require("src.lib.mat4").orthonormalize(f.ship.right, f.ship.up, f.ship.fwd)
    game.camera.mode = "cockpit"
    game:update(1 / 60)
end)

step(56, "back to the approach", function(game)
    game.camera.mode = "chase"
end)

step(50, "autopilot handles a distant, large target", function(game)
    -- A planet is millions of metres away with a standoff tens of kilometres
    -- wide -- a different regime from a station, and the one where the cruise
    -- speed the autopilot picks matters most.
    local f = game.manager:current()
    local body
    for _, c in ipairs(f.contacts) do
        if c.body and c.kind == "body" then body = c break end
    end
    if not body then return end
    f.target = body
    local startDist = body.distance
    f:toggleAutopilot()
    assert(f.autopilot, "autopilot refused a planet")

    local arrived = false
    for _ = 1, 6000 do
        game:update(1 / 60)
        if not f.autopilot then arrived = true break end
    end
    local speed = f.ship.vel:length()
    io.write(string.format("    DIAG-AP2 planet start=%.0f m  arrived at %.0f m/s\n",
        startDist, speed))
    io.flush()
    assert(arrived, string.format("never reached a planet %.0f m away", startDist))
    assert(speed < 2000, string.format("arrived at a planet doing %.0f m/s", speed))
end)

step(55, "fire weapons", function(game)
    local f = game.manager:current()
    local w = game.world.player:weapon()
    local combat = require("src.sim.combat")
    for i = 1, 5 do
        combat.fire(f.arena, f.ship, w, f.ship.fwd.x, f.ship.fwd.y, f.ship.fwd.z, i)
    end
    assert(f.arena.nProjectiles >= 5, "projectiles were not queued")
end)

step(70, "approach a landable world", function(game)
    local f = game.manager:current()
    local systemGen = require("src.procgen.system")
    local body
    for _, b in ipairs(systemGen.landables(game.world.system)) do
        if b.landable and not b.giant then body = b break end
    end
    assert(body, "no landable body in the start system")
    selftest.body = body
    -- drop the ship into the upper atmosphere directly above the equator
    local x, y, z = systemGen.surfacePoint(body, 0.12, 0.4, 40000)
    f.ship.pos:set(x, y, z)
    f.ship.vel:set(0, 0, 0)
    f.throttle = 0
    f.warpState = "off"
end)

step(71, "profile: atmospheric entry", function(game)
    -- Frame times through the descent, which is where the player reports the
    -- game stalling. Printed rather than asserted: the point is to see the
    -- shape of the cost, not to gate on a number that varies by machine.
    local f = game.manager:current()
    local surface = require("src.procgen.surface")

    -- time the surface streaming separately from everything else
    local Surface = getmetatable(f.surface).__index
    local realUpdate, realBuild = Surface.update, Surface._buildChunk
    local updMs, buildMs, builds = 0, 0, 0
    Surface.update = function(self, ...)
        local t = os.clock(); local r = realUpdate(self, ...); updMs = updMs + (os.clock() - t) * 1000
        return r
    end
    Surface._buildChunk = function(self, ...)
        local t = os.clock(); local r = realBuild(self, ...)
        buildMs = buildMs + (os.clock() - t) * 1000; builds = builds + 1
        return r
    end

    -- Actually descend. The complaint is about entering the atmosphere, and
    -- what makes that different from hovering is that the terrain LOD level
    -- changes: each change used to drop the entire resident set and rebuild it
    -- three chunks per frame.
    local systemGen = require("src.procgen.system")
    local body = selftest.body
    local lodChanges, lastLod = 0, f.surface and f.surface.lodLevel
    local total, n, updateMs, drawMs = 0, 0, 0, 0
    local worst, worstAlt = 0, 0
    -- The sphere's tessellation must not change during a descent. It used to
    -- switch at twelve radii, where the planet fills nine degrees of sky, and
    -- with flat shading the whole body visibly re-formed; the swap now happens
    -- far out where it is under a pixel wide, so from here to the ground it is
    -- one mesh from start to finish.
    local scene = require("src.flight.scene")
    local detailChanges, lastDetail = 0, nil
    for i = 1, 150 do
        -- walk down from 40 km to about 2 km
        local alt = 40000 * (1 - i / 165)
        local x, y, z = systemGen.surfacePoint(body, 0.12, 0.4, alt)
        f.ship.pos:set(x, y, z)
        local t0 = os.clock()
        game:update(1 / 60)
        local t1 = os.clock()
        game:draw()
        local t2 = os.clock()
        updateMs = updateMs + (t1 - t0) * 1000
        drawMs = drawMs + (t2 - t1) * 1000
        local ms = (t2 - t0) * 1000
        if ms > worst then worst, worstAlt = ms, alt end
        total, n = total + ms, n + 1
        if f.surface and f.surface.lodLevel ~= lastLod then
            lodChanges = lodChanges + 1
            lastLod = f.surface.lodLevel
        end
        local det = scene.bodyDetail(f, body,
            math.sqrt((body.pos.x - x) ^ 2 + (body.pos.y - y) ^ 2 + (body.pos.z - z) ^ 2))
        if lastDetail and det ~= lastDetail then detailChanges = detailChanges + 1 end
        lastDetail = det
    end
    io.write(string.format("    DIAG-SPHERE %d segments through the whole descent, %d changes\n",
        lastDetail or -1, detailChanges))
    assert(detailChanges == 0, string.format(
        "the planet re-tessellated %d times between 40 km and 2 km", detailChanges))
    io.write(string.format("    DIAG-DESCENT mean=%.0f ms  worst=%.0f ms at %.0f m  lodChanges=%d\n",
        total / n, worst, worstAlt, lodChanges))
    Surface.update, Surface._buildChunk = realUpdate, realBuild

    local resident = 0
    for _ in pairs(f.surface.chunkCache or {}) do resident = resident + 1 end
    io.write(string.format(
        "    DIAG-ENTRY %.0f ms/frame = update %.0f + draw %.0f   surface:update %.0f  chunkBuild %.0f (%d builds, %.1f ms each)\n",
        total / n, updateMs / n, drawMs / n, updMs / n, buildMs / n, builds / n, builds > 0 and buildMs / builds or 0))
    local st = game.renderer.stats
    io.write(string.format("    DIAG-ENTRY resident chunks=%d  lod=%d  chunkSize=%.0f  alt=%.0f\n",
        resident, f.surface.lodLevel, f.surface.chunkSize, f.altitude or -1))
    io.write(string.format("    DIAG-ENTRY draws=%d  tris=%d  culled=%s\n",
        st.draws or -1, st.triangles or -1, tostring(st.culled)))
    -- how expensive is the post pass on its own?
    local r = game.renderer
    local was = r.settings.post
    r.settings.post = false
    local t0 = os.clock(); for _ = 1, 20 do game:draw() end
    local noPost = (os.clock() - t0) * 1000 / 20
    r.settings.post = true
    t0 = os.clock(); for _ = 1, 20 do game:draw() end
    local withPost = (os.clock() - t0) * 1000 / 20
    r.settings.post = was
    io.write(string.format("    DIAG-ENTRY draw with post=%.0f ms  without=%.0f ms\n",
        withPost, noPost))

    -- how much of the draw is the full-screen sky shader?
    local sky = game.sky
    local realSky = sky.draw
    local skyMs = 0
    sky.draw = function(...) local t = os.clock(); local r = realSky(...)
        skyMs = skyMs + (os.clock() - t) * 1000; return r end
    local realNebula = r.env.nebula
    t0 = os.clock(); for _ = 1, 20 do game:draw() end
    local base = (os.clock() - t0) * 1000 / 20
    sky.draw = realSky
    -- and with the nebula branch switched off entirely
    r.env.nebula = 0
    t0 = os.clock(); for _ = 1, 20 do game:draw() end
    local noNebula = (os.clock() - t0) * 1000 / 20
    r.env.nebula = realNebula
    io.write(string.format("    DIAG-ENTRY starfield=%.0f ms  draw with nebula=%.0f  without=%.0f\n",
        skyMs / 20, base, noNebula))
    io.flush()
    io.flush()
end)

-- The plain case: level flight in surface mode, mouse right, nose right.
--
-- This is the one a player actually meets -- you cross the surface handover on
-- the way to a planet and everything after that is in the tangent frame -- and
-- nothing covered it. Step 100 below covers a hull rolled nearly onto its
-- back, step 152 covers walking; between them sat the ordinary approach, which
-- is exactly where the report came from.
step(98, "level flight in surface mode turns the way the mouse moves", function(game)
    local f = game.manager:current()
    local camera = game.camera
    local mat4 = require("src.lib.mat4")
    local settings = require("src.settings")
    local w, h = game.renderer.width, game.renderer.height
    assert(f.surface, "not in surface mode, so this proves nothing")

    local ground = f.surface:groundHeight(f.local_.pos.x, f.local_.pos.z)
    f.local_.pos.y = ground + 900
    f.local_.vel:set(0, 0, 0)
    f.gearDown = false
    f.hoverMode = false
    f:setMouseFlight(true)
    local wasMode = camera.mode
    camera.mode = "cockpit"

    -- level and pointing along the frame's north, which is as ordinary as it
    -- gets; auto-level off so nothing is fighting the input
    settings.set("autoLevel", false)
    f.autoLevel = false
    local b = f.local_
    b.fwd:set(0, 0, 1)
    b.up:set(0, 1, 0)
    mat4.orthonormalize(b.right, b.up, b.fwd, f:frameHanded())
    f:syncFromLocal()
    f:centreStick()
    for _ = 1, 30 do
        f.local_.pos.y = ground + 900
        f.local_.vel:set(0, 0, 0)
        game:update(1 / 60)
    end

    -- a landmark the screen shows on the right
    local s = f.ship
    local mx = s.pos.x + camera.right.x * 900 + s.fwd.x * 3000
    local my = s.pos.y + camera.right.y * 900 + s.fwd.y * 3000
    local mz = s.pos.z + camera.right.z * 900 + s.fwd.z * 3000
    local before = camera:project(mx, my, mz, w, h)
    assert(before and before > w / 2, "the probe landmark is not on the right of the screen")

    f:centreStick()
    f:mousemoved(0, 0, 60, 0)
    for _ = 1, 20 do
        f.local_.pos.y = ground + 900
        f.local_.vel:set(0, 0, 0)
        game:update(1 / 60)
    end
    local after = camera:project(mx, my, mz, w, h)
    assert(after, "the landmark left the screen entirely")
    io.write(string.format("    DIAG-YAW level surface: landmark %.0f -> %.0f px\n", before, after))
    io.flush()
    assert(after < before, string.format(
        "level surface flight: mouse right turned AWAY from the right-hand landmark "
        .. "(%.0f -> %.0f px) -- the controls are mirrored", before, after))

    f:centreStick()
    settings.set("autoLevel", true)
    f.autoLevel = true
    camera.mode = wasMode
end)

-- A landing approach with the hull rolled.
--
-- Near the ground the camera levels itself to the horizon while the hull does
-- not, and the controls used to turn the nose about the *hull's* axes -- so at
-- ninety degrees of roll the view and the controls disagreed by ninety
-- degrees, and past upside down the mouse worked backwards. Worse, the
-- auto-level term was `right.y`, which is zero when upright *and* when exactly
-- inverted, so a ship that arrived on its back stayed there.
--
-- The horizon lock only engages below 30 km, so this has to be run down there:
-- at cruising altitude the camera stays glued to the hull and there is no
-- disagreement to find.
step(100, "a rolled landing approach still turns the way the mouse moves", function(game)
    local f = game.manager:current()
    local camera = game.camera
    local mat4 = require("src.lib.mat4")
    local settings = require("src.settings")
    local w, h = game.renderer.width, game.renderer.height
    if not f.surface then return end

    -- drop to a few hundred metres so the horizon lock is at full strength
    local ground = f.surface:groundHeight(f.local_.pos.x, f.local_.pos.z)
    f.local_.pos.y = ground + 300
    f.local_.vel:set(0, 0, 0)
    f.gearDown = false
    f:setMouseFlight(true)
    -- Cockpit view, because in the chase view the camera orbits the hull: a
    -- nose rotation moves the camera as well as aiming it, and the landmark's
    -- screen position then says more about where the camera swung to than
    -- about which way the nose turned.
    local wasMode = camera.mode
    camera.mode = "cockpit"

    -- Roll the hull most of the way over. The local frame has +Y as up by
    -- definition, so the attitude is built directly rather than by rotating
    -- whatever the ship happened to be doing -- otherwise "rolled 150 degrees"
    -- is 150 degrees from the hull's old attitude, not from the horizon.
    local b = f.local_
    local ang = 2.8                        -- radians from level: nearly inverted
    b.fwd:set(0, 0, 1)
    b.up:set(math.sin(ang), math.cos(ang), 0)
    -- The surface frame is left-handed, so the basis has to be built the way
    -- the ship's own code builds it. Without this the test installs an
    -- attitude the game cannot hold and readRotation mirrors it on the first
    -- frame, which is a defect in the setup rather than in the assertion.
    mat4.orthonormalize(b.right, b.up, b.fwd, f:frameHanded())
    assert(math.abs((math.atan2 or math.atan)(b.right.y, b.up.y)) > 2.5,
        "the test did not manage to roll the hull past ninety degrees")

    -- Hold the roll while the camera levels, so the measurement is about the
    -- input frame and not about the ship righting itself: a rolling hull sweeps
    -- a fixed landmark across the screen far faster than yaw moves it.
    settings.set("autoLevel", false)
    f.autoLevel = false
    for _ = 1, 90 do game:update(1 / 60) end

    -- The regime that inverts the controls is the camera being more than a
    -- right angle away from the hull: below that, yawing about the hull's axis
    -- still has a positive component along screen-right and merely feels
    -- skewed rather than backwards.
    local su, cu = f.ship.up, camera.up
    local cosPhi = su.x * cu.x + su.y * cu.y + su.z * cu.z
    assert(cosPhi < 0, string.format(
        "the camera levelled only %.0f degrees away from the hull, which is not far "
        .. "enough to invert anything", math.deg(math.acos(cosPhi))))

    -- a landmark that the screen shows on the right
    local s = f.ship
    local mx = s.pos.x + camera.right.x * 700 + s.fwd.x * 2400
    local my = s.pos.y + camera.right.y * 700 + s.fwd.y * 2400
    local mz = s.pos.z + camera.right.z * 700 + s.fwd.z * 2400
    local before = camera:project(mx, my, mz, w, h)
    assert(before and before > w / 2, "the probe landmark is not on the right of the screen")

    f:centreStick()
    f:mousemoved(0, 0, 60, 0)
    for _ = 1, 20 do game:update(1 / 60) end
    local after = camera:project(mx, my, mz, w, h)
    assert(after, "the landmark left the screen entirely")
    assert(after < before, string.format(
        "rolled approach: mouse right turned away from the right-hand landmark (%.0f -> %.0f px)",
        before, after))

    -- and with levelling back on the hull must right itself rather than
    -- settling upside down, which is where `right.y` alone left it
    settings.set("autoLevel", true)
    f.autoLevel = true
    f:centreStick()
    local rolled = math.abs((math.atan2 or math.atan)(f.local_.right.y, f.local_.up.y))
    -- hold it in the air: a ship that has landed stops levelling, and this is
    -- about the approach
    for _ = 1, 600 do
        f.local_.pos.y = ground + 300
        f.local_.vel:set(0, 0, 0)
        game:update(1 / 60)
    end
    local levelled = math.abs((math.atan2 or math.atan)(f.local_.right.y, f.local_.up.y))
    assert(levelled < 0.35, string.format(
        "the hull did not level itself: %.2f rad of roll became %.2f", rolled, levelled))
    f:centreStick()
    camera.mode = wasMode
end)

step(90, "terrain streamed in", function(game)
    local f = game.manager:current()
    assert(f.surface, "no surface patch after descending to 40 km")
    local n = 0
    for _ in pairs(f.surface.chunkCache or {}) do n = n + 1 end
    assert(n > 0, "no terrain chunks were built")
    selftest.chunkCount = n
end)

step(105, "land on the surface", function(game)
    local f = game.manager:current()
    local s = f.surface
    f.gearDown = true
    local h = s:groundHeight(f.local_.pos.x, f.local_.pos.z)
    f.local_.pos.y = h + game.world.player.shipDef.length * 0.22 + 1.0
    f.local_.vel:set(0, 0, 0)
    f.local_.up:set(0, 1, 0)
    f.local_.fwd:set(0, 0, 1)
    local mat4 = require("src.lib.mat4")
    mat4.orthonormalize(f.local_.right, f.local_.up, f.local_.fwd)
    f:syncFromLocal()
end)

step(120, "touchdown registered", function(game)
    local f = game.manager:current()
    assert(f.landedOn, "the ship never registered as landed")
end)

step(124, "diagnostics: landed state", function(game)
    local f = game.manager:current()
    local s = f.surface
    local gh = s:groundHeight(f.local_.pos.x, f.local_.pos.z)
    local n = 0
    for _ in pairs(s.chunkCache or {}) do n = n + 1 end
    io.write(string.format(
        "    DIAG-L local=(%.0f,%.0f,%.0f) ground=%.0f alt(hud)=%.0f lod=%d size=%.0f chunks=%d\n",
        f.local_.pos.x, f.local_.pos.y, f.local_.pos.z, gh, f.altitude or -1,
        s.lodLevel, s.chunkSize, n))
    local fieldH = s.field:height(f.local_.pos.x, f.local_.pos.z)
    io.write(string.format("    DIAG-L fieldH=%.0f curvature=%.0f originLat=%.4f originLon=%.4f\n",
        fieldH, (f.local_.pos.x^2 + f.local_.pos.z^2) / (2 * s.radius), s.field.originLat, s.field.originLon))
    io.flush()
end)

step(130, "disembark on foot", function(game)
    local f = game.manager:current()
    f:disembark()
    local s = game.manager:current()
    assert(s.pos, "on-foot state has no position")
    selftest.onFoot = s
end)

step(150, "walk around", function(game)
    local s = game.manager:current()
    s.walker.yaw = 1.2
    s.vel:set(2, 0, 2)
    assert(s.onGround ~= nil, "ground contact not evaluated")
end)

-- Where does a landmark to the player's east actually land on the screen?
--
-- The on-foot camera has been reported inverted twice, and both times the
-- reasoning that said it was correct was algebra about handedness. This asks
-- the renderer instead: it projects three known directions and requires east
-- to be right of centre, west to be left of it, and a real mouse event to move
-- the eastern one towards the middle.
step(151, "east is on the right of the screen, and the mouse agrees", function(game)
    local s = game.manager:current()
    s.walker.yaw = 0
    s.walker.pitch = 0
    s:updateCamera(0.016)
    local camera = game.camera
    local surface = s.surface
    local w = game.renderer.width

    local function screenX(lx, lz)
        local p = surface:toWorld(s.pos.x + lx, s.pos.y + 1.7, s.pos.z + lz)
        return (camera:project(p.x, p.y, p.z, w, game.renderer.height))
    end
    local east, north, west = screenX(30, 60), screenX(0, 60), screenX(-30, 60)
    assert(east and north and west, "the probe landmarks are not on screen")
    assert(math.abs(north - w / 2) < 2, string.format(
        "facing north, north is not dead ahead (x=%.0f, centre %.0f)", north, w / 2))
    assert(east > w / 2, string.format("east renders on the LEFT of the screen (x=%.0f)", east))
    assert(west < w / 2, string.format("west renders on the RIGHT of the screen (x=%.0f)", west))

    -- and a real mouse event has to bring the eastern one towards the middle
    local before = screenX(30, 60)
    s:mousemoved(0, 0, 40, 0)                 -- mouse to the right
    s:updateCamera(0.016)
    local after = screenX(30, 60)
    assert(after < before, string.format(
        "on foot: mouse right turned away from the eastern landmark (%.0f -> %.0f px)",
        before, after))
    s:mousemoved(0, 0, -40, 0)
    s:updateCamera(0.016)
end)

step(152, "mouse right turns right on the real camera", function(game)
    local s = game.manager:current()
    local camera = game.camera

    s:updateCamera(0.016)
    -- a landmark 100 m off to the right of where we are looking
    local mark = { camera.pos.x + camera.right.x * 100,
                   camera.pos.y + camera.right.y * 100,
                   camera.pos.z + camera.right.z * 100 }
    local before = camera:angleTo(mark[1], mark[2], mark[3])

    s:mousemoved(0, 0, 40, 0)              -- mouse to the right
    s:updateCamera(0.016)
    local after = camera:angleTo(mark[1], mark[2], mark[3])
    assert(after < before, string.format(
        "mouse right turned away from the right-hand landmark (%.3f -> %.3f rad)", before, after))

    -- and the strafe key has to agree with it
    local rx, _, rz = s.walker:right()
    local sx, sz = s.walker:wishDir(1, 0)
    assert(sx * rx + sz * rz > 0.99, "the strafe key disagrees with screen right")

    -- mouse down looks down: the view direction loses height against the
    -- surface normal we are standing on
    local up = s.surface.up
    local h0 = camera.fwd.x * up.x + camera.fwd.y * up.y + camera.fwd.z * up.z
    s:mousemoved(0, 0, 0, 40)
    s:updateCamera(0.016)
    local h1 = camera.fwd.x * up.x + camera.fwd.y * up.y + camera.fwd.z * up.z
    assert(h1 < h0, "mouse down did not look down")

    s:mousemoved(0, 0, -40, -40)           -- put it back
    s:updateCamera(0.016)
end)

step(154, "walking covers ground at a playable pace", function(game)
    local s = game.manager:current()
    local config = require("src.config")
    local x0, z0 = s.pos.x, s.pos.z
    -- drive the walker directly: the selftest has no keyboard
    for _ = 1, 90 do
        s.walker:walk(1 / 60, 0, 1, true)
        s.pos.x = s.pos.x + s.vel.x / 60
        s.pos.z = s.pos.z + s.vel.z / 60
    end
    local travelled = math.sqrt((s.pos.x - x0) ^ 2 + (s.pos.z - z0) ^ 2)
    -- 1.5 s of sprinting, minus the ramp up
    assert(travelled > config.walk.runSpeed * 1.0, string.format(
        "sprinted only %.1f m in 1.5 s", travelled))
    s.pos.x, s.pos.z = x0, z0
    s.vel:set(0, 0, 0)
end)

step(157, "diagnostics: surface state", function(game)
    local s = game.manager:current()
    local surf = s.surface
    local n = 0
    for _ in pairs(surf.chunkCache or {}) do n = n + 1 end
    local gh = surf:groundHeight(s.pos.x, s.pos.z)
    io.write(string.format(
        "    DIAG lod=%d size=%.0f chunks=%d pos=(%.0f,%.0f,%.0f) ground=%.0f alt=%.1f settlements=%d draws=%d\n",
        surf.lodLevel, surf.chunkSize, n, s.pos.x, s.pos.y, s.pos.z, gh, s.pos.y - gh,
        #surf.settlements, game.renderer.stats.draws))
    io.write(string.format("    DIAG camera=(%.0f,%.0f,%.0f) fwd=(%.2f,%.2f,%.2f) up=(%.2f,%.2f,%.2f)\n",
        game.camera.pos.x, game.camera.pos.y, game.camera.pos.z,
        game.camera.fwd.x, game.camera.fwd.y, game.camera.fwd.z,
        game.camera.up.x, game.camera.up.y, game.camera.up.z))
    local origin = surf.origin
    io.write(string.format("    DIAG origin=(%.0f,%.0f,%.0f) bodyR=%.0f\n", origin.x, origin.y, origin.z, surf.radius))
    io.flush()
end)

step(165, "enter a building interior", function(game)
    local onfoot = game.manager:current()
    -- find any settlement on this patch and walk into its first door
    local surface = onfoot.surface
    local site = surface.settlements[1]
    if not site then
        record("enter a building interior", true, nil)
        selftest.skippedInterior = true
        return
    end
    local mesh = surface:ensureSettlement(site.place)
    assert(mesh, "settlement mesh was not built")
    assert(#mesh.buildings > 0, "settlement has no buildings")
    local target = mesh.interiors[1]
    if not target then
        selftest.skippedInterior = true
        return
    end
    onfoot.pos:set(site.x + target.entrance.x, onfoot.pos.y, site.z + target.entrance.z)
    onfoot.site, onfoot.siteMesh = site, mesh
    onfoot:enterBuilding(target, site)
    local room = game.manager:current()
    assert(room.room and room.room.model, "interior mesh missing")
end)

-- Interiors are drawn in world axes, which are the opposite handedness to the
-- planet surface, so they get the same question asked.
step(182, "interiors turn the same way as the surface does", function(game)
    local room = game.manager:current()
    if not room.walker then return end
    local camera = game.camera
    local w, h = game.renderer.width, game.renderer.height
    room.walker.yaw, room.walker.pitch = 0, 0
    room:updateCamera(0.016)

    -- a marker 6 m ahead and 3 m to camera-right
    local mx = camera.pos.x + camera.fwd.x * 6 + camera.right.x * 3
    local my = camera.pos.y + camera.fwd.y * 6 + camera.right.y * 3
    local mz = camera.pos.z + camera.fwd.z * 6 + camera.right.z * 3
    local function x() return (camera:project(mx, my, mz, w, h)) end
    local before = x()
    room:mousemoved(0, 0, 40, 0)
    room:updateCamera(0.016)
    local after = x()
    assert(before and after, "the interior marker was not on screen")
    assert(after < before, string.format(
        "interior: mouse right turned away from the right-hand marker (%.0f -> %.0f px)",
        before, after))

    -- and the strafe key, which was the defect in here: A and D were swapped
    local rx, _, rz = room.walker:right()
    local sx, sz = room.walker:wishDir(1, 0)
    assert(sx * rx + sz * rz > 0.99, "interior: the strafe key steps the wrong way")
    room:mousemoved(0, 0, -40, 0)
    room:updateCamera(0.016)
end)

step(185, "open a service terminal", function(game)
    local room = game.manager:current()
    -- If the landing site had no settlement the interior steps were skipped,
    -- which used to mean the port screen -- market, contracts, outfitting,
    -- shipyard -- was never drawn at all while three steps still reported ok.
    -- Dock at the system's own port instead so the screen is always exercised.
    if selftest.skippedInterior then
        local systemGen = require("src.procgen.system")
        local Port = require("src.states.port")
        local place = systemGen.ports(game.world.system)[1]
        assert(place, "system has nowhere to dock")
        game.manager:push(Port.new(), place, { docked = false })
        local port = game.manager:current()
        assert(port.menu, "port screen has no menu")
        selftest.port = port
        return
    end
    if not room.room then return end
    local t = room.room.terminals[1]
    assert(t, "interior has no terminals")
    room.pos:set(t.x, 0, t.z + 1.0)
    room:updatePrompt()
    assert(room.action and room.action.kind == "service", "terminal did not offer a service")
    room:keypressed(require("src.config").keys.interact[1])
    local port = game.manager:current()
    assert(port.menu, "port screen has no menu")
    selftest.port = port
end)

step(200, "browse every port tab", function(game)
    local port = selftest.port
    assert(port, "the port screen never opened")
    for i = 1, #port.tabs do
        port.tab = i
        port:rebuild()
        port:draw()
    end
    -- leave it on the market tab so the screenshot at 205 catches the busiest
    -- layout: a scrolling list, a detail panel and a footer
    for i, t in ipairs(port.tabs) do
        if t == "market" then port.tab = i end
    end
    port:rebuild()
end)

step(215, "buy and sell a commodity", function(game)
    local port = selftest.port
    assert(port, "the port screen never opened")
    for i, t in ipairs(port.tabs) do
        if t == "market" then port.tab = i end
    end
    port:rebuild()
    local before = game.world.player.credits
    port.quantity = 10
    port:trade(false)
    port:trade(true)
    assert(game.world.player.credits ~= before or port.status ~= nil,
        "trading did nothing and reported nothing")
end)

step(220, "the market says what is cheap and who wants it", function(game)
    local port = selftest.port
    assert(port, "the port screen never opened")
    for i, t in ipairs(port.tabs) do
        if t == "market" then port.tab = i end
    end

    -- A pilot with no colony never reaches the "your colonies are short" line,
    -- and an unexercised draw path is how the canister crash shipped. Plant a
    -- starving colony so the row really is marked and really is drawn.
    local colonyMod = require("src.sim.colony")
    local player = game.world.player
    local saved = player.colonies
    local c = colonyMod.found({ seed = 4242, body = { type = "rock", landable = true },
                                day = game.world.day })
    c.population = 4000
    c.stockpile = {}
    player.colonies = { c }

    port:rebuild()
    -- put something in the hold that this port pays over the odds for, so the
    -- "sell it here" colour is a path the test walks and not a claim
    local held
    for _, id in ipairs(port.market:tradedIds()) do
        if not held and port.assessed[id].verdict == "dear" then
            held = id
            player:addCargo(id, 2)
        end
    end
    selftest.plantedCargo = held

    port:rebuild()
    local rows = port.assessed
    assert(rows and next(rows), "the market assessed nothing")
    local marked, cheap, dear = 0, 0, 0
    for _, r in pairs(rows) do
        assert(r.ratio == nil or r.ratio > 0, "a price came out at or below zero")
        assert(r.take <= player:cargoFree(), "the hold was offered more than it holds")
        if r.wanted > 0 then marked = marked + 1 end
        if r.verdict == "cheap" then cheap = cheap + 1 end
        if r.verdict == "dear" then dear = dear + 1 end
    end
    assert(marked > 0, "a starving colony of 4000 asks for nothing this port sells")
    -- not an assertion about balance, an assertion that the column is doing
    -- work: a shelf where every row reads the same tells the player nothing
    assert(cheap + dear < #port.menu.items or #port.menu.items <= 2,
        "every single row got the same verdict")

    if held then
        local palette = require("src.render.palette")
        local lit = false
        for _, item in ipairs(port.menu.items) do
            if item.commodity == held then lit = (item.valueColor == palette.colors.uiWarn) end
        end
        assert(lit, "a cargo this port pays over the odds for is not flagged to sell")
    end

    -- park the cursor on a marked row: the side panel's new lines then run for
    -- real, and the screenshot at 221 has something in it worth looking at
    for i, item in ipairs(port.menu.items) do
        if item.commodity and rows[item.commodity].wanted > 0 then port.menu.cursor = i end
    end
    port:draw()
    -- the colony is put back in step 230, once the shot has been taken
    selftest.plantedColonies = saved
end)

step(230, "leave the port and the building", function(game)
    if selftest.plantedColonies then
        game.world.player.colonies = selftest.plantedColonies
        selftest.plantedColonies = nil
    end
    if selftest.plantedCargo then
        game.world.player:removeCargo(selftest.plantedCargo, 2)
        selftest.plantedCargo = nil
    end
    if selftest.port then
        selftest.port:launch()
    end
    -- back in the room; step outside
    local s = game.manager:current()
    if s.room then
        s.pos:set(s.room.exit.x, 0, s.room.exit.z)
        s:updatePrompt()
        s:keypressed(require("src.config").keys.interact[1])
    end
end)

step(245, "board the ship", function(game)
    local s = game.manager:current()
    if s.shipLocal then
        s.pos:set(s.shipLocal.x, s.pos.y, s.shipLocal.z)
        s:updatePrompt()
        s:keypressed(require("src.config").keys.disembark[1])
    end
    local f = game.manager:current()
    assert(f.ship, "did not return to the flight state")
end)

step(260, "open the galaxy map", function(game)
    local f = game.manager:current()
    local config = require("src.config")
    f:keypressed(config.keys.map[1])
    local map = game.manager:current()
    assert(map.systems, "galaxy map has no systems")
    assert(#map.systems > 0, "galaxy map is empty")
    selftest.map = map
end)

-- Clicking a star must select the star you clicked.
--
-- Each system is drawn lifted off the chart plane by its height above it, but
-- the hit test used the *foot* of that rail, so the target sat wherever the
-- star would have been if it had no height -- and clicking the circle itself
-- missed by exactly the length of the stalk.
step(266, "clicking a star on the chart selects that star", function(game)
    local map = selftest.map
    assert(map and map.dotOf, "the galaxy map was not open for the click test")
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    -- a system with a real height offset, otherwise the defect is invisible
    local target
    for _, sys in ipairs(map.systems) do
        local _, y = map:screenOf(sys, w, h)
        local _, dy = map:dotOf(sys, w, h)
        if math.abs(y - dy) > 12 and dy > 40 and dy < h - 40 then target = sys break end
    end
    assert(target, "no system on screen stands far enough off the plane to test with")

    local realPos = love.mouse.getPosition
    local tx, ty = map:dotOf(target, w, h)
    love.mouse.getPosition = function() return tx, ty end
    local ok, hit = pcall(map.nearestToCursor, map, w, h)
    love.mouse.getPosition = realPos
    assert(ok, "the hit test errored: " .. tostring(hit))
    assert(hit, "clicking directly on a star hit nothing")
    assert(hit.id == target.id, string.format(
        "clicking %s selected %s instead", target.name, hit.name))
end)

step(267, "the chart plots a course and marks what is owed", function(game)
    local map = selftest.map
    assert(map, "the galaxy map was not open")
    local here = game.world.stub

    -- a few jumps out -- the case the map used to answer with "OUT OF JUMP
    -- RANGE" and nothing else. Not the far edge of the chart: the chart holds
    -- 240 ly and a course across all of it is a different (slower) test.
    local far
    for _, s in ipairs(map.systems) do
        local d = math.sqrt((s.x - here.x) ^ 2 + (s.y - here.y) ^ 2 + (s.z - here.z) ^ 2)
        if d > map.jumpRange * 2.2 and d < map.jumpRange * 4
            and (not far or d > far.d) then far = { s = s, d = d } end
    end
    assert(far, "the chart holds nothing beyond two jumps to plot a course to")

    map:select(far.s)
    assert(map.route, "no course to a system " .. math.floor(far.d) .. " ly away: "
        .. tostring(map.routeReason))
    assert(map.route.jumps >= 2, "a system beyond the drive was reached in one jump")
    local prev, worst = here, 0
    for _, s in ipairs(map.route.hops) do
        worst = math.max(worst, math.sqrt((s.x - prev.x) ^ 2 + (s.y - prev.y) ^ 2 + (s.z - prev.z) ^ 2))
        prev = s
    end
    assert(worst <= map.jumpRange + 1e-6,
        string.format("a leg of %.1f ly is beyond the %.1f ly drive", worst, map.jumpRange))
    assert(map.route.hops[#map.route.hops].id == far.s.id, "the course ends somewhere else")

    -- a contract with a destination on the chart: the diamond, the label rank
    -- and the panel's list are all paths nothing else in the test walks
    -- every field the mission code touches while this sits in the list:
    -- `expire` reads expires and factionId, the panel reads title and destName
    local mission = {
        state = "active", type = "delivery", destSystemId = far.s.id, destName = far.s.name,
        title = "Deliver grain", commodity = "grain", quantity = 4, reward = 5000,
        expires = (game.world.day or 0) + 6, factionId = "independent",
        employer = "Selftest Freight", days = 6,
    }
    local player = game.world.player
    player.missions[#player.missions + 1] = mission
    map:findContracts()
    assert(map.contracts[far.s.id], "a contract destination is not marked on the chart")
    map:draw()

    -- and the key that puts the cursor on it without any panning at all
    map:select(here)
    map:cycleContract()
    assert(map.selected and map.selected.id == far.s.id,
        "C did not centre the chart on the system a contract is owed at")
    map:draw()

    -- every filter, drawn. A filter that errors on the third press is a
    -- filter nobody finds until they press it.
    local player2 = game.world.player
    local hadCargo = next(player2.cargo) ~= nil
    if not hadCargo then player2:addCargo("grain", 1) end
    map:refreshDemand()
    local wanted = 0
    for _ in pairs(map.wantsCargo) do wanted = wanted + 1 end
    assert(wanted > 0, "nowhere in 240 ly of chart buys anything in the hold")
    for _ = 1, 4 do
        map:keypressed("f")
        map:draw()
    end
    assert((map.filter or 1) == 1, "the filters did not come back round to all systems")
    if not hadCargo then player2:removeCargo("grain", 1) end

    -- left in place for the screenshot at 268; step 275 takes it back out
    selftest.plantedMission = mission
end)

step(275, "hyperspace jump", function(game)
    local map = selftest.map
    if not map then return end
    if selftest.plantedMission then
        local list = game.world.player.missions
        for i, m in ipairs(list) do
            if m == selftest.plantedMission then table.remove(list, i) break end
        end
        selftest.plantedMission = nil
        map:findContracts()
    end
    local targets = game.world:jumpTargets()
    local pick
    for _, t in ipairs(targets) do
        if t.reachable then pick = t break end
    end
    assert(pick, "nothing in jump range with a full tank")
    map.selected = pick
    local before = game.world.stub.id
    map:jump()
    assert(game.world.stub.id ~= before, "the jump did not happen")
end)

step(290, "back in flight after the jump", function(game)
    local f = game.manager:current()
    assert(f.ship, "not in the flight state after jumping")
    assert(game.world.system, "arrived without a system")
end)

step(305, "logbook and colony screens", function(game)
    local f = game.manager:current()
    local config = require("src.config")
    f:keypressed(config.keys.missions[1])
    local log = game.manager:current()
    for i = 1, 3 do
        log.tab = i
        log:draw()
    end
    log:keypressed("escape")
    f:keypressed(config.keys.colony[1])
    local col = game.manager:current()
    col:draw()
    col:keypressed("escape")
end)

step(320, "save and reload", function(game)
    local ok, err = game:saveGame()
    assert(ok, "save failed: " .. tostring(err))
    local loaded, lerr = game:loadGame()
    assert(loaded, "load failed: " .. tostring(lerr))
    local Flight = require("src.states.flight")
    game.manager:switch(Flight.new())
end)

step(335, "chase view and wireframe", function(game)
    local f = game.manager:current()
    f:keypressed(require("src.config").keys.view[1])
    game.renderer.settings.wireframe = true
    game.renderer.settings.post = false
end)

step(342, "settings screen and lighting presets", function(game)
    local SettingsState = require("src.states.settings")
    local settings = require("src.settings")
    local lighting = require("src.render.lighting")
    game.manager:push(SettingsState.new(), game.manager:current())
    local scr = game.manager:current()
    assert(scr.optionMenu and scr.bindMenu, "settings panes missing")
    -- walk both panes and draw them
    for pane = 1, 2 do
        scr.pane = pane
        for _ = 1, 12 do
            scr:keypressed("down")
            scr:draw()
        end
    end
    -- cycle every lighting preset through the live renderer
    scr.pane = 1
    for _, id in ipairs(lighting.order) do
        settings.set("lightingPreset", id)
        scr:apply()
        game:applyLighting()
        scr:draw()
    end
    -- rebind a key and put it back
    scr.pane = 2
    scr.rebinding = "boost"
    scr:keypressed("p")
    local input = require("src.input")
    assert(input.is("boost", "p"), "rebinding did not take effect")
    input.resetBindings()
    scr:keypressed("escape")
    assert(game.manager:current() ~= scr, "settings screen did not close")
end)

step(344, "the commander panel hosts every screen", function(game)
    local config = require("src.config")
    local f = game.manager:current()
    local Panel = require("src.states.panel")
    f:keypressed(config.keys.panel[1])
    local panel = game.manager:current()
    assert(panel ~= f, "the panel key opened nothing")
    assert(panel.child, "the panel has no hosted screen")
    -- cycling with the same key walks every tab, and each one draws
    local seen = {}
    for _ = 1, #Panel.TABS do
        seen[Panel.TABS[panel.tab].id] = true
        panel:draw()
        panel:keypressed(config.keys.panel[1])
    end
    for _, t in ipairs(Panel.TABS) do
        assert(seen[t.id], "the panel never showed the " .. t.id .. " tab")
    end
    -- back to the overview for this frame's screenshot, then out: leaving it
    -- open would cover the chase shot taken on the next one
    panel:select(1)
    panel:draw()
    panel:keypressed("escape")
end)

step(346, "the utility wheel replaces the keys it took over", function(game)
    local config = require("src.config")
    -- get back to flight whatever the panel left on the stack
    local Flight = require("src.states.flight")
    while #game.manager.stack > 1 and not game.manager:current():isInstanceOf(Flight) do
        game.manager:pop()
    end
    local f = game.manager:current()
    assert(f:isInstanceOf(Flight), "did not get back to flight after the panel")
    local Wheel = require("src.states.wheel")
    local gear = f.gearDown
    f:keypressed(config.keys.utility[1])
    local wheel = game.manager:current()
    assert(wheel ~= f, "the utility key opened nothing")

    -- every slot has to be able to describe itself without blowing up
    for i, slot in ipairs(Wheel.SLOTS) do
        wheel.selected = i
        assert(type(slot.state(f)) == "string", slot.id .. " has no readable state")
        wheel:draw()
    end

    -- point at the landing gear and release: hold, point, release
    wheel.selected = 1
    wheel:keyreleased(config.keys.utility[1])
    assert(game.manager:current() == f, "releasing the key did not close the wheel")
    assert(f.gearDown ~= gear, "the wheel did not run the slot it was pointing at")
    f.gearDown = gear
end)

step(348, "a wreck spills cargo that can be scooped", function(game)
    local f = game.manager:current()
    local salvage = require("src.sim.salvage")
    local before = f.player:cargoUsed()

    -- put a canister right on top of the ship and take the context action
    f.canisters = {}
    salvage.fromWreck(f.canisters, {
        seed = 4242, cargoValue = 26000, aiKind = "trader", radius = 6,
        pos = f.ship.pos, vel = f.ship.vel,
    })
    assert(#f.canisters > 0, "a loaded trader spilled nothing")
    for _, c in ipairs(f.canisters) do
        c.pos:set(f.ship.pos.x, f.ship.pos.y, f.ship.pos.z)
        c.vel:set(0, 0, 0)
    end

    f:updateDockPrompt()
    assert(f.dockPrompt and f.dockPrompt.kind == "scoop",
        "loose cargo alongside offered no scoop: " .. tostring(f.dockPrompt and f.dockPrompt.kind))
    assert(f:contextAction(), "the context key refused to scoop")
    assert(f.player:cargoUsed() > before, "scooping put nothing in the hold")

    -- Leave one in the world.
    --
    -- This step used to end with `f.canisters = {}`, and because it all
    -- happened inside one update, the list was empty again before anything was
    -- drawn. Flight:submitCanisters returns early on an empty list, so its
    -- body had never executed in 52 steps -- and it contained a call to a
    -- global `cos` that crashed the game the first time a player saw loose
    -- cargo. Anything a submit* function only does when its list is non-empty
    -- has to be given a frame in which the list is non-empty.
    f.canisters = {}
    salvage.fromWreck(f.canisters, {
        seed = 99, cargoValue = 12000, aiKind = "pirate", radius = 6,
        pos = f.ship.pos, vel = f.ship.vel,
    })
    assert(#f.canisters > 0, "nothing was left in the world to draw")
end)

step(349, "loose cargo is drawn without crashing", function(game)
    local f = game.manager:current()
    -- The draw of frame 348 ran Flight:submitCanisters with a full list; had it
    -- thrown, the selftest would already be dead. All that is left is to prove
    -- the list really survived the frame, and to clear it.
    assert(#f.canisters > 0, "the canisters vanished before a frame was drawn")
    f.canisters = {}
end)

-- The colour a generator asks for is the colour the GPU gets.
--
-- Everything in this game is untextured, so a mesh's vertex colours are the
-- entire palette: if they do not survive the trip to the shader, no amount of
-- work on biomes, lighting or tone mapping can put colour back. They did not
-- survive. `{"VertexColor","byte",4}` is a normalised byte -- LOVE 11 wants
-- 0..1 and multiplies by 255 itself -- and the builder was sending 0..255, so
-- every channel clamped to 1.0 and every surface in the game was pure white.
-- Months of "it is all grey" was that: the screen was showing the lighting
-- with no albedo under it.
--
-- One triangle, a pass-through shader, one pixel read back. This is the check
-- that would have caught it on the first frame it existed.
-- Sound reaches the driver, or says why not.
--
-- Under xvfb there is no sound device -- the log says so before the window
-- opens -- so this cannot check that anything is audible. What it can check is
-- the thing that would break silently: that building the whole catalogue into
-- SoundData and Sources does not throw, and that when there is no device the
-- runtime says so and turns itself off rather than half working.
step(347, "the sound catalogue builds or reports why it cannot", function()
    local audio = require("src.audio")
    if not audio.available then
        io.write("    AUDIO  unavailable: " .. tostring(audio.reason) .. "\n")
        io.flush()
        -- and every entry point still has to be safe
        audio.play("laser")
        audio.loop("engine", 1)
        audio.update(1 / 60)
        return
    end

    local built, failed = 0, {}
    for _, name in ipairs(audio.names()) do
        local e = audio._entry(name)
        if e and e.data then built = built + 1 else failed[#failed + 1] = name end
    end
    io.write(string.format("    AUDIO  %d of %d voices built\n", built, #audio.names()))
    io.flush()
    assert(#failed == 0, "voices that would not build: " .. table.concat(failed, ", "))
end)

step(346, "a mesh's vertex colour reaches the shader", function()
    local Builder = require("src.render.mesh")
    local want = { 0.24, 0.61, 0.93 }

    local b = Builder.new()
    b:tri(0, 0, 0, 400, 0, 0, 0, 400, 0, want)
    local model = b:build()
    assert(model and model.mesh, "the builder produced no GPU mesh")

    local canvas = love.graphics.newCanvas(32, 32)
    local shader = love.graphics.newShader(
        "vec4 effect(vec4 c, Image t, vec2 tc, vec2 sc) { return vec4(c.rgb, 1.0); }")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setShader(shader)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(model.mesh)
    love.graphics.setShader()
    love.graphics.setCanvas()

    local data = canvas:newImageData()
    local r, g, bl = data:getPixel(8, 8)
    if data.release then data:release() end
    io.write(string.format("    VCOL   asked %.2f %.2f %.2f  got %.3f %.3f %.3f\n",
        want[1], want[2], want[3], r, g, bl))
    io.flush()
    -- 1/255 of slack for the byte quantisation, no more
    for i, got in ipairs({ r, g, bl }) do
        assert(math.abs(got - want[i]) < 0.01, string.format(
            "channel %d went in as %.3f and came out as %.3f", i, want[i], got))
    end
end)

step(350, "title screen renders", function(game)
    local Menu = require("src.states.menu")
    game.manager:switch(Menu.new())
    game.renderer.settings.wireframe = false
    game.renderer.settings.post = true
end)

-- ---------------------------------------------------------------------------

-- Frames to capture to disk (LÖVE's save directory) when --shots is passed.
-- Looking at the output is the only way to check that a procedural renderer
-- actually produces the picture you intended.
-- A tour of biomes.
--
-- The whole point of the climate work is that two places on the same planet
-- should not look alike, and that is not something a number can check: it has
-- to be rendered and looked at. This finds distinct biomes on the worlds of
-- the start system, moves the patch to each in turn, and captures a frame of
-- each one from ground level.
--
-- It also asserts what it can. The biomes it visits must genuinely differ, the
-- ground must actually build under the ship at each stop, and the average
-- colour of a patch must not be the same in a rainforest as in a dune sea --
-- which is the "everything is one flat tone" complaint, expressed as a test.

local TOUR_SLOTS = 6
local TOUR_START = 366
local TOUR_STRIDE = 6

step(TOUR_START, "find contrasting biomes to photograph", function(game)
    local Flight = require("src.states.flight")
    game.manager:switch(Flight.new())
    local f = game.manager:current()
    local sysMod = require("src.procgen.system")
    local terrainMod = require("src.procgen.terrain")

    -- Sample every landable world in the system and keep one location per
    -- biome, preferring the ones that look least like each other.
    local found, order = {}, {}
    for _, body in ipairs(sysMod.landables(game.world.system)) do
        if body.landable and not body.giant then
            local field = terrainMod.field(body)
            for i = 0, 17 do
                for j = 1, 10 do
                    local lat = (j / 11 - 0.5) * math.pi * 0.9
                    local lon = i / 18 * math.pi * 2
                    local cl = math.cos(lat)
                    local h = field:heightDir(cl * math.cos(lon), math.sin(lat), cl * math.sin(lon))
                    if not field:isWater(h) then
                        local b = field.climate:at(lat, lon, h)
                        if not found[b.id] then
                            found[b.id] = { body = body, lat = lat, lon = lon, biome = b }
                            order[#order + 1] = b.id
                        end
                    end
                end
            end
        end
    end

    assert(#order >= 3, "the start system offers only " .. #order
        .. " biome(s) to photograph, which is not a tour")
    selftest.tour = {}
    for i = 1, math.min(TOUR_SLOTS, #order) do
        selftest.tour[i] = found[order[i]]
    end
    io.write("    TOUR " .. table.concat(order, ", ") .. "\n")
    io.flush()
end)

for slot = 1, TOUR_SLOTS do
    step(TOUR_START + slot * TOUR_STRIDE, "photograph biome " .. slot, function(game)
        local entry = selftest.tour and selftest.tour[slot]
        if not entry then
            -- fewer biomes than slots is a legitimate outcome for a system;
            -- the setup step already asserted there are at least three
            assert(slot > #(selftest.tour or {}), "tour slot " .. slot .. " went missing")
            return
        end
        local f = game.manager:current()
        -- `enterSurface` returns early when the body is already the one in
        -- hand, so every stop after the first would have re-photographed the
        -- first one -- which is exactly what it did until the averages came
        -- back identical to four decimal places.
        f:leaveSurface()

        -- Turn the planet until this spot is in daylight.
        --
        -- Every stop of the tour used to land on the night side, and a night
        -- photograph cannot answer "is the ground the right colour" -- it only
        -- shows the ambient term. The spot is chosen by climate, so the
        -- longitude is not free; the rotation phase is. Aim for a sun about
        -- 37 degrees up rather than straight overhead: a vertical sun flattens
        -- relief, which is the other thing these frames are for.
        local terrainMod = require("src.procgen.terrain")
        local body = entry.body
        local sys = game.world.system
        local TAU = math.pi * 2
        local best, bestErr = body.spin, math.huge
        for i = 0, 127 do
            body.spin = i / 128 * TAU
            local _, up, _, origin = terrainMod.tangentFrame(body, entry.lat, entry.lon)
            local sx = sys.star.pos.x - origin.x
            local sy = sys.star.pos.y - origin.y
            local sz = sys.star.pos.z - origin.z
            local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
            local dot = (sl > 0) and (up.x * sx + up.y * sy + up.z * sz) / sl or -1
            local err = math.abs(dot - 0.80)
            if err < bestErr then bestErr, best = err, body.spin end
        end
        body.spin = best
        -- updateOrbits recomputes spin from the phase every frame, so the
        -- phase is what has to change for the sun to stay up
        local day = sys.day or 0
        body.rotationPhase = (best - (day / (body.dayLength or 1)) * TAU) % TAU

        f:enterSurface(entry.body, entry.lat, entry.lon)
        local surf = f.surface
        assert(surf, "no surface after entering one")

        -- Put the ship on the ground looking at the horizon, then build the
        -- patch outright rather than waiting for the frame budget to trickle
        -- it in over the next few seconds.
        f.local_.pos:set(0, 0, 0)
        for _ = 1, 90 do surf:update(0, 0, 1 / 60, 0) end
        local n = 0
        for _ in pairs(surf.chunkCache or {}) do n = n + 1 end
        assert(n > 0, "no ground built at " .. entry.biome.id)

        local ground = surf:groundHeight(0, 0)
        -- well clear of the ground: the chase camera sits behind and below
        -- the hull, and at fourteen metres it ended up *under* the terrain,
        -- photographing the underside of it
        f.local_.pos:set(0, ground + 60, 0)
        f.local_.vel:set(0, 0, 0)
        f.local_.up:set(0, 1, 0)
        f.local_.fwd:set(0, 0.06, 1)
        require("src.lib.mat4").orthonormalize(f.local_.right, f.local_.up, f.local_.fwd)
        f:syncFromLocal()
        f.landedOn = entry.body
        game.camera.mode = "cockpit"
        game:update(1 / 60)
        -- `groundHeight` is measured in the tangent frame and `altitude` from
        -- the body's surface; they differ by the terrain under the frame
        -- origin, so the height is corrected against the number that actually
        -- decides whether the camera is underground.
        for _ = 1, 4 do
            local alt = f.altitude or 0
            if alt > 30 then break end
            f.local_.pos.y = f.local_.pos.y + (30 - alt) + 20
            f.local_.vel:set(0, 0, 0)
            f:syncFromLocal()
            game:update(1 / 60)
        end
        assert((f.altitude or 0) > 0, string.format(
            "the camera ended up below the ground at %s (altitude %.0f m)",
            entry.biome.id, f.altitude or 0))

        -- What is on screen has to differ between stops: a rainforest and a
        -- dune sea rendering the same average colour would mean the biome
        -- work never reached the picture.
        local field = surf.field
        local r, g, bl, count = 0, 0, 0, 0
        for i = -8, 8 do
            for j = -8, 8 do
                local x, z = i * 55, j * 55
                local h = field:height(x, z)
                if not field:isWater(h) then
                    local c = field:colorAt(x, z, h, 0.95)
                    r, g, bl, count = r + c[1], g + c[2], bl + c[3], count + 1
                end
            end
        end
        assert(count > 0, "nowhere dry to sample at " .. entry.biome.id)
        entry.average = { r / count, g / count, bl / count }

        -- How high is the sun? Without this the frame numbers are unreadable:
        -- a dark ground is a bug at noon and correct at midnight, and the tour
        -- has no other way to say which one it photographed.
        local sun = game.renderer.env.sunDir
        local up = f.upVec
        entry.sunUp = up and -(sun.x * up.x + sun.y * up.y + sun.z * up.z) or 0

        -- Ask for a frame sample. It is taken in love.draw, where the canvas
        -- actually holds the frame -- the first version of this read from a
        -- test step, that is from love.update, and returned the same averages
        -- for completely different parts of the screen because the canvas it
        -- read had not been drawn into yet.
        selftest.sampleWanted = { slot = slot }
        io.write(string.format(
            "    TOUR %-10s %-9s vertex %.2f %.2f %.2f  sun %+.2f  chunks=%d\n",
            entry.biome.id, tostring(entry.body.terrain),
            entry.average[1], entry.average[2], entry.average[3],
            entry.sunUp, n))
        io.flush()
    end)
end

step(TOUR_START + (TOUR_SLOTS + 1) * TOUR_STRIDE, "the tour actually showed variety", function(game)
    local tour = selftest.tour or {}
    local shown = {}
    for _, e in ipairs(tour) do
        if e.average then shown[#shown + 1] = e end
    end
    assert(#shown >= 3, "only " .. #shown .. " biomes were photographed")

    -- no two stops may render the same average colour
    for i = 1, #shown do
        for j = i + 1, #shown do
            local a, b = shown[i].average, shown[j].average
            local d = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3])
            assert(d > 0.02, string.format(
                "%s and %s render the same colour (difference %.4f)",
                shown[i].biome.id, shown[j].biome.id, d))
        end
    end

    -- And now the same question asked of the screen rather than the palette.
    --
    -- The two used to disagree completely: vertices at saturation 0.8 arrived
    -- as 0.20, identical for every biome, because the vertex colours were
    -- being clamped to white on their way to the GPU. A palette that differs
    -- proves nothing on its own -- this is the assertion that the difference
    -- survives all the way to the pixels.
    local measured = {}
    for _, e in ipairs(shown) do
        if e.screen and e.sat then measured[#measured + 1] = e end
    end
    assert(#measured >= 3, "only " .. #measured .. " frames were read back")

    -- The test is not "every biome must be colourful" -- an ash plain is
    -- supposed to be grey, and demanding a saturation floor of every stop is
    -- how a game ends up in poster paint, which was the other half of the
    -- complaint. What must hold is that the screen *tracks the palette*: a
    -- biome's frame may be no less saturated than its own vertex colours, give
    -- or take what the lighting does. Broken, this read 0.20 against 0.76.
    local peak = 0
    for _, e in ipairs(measured) do
        local v = e.average
        local vmax, vmin = math.max(v[1], v[2], v[3]), math.min(v[1], v[2], v[3])
        local vsat = (vmax > 0) and (vmax - vmin) / vmax or 0
        assert(e.sat >= vsat * 0.6 - 0.02, string.format(
            "%s: vertices at saturation %.2f reach the screen at %.2f "
            .. "(%.3f %.3f %.3f) -- the shading is painting over the palette",
            e.biome.id, vsat, e.sat, e.screen[1], e.screen[2], e.screen[3]))
        if e.sat > peak then peak = e.sat end
    end
    -- and a whole tour of nothing but grey is still a failure
    assert(peak >= 0.30, string.format(
        "the most colourful biome on the tour reached the screen at "
        .. "saturation %.2f: the ground is grey again", peak))
    for i = 1, #measured do
        for j = i + 1, #measured do
            local a, b = measured[i].screen, measured[j].screen
            local d = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3])
            assert(d >= 0.05, string.format(
                "%s and %s reach the screen as the same colour (difference %.4f)",
                measured[i].biome.id, measured[j].biome.id, d))
        end
    end

    -- Shadows, where the tour gave them anything to do.
    --
    -- Two separate claims, because they fail separately. First: wherever the
    -- pass ran it must have drawn geometry -- an empty map shadows nothing and
    -- looks exactly like a correct scene with nothing to cast. Second: a low
    -- sun over relief must actually darken the ground, which is the only
    -- statement that covers the lookup as well as the pass. A sun overhead
    -- legitimately casts almost nothing on open ground, so that half is only
    -- claimed when the tour visited somewhere with the sun low.
    local lowSun, maxDarken = false, 0
    for _, e in ipairs(measured) do
        local sh = e.shadow
        if sh and sh.strength > 0 then
            assert(sh.covered > 0.05, string.format(
                "%s: the shadow pass ran and left the map empty (%.0f%% covered)",
                e.biome.id, sh.covered * 100))
            if (e.sunUp or 1) < 0.5 then lowSun = true end
            maxDarken = math.max(maxDarken, e.darken or 0)
        end
    end
    if lowSun then
        assert(maxDarken > 0.01, string.format(
            "the sun was low over relief and turning shadows off changed the "
            .. "ground by %.1f%%: nothing is being shadowed", maxDarken * 100))
    end
end)

local SHOTS = {
    [30] = "01-space",
    [54] = "01c-atmosphere",
    [58] = "01b-approach",
    [95] = "02-descent",
    [125] = "03-landed",
    [158] = "04-onfoot",
    [178] = "05-interior",
    [205] = "06-port",
    [221] = "06b-market",
    [268] = "07-chart",
    [344] = "07b-panel",
    [345] = "08-chase",
    [358] = "09-title",
    [375] = "10-biome-1",
    [381] = "10-biome-2",
    [387] = "10-biome-3",
    [393] = "10-biome-4",
    [399] = "10-biome-5",
    [405] = "10-biome-6",
}

selftest.lastFrame = 420

--- Averages a strip of the rendered frame.
--
-- This has to run from `love.draw`, after `game:draw()`. The first attempt
-- called it from a test step -- that is, from `love.update` -- and read the
-- same averages to two decimal places for completely different parts of the
-- frame, because the canvas it was reading had not been drawn into yet that
-- frame. A readback that reports plausible nonsense is worse than none.
local function sampleFrame(game, y0, y1)
    local canvas = game and game.renderer and game.renderer.color
    if not canvas or not canvas.newImageData then return nil end
    local ok, data = pcall(function() return canvas:newImageData() end)
    if not ok or not data then return nil end
    local W, H = data:getWidth(), data:getHeight()
    local r, g, b, n = 0, 0, 0, 0
    for px = math.floor(W * 0.12), math.floor(W * 0.88), 8 do
        for py = math.floor(H * y0), math.floor(H * y1), 4 do
            local cr, cg, cb = data:getPixel(px, py)
            r, g, b, n = r + cr, g + cg, b + cb, n + 1
        end
    end
    if data.release then data:release() end
    if n == 0 then return nil end
    return { r / n, g / n, b / n }
end

selftest.sampleFrame = sampleFrame

--- Fraction of the shadow map that has any geometry in it, and the nearest
--- depth written.
--
-- A shadow map is invisible. If the pass never runs, or runs and writes
-- nothing, the picture is identical to a picture with no shadows -- which is
-- also what a correct picture looks like at midnight, so the screen cannot
-- tell you which one you have. This reads the map itself: any texel below 1.0
-- is something the sun can see.
local function sampleShadowMap(game)
    local r = game and game.renderer
    local canvas = r and r.shadowColor
    if not canvas or not canvas.newImageData then return nil end
    local ok, data = pcall(function() return canvas:newImageData() end)
    if not ok or not data then return nil end
    local w, h = data:getWidth(), data:getHeight()
    local hit, n, lo = 0, 0, 1
    for px = 0, w - 1, 8 do
        for py = 0, h - 1, 8 do
            local d = data:getPixel(px, py)
            if d < 0.999 then hit = hit + 1 end
            if d < lo then lo = d end
            n = n + 1
        end
    end
    if data.release then data:release() end
    if n == 0 then return nil end
    return { covered = hit / n, nearest = lo, strength = r.shadowStrength or 0 }
end

function selftest.captureIfWanted(frame)
    local want = selftest.sampleWanted
    if want then
        selftest.sampleWanted = nil
        local entry = selftest.tour and selftest.tour[want.slot]
        if entry then
            entry.screen = sampleFrame(selftest.game, 0.56, 0.66)
            entry.sky = sampleFrame(selftest.game, 0.02, 0.14)
            entry.shadow = sampleShadowMap(selftest.game)

            -- The same frame again with the shadow pass switched off.
            --
            -- A shadow map that is full of geometry still proves nothing about
            -- the picture -- the lookup can be wrong in a way that says "lit"
            -- everywhere, and the result is indistinguishable from a scene that
            -- has nothing to cast. Rendering the stop twice and differencing
            -- the ground is the only statement that means anything: if turning
            -- shadows off does not change the frame, there are no shadows.
            local r = selftest.game.renderer
            if r.settings.shadows and not r.shadowUnsupported then
                r.settings.shadows = false
                selftest.game:draw()
                entry.unshadowed = sampleFrame(selftest.game, 0.56, 0.66)
                r.settings.shadows = true
                -- leave the canvas holding the shadowed frame, which is what
                -- the screenshot is meant to show
                selftest.game:draw()
            end
            if entry.screen then
                local c = entry.screen
                local mx = math.max(c[1], c[2], c[3])
                local mn = math.min(c[1], c[2], c[3])
                entry.sat = (mx > 0) and (mx - mn) / mx or 0
                local sh = entry.shadow
                local u = entry.unshadowed
                local darken = 0
                if u then
                    local a = (c[1] + c[2] + c[3]) / 3
                    local b = (u[1] + u[2] + u[3]) / 3
                    darken = (b > 0) and (1 - a / b) or 0
                    entry.darken = darken
                end
                io.write(string.format(
                    "    SHADOW %-10s map %.0f%% covered, nearest %.4f, strength %.2f, "
                    .. "ground darkened %.1f%%\n",
                    entry.biome.id, sh and sh.covered * 100 or -1,
                    sh and sh.nearest or -1, sh and sh.strength or -1, darken * 100))
                io.write(string.format(
                    "    TOUR   %-10s ground %.3f %.3f %.3f sat %.2f | sky %.3f %.3f %.3f\n",
                    entry.biome.id, c[1], c[2], c[3], entry.sat,
                    entry.sky and entry.sky[1] or -1,
                    entry.sky and entry.sky[2] or -1,
                    entry.sky and entry.sky[3] or -1))
                io.flush()
            end
        end
    end
    local name = SHOTS[frame]
    if name and selftest.shots then
        love.graphics.captureScreenshot(string.format("shot-%s.png", name))
    end
end

function selftest.run(game, frame)
    selftest.game = game
    -- a heartbeat with real wall-clock time, so a stall is distinguishable
    -- from a merely slow software renderer
    if frame % 10 == 0 then
        local now = love.timer.getTime()
        local elapsed = now - (selftest.lastBeat or now)
        selftest.lastBeat = now
        io.write(string.format("[frame %3d] %5.1f ms/frame, %d draws, %d tris  (%s)\n",
            frame, elapsed * 100, game.renderer.stats.draws, game.renderer.stats.triangles,
            tostring(game.manager:current().__name or "?")))
        io.flush()
    end
    for _, s in ipairs(steps) do
        if s.frame == frame then
            local ok, err = pcall(s.fn, game)
            record(s.name, ok, err)
        end
    end
    if frame >= selftest.lastFrame then
        local failed = 0
        for _, r in ipairs(results) do
            if not r.ok then failed = failed + 1 end
        end
        io.write(string.rep("-", 52), "\n")
        io.write(string.format("selftest: %d steps, %d failed\n", #results, failed))
        io.write(string.format("renderer: %d draws, %d triangles in the last frame\n",
            game.renderer.stats.draws, game.renderer.stats.triangles))
        io.flush()
        love.event.quit(failed > 0 and 1 or 0)
    end
end

return selftest

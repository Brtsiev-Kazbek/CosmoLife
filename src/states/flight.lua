-- Flying.
--
-- One state covers everything from deep space to taxiing on a landing pad.
-- There is no "entering atmosphere" cutscene and no separate surface level:
-- the same ship, the same controls and the same update loop run throughout,
-- and the only thing that changes with altitude is which frame the ship is
-- integrated in.
--
--   space mode    position and velocity are absolute world coordinates
--   surface mode  position and velocity are local to a tangent frame on the
--                 body (see procgen.surface), so a landed ship rides the
--                 planet's rotation and orbit for free
--
-- The handover happens at config.scale.surfaceHandover with no visual break:
-- the sphere mesh is still drawn beyond the streamed terrain patch, and the
-- patch is bent to match the sphere's curvature.

local class = require("src.lib.class")
local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local stationGen = require("src.procgen.stations")
local systemGen = require("src.procgen.system")
local Surface = require("src.procgen.surface")
local combat = require("src.sim.combat")
local npcMod = require("src.sim.npc")
local hud = require("src.render.hud")
local ui = require("src.ui.widgets")
local settings = require("src.settings")
local i18n = require("src.i18n")
local hints = require("src.render.hints")
local mining = require("src.sim.mining")
local tutorial = require("src.sim.tutorial")
local objectives = require("src.sim.objectives")
local input = require("src.input")
local salvage = require("src.sim.salvage")
local context = require("src.sim.context")
local autopilot = require("src.flight.autopilot")
local audio = require("src.audio")
local rocks = require("src.flight.rocks")
local docking = require("src.flight.docking")
local scene = require("src.flight.scene")
local environment = require("src.flight.environment")
local combatState = require("src.flight.combat_state")

local Flight = class("FlightState")

local sqrt, min, max, abs, floor = math.sqrt, math.min, math.max, math.abs, math.floor
local atan2 = math.atan2 or math.atan
local FL = config.flight
local S = config.scale
local C = palette.colors
local L = i18n.format

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function Flight:init()
    self.drawUnderlying = false
end

function Flight:enter(spawnOpts)
    local game = self.game
    local world = game.world
    self.world = world
    self.player = world.player

    self.ship = self.ship or {
        isPlayer = true,
        pos = vec3(), vel = vec3(),
        right = vec3(1, 0, 0), up = vec3(0, 1, 0), fwd = vec3(0, 0, -1),
        angular = vec3(0, 0, 0),
    }
    local ship = self.ship
    ship.shipDef = self.player.shipDef
    ship.stats = self.player.stats
    ship.radius = self.player.shipDef.radius
    ship.hardpoints = self.player.shipDef.hardpoints
    ship.hull = self.player.hull
    ship.shield = self.player.shield
    ship.faction = "player"
    ship.dead = false
    ship.chaseScale = self.player.shipDef.length / 20

    self.throttle = 0
    self.heat = 0
    self.boostTimer = 0
    self.boostCooldown = 0
    self.warpState = "off"
    self.warpSpeed = 0
    self.warpSpool = 0
    self.gearDown = false
    self.fireTimer = 0
    self.muzzle = 0
    self.target = nil
    self.contacts = {}
    self.arena = combat.newArena()
    self.npcs = {}
    self.npcState = {}
    self.surface = nil
    self.landedOn = nil
    self.landedPlace = nil
    self.dockPrompt = nil
    self.stationMeshes = {}
    self.time = 0
    self.local_ = { pos = vec3(), vel = vec3(), right = vec3(1, 0, 0), up = vec3(0, 1, 0), fwd = vec3(0, 0, -1) }
    self.autopilot = nil
    self.pois = {}
    self.surfacePois = {}
    -- cargo spilled by wrecks, waiting to be scooped
    self.canisters = {}

    -- Objectives. One line and one marker serve the tutorial, contracts and
    -- the next rank, in that priority: a screen with three competing arrows
    -- points at nothing.
    self.player.tutorial = self.player.tutorial or tutorial.newState()
    self.objectives = objectives.tracker()
    self.objectives:addSource("tutorial", 1,
        tutorial.source(self.player.tutorial, config.keyName))
    self.objectives:addSource("contract", 2, objectives.contractSource)
    self.objectives:addSource("rank", 3, objectives.rankSource)

    self:spawn(spawnOpts)
    -- chase view by default: it is far easier to judge attitude and altitude
    -- with the hull in frame than from inside it
    self.game.camera.mode = self.game.camera.mode or settings.get("defaultView")
    self.game.camera.chaseMultiplier = settings.get("chaseDistance")
    self:setMouseFlight(settings.get("mouseFlight"))
end

--- Places the ship somewhere sensible on entering the state.
function Flight:spawn(opts)
    opts = opts or {}
    local sys = self.world.system
    local ship = self.ship

    if opts.atPort and opts.atPort.kind == "station" then
        local mesh = self:stationMesh(opts.atPort)
        local mx, my, mz, nx, ny, nz = stationGen.mouthWorld(opts.atPort, mesh)
        ship.pos:set(mx + nx * 400, my + ny * 400, mz + nz * 400)
        ship.fwd:set(-nx, -ny, -nz)
        ship.up:set(0, 1, 0)
        mat4.orthonormalize(ship.right, ship.up, ship.fwd)
        ship.vel:set(0, 0, 0)
        self.throttle = 0
        hud.message(L("Launched from {name}", { name = opts.atPort.name }), "info")
        return
    end

    if opts.atSurface and opts.atSurface.place then
        -- launching from a settlement: start on its pad, gear down
        local place = opts.atSurface.place
        local body = place.body or opts.atSurface.body
        self:enterSurface(body, place.latitude, place.longitude)
        local sx, sz = self.surface:latLonToLocal(place.latitude, place.longitude)
        local h = self.surface:groundHeight(sx, sz)
        self.local_.pos:set(sx, h + 6, sz)
        self.local_.vel:set(0, 0, 0)
        self.local_.fwd:set(0, 0, 1)
        self.local_.up:set(0, 1, 0)
        mat4.orthonormalize(self.local_.right, self.local_.up, self.local_.fwd, -1)
        self.gearDown = true
        self.landedOn = body
        self.landedPlace = place
        self:syncFromLocal()
        hud.message(L("On the pad at {name}", { name = place.name }), "info")
        return
    end

    -- Default arrival.
    --
    -- Previously this dropped the ship fourteen radii from the *innermost*
    -- planet, facing it, and said nothing -- the one spawn path in the game
    -- that printed no message. A new pilot appeared in empty space with no
    -- target, no prompt and no idea which of a dozen unlabelled boxes in the
    -- sky was a station. Now it arrives on the approach to the system's main
    -- station, pointed at it, and says so.
    local station = sys.stations and sys.stations[1]
    local base, d, name
    if station then
        base, d, name = station.pos, math.max(station.size * 26, 40000), station.name
    else
        local body
        for _, b in ipairs(sys.bodies) do
            if b.kind == "planet" then body = b break end
        end
        base = body and body.pos or sys.star.pos
        d = body and (body.radius * 14) or (sys.star.radius * 8)
        name = body and body.name or sys.star.name
    end

    ship.pos:set(base.x + d, base.y + d * 0.25, base.z + d)
    local dx, dy, dz = vec3.normT(base.x - ship.pos.x, base.y - ship.pos.y, base.z - ship.pos.z)
    ship.fwd:set(dx, dy, dz)
    ship.up:set(0, 1, 0)
    mat4.orthonormalize(ship.right, ship.up, ship.fwd)
    ship.vel:set(0, 0, 0)
    self.throttle = 0

    -- the contact list is rebuilt in update(), so the target is picked on the
    -- first frame rather than here
    self.pendingArrivalTarget = true
    hud.message(L("Arrived in {system}. {name} ahead.",
        { system = sys.stub and sys.stub.name or sys.name or "?", name = name }), "info")
end

function Flight:stationMesh(st)
    local m = self.stationMeshes[st.seed]
    if not m then
        m = stationGen.generate(st)
        self.stationMeshes[st.seed] = m
    end
    return m
end

-- ---------------------------------------------------------------------------
-- Frame handover
-- ---------------------------------------------------------------------------

function Flight:enterSurface(body, lat, lon)
    if self.surface and self.surface.body == body then return end
    if self.surface then self.surface:release() end
    self.surface = Surface.new(body)
    local allSettlements = body.settlements or {}
    self.surface:setOrigin(lat, lon, allSettlements)
    self:syncToLocal()
    hud.message(L("Approaching {name}", { name = body.name }), "info")
end

function Flight:leaveSurface()
    if not self.surface then return end
    self.surface:release()
    self.surface = nil
    self.landedOn = nil
    self.landedPlace = nil
end

--- World state -> local frame state.
--- Which way round a cross product goes in the frame the ship is flying in.
--
-- The surface tangent frame (east, up, north) is left-handed -- measured, its
-- determinant is exactly -1 -- so `right = fwd x up` comes out mirrored there.
-- Everything that rebuilds the ship's basis while in surface mode has to say
-- so, or the controls turn the wrong way (see mat4.orthonormalize). This is
-- the same notion `sim/walker.lua` carries as `self.handed`; the walker was
-- fixed when the on-foot camera was reported and the ship was not.
function Flight:frameHanded()
    return self.surface and -1 or 1
end

function Flight:syncToLocal()
    local s, ship, l = self.surface, self.ship, self.local_
    if not s then return end
    local x, y, z = s:toLocal(ship.pos.x, ship.pos.y, ship.pos.z)
    l.pos:set(x, y, z)
    local vx, vy, vz = s:dirToLocal(ship.vel.x, ship.vel.y, ship.vel.z)
    l.vel:set(vx, vy, vz)
    local fx, fy, fz = s:dirToLocal(ship.fwd.x, ship.fwd.y, ship.fwd.z)
    l.fwd:set(fx, fy, fz)
    local ux, uy, uz = s:dirToLocal(ship.up.x, ship.up.y, ship.up.z)
    l.up:set(ux, uy, uz)
    mat4.orthonormalize(l.right, l.up, l.fwd, -1)
end

--- Local frame state -> world state (run every frame while on a surface).
function Flight:syncFromLocal()
    local s, ship, l = self.surface, self.ship, self.local_
    if not s then return end
    s:toWorld(l.pos.x, l.pos.y, l.pos.z, ship.pos)
    local vx, vy, vz = s:dirToWorld(l.vel.x, l.vel.y, l.vel.z)
    ship.vel:set(vx, vy, vz)
    local fx, fy, fz = s:dirToWorld(l.fwd.x, l.fwd.y, l.fwd.z)
    ship.fwd:set(fx, fy, fz)
    local ux, uy, uz = s:dirToWorld(l.up.x, l.up.y, l.up.z)
    ship.up:set(ux, uy, uz)
    mat4.orthonormalize(ship.right, ship.up, ship.fwd)
end

-- ---------------------------------------------------------------------------
-- Environment
-- ---------------------------------------------------------------------------

-- Lighting, atmosphere, gravity, the surface handover, the nebula colour, the
-- sky tint and the weather overhead all live in src/flight/environment.lua:
-- the part of the state that changes for reasons the pilot has no say in.

function Flight:updateEnvironment(skip) return environment.updateEnvironment(self, skip) end
function Flight:nebulaHue() return environment.nebulaHue(self) end
function Flight:sunVisible() return environment.sunVisible(self) end
function Flight:skyTint(body) return environment.skyTint(self, body) end
function Flight:updateWeather(body) return environment.updateWeather(self, body) end



--- Where the current objective is in the world, if it can say.
--
-- The tracker has always been able to answer this and nothing ever asked: the
-- position was computed straight into the HUD context and read by nobody, so
-- the game knew where your contract was and never showed you. One call a
-- frame, kept on the state so the HUD and anything else that wants it see the
-- same answer.
function Flight:updateObjectiveMarker()
    if not self.objectives then self.objectiveMarker = nil return end
    local x, y, z = self.objectives:markerPos(self._objCtx)
    if not x then self.objectiveMarker = nil return end
    local m = self.objectiveMarker or {}
    m[1], m[2], m[3] = x, y, z
    self.objectiveMarker = m
end

--- How long ago anything violent happened, and whether it is still nearby.
--
-- The HUD uses this to decide it is in a fight (render/hudmode.lua). Firing is
-- not enough on its own -- a miner burns rock all day -- so it is fire *or*
-- losing shield or hull, and a hostile inside scanner range keeps it up
-- regardless.
function Flight:updateCombatMood(dt)
    local health = (self.ship.hull or 0) + (self.ship.shield or 0)
    local hurt = self._lastHealth and health < self._lastHealth - 0.5
    self._lastHealth = health
    if hurt or self.firedRecently then
        self.sinceCombat = 0
    elseif self.sinceCombat then
        self.sinceCombat = self.sinceCombat + dt
    end
    self.firedRecently = false

    local range = self.player.stats.scanRange or config.combat.scanRange
    self.hostileNear = false
    for _, c in ipairs(self.contacts) do
        if c.hostile and (c.distance or 1e12) < range then
            self.hostileNear = true
            break
        end
    end
end

--- The soundscape: the drive and the air outside it.
--
-- Both are continuous voices rather than events, so this only sets where they
-- should be and audio.update slides them there. The two are exclusive: in
-- cruise the drive is doing something else and sounds like it.
function Flight:updateSound(dt)
    local thrust = math.abs(self.throttle or 0)
    local cruising = self.warpState == "cruise" or self.warpState == "spool"
    -- an idling drive is still running, so it never goes fully silent in space
    local idle = self.landedOn and 0 or 0.16
    audio.loop("engine", cruising and 0 or (idle + thrust * 0.8),
        0.75 + thrust * 0.55)
    audio.loop("cruise", cruising and 0.75 or 0, 0.9 + (self.warpSpool or 0) * 0.2)

    -- Wind needs air to be in and something to blow: on an airless moon the
    -- loudest storm in the generator is still silence.
    local air = util.clamp((self.airDensity or 0) * 1.4, 0, 1)
    local w = self.weather
    local strength = w and w.strength or 0
    local speed = util.clamp((self.speed or 0) / 320, 0, 1)
    audio.loop("wind", air * util.clamp(0.12 + strength * 0.7 + speed * 0.5, 0, 1),
        0.85 + strength * 0.3)

    audio.update(dt)
end

--- Roll and pitch relative to the local horizontal, for the attitude
--- indicator.  In surface mode the local frame already *is* the horizontal,
--- which makes this two dot products rather than a change of basis.
function Flight:attitude()
    if not self.surface or not self.altitude then return nil end
    if self.altitude > 26000 then return nil end
    local l = self.local_
    local pitch = math.asin(util.clamp(l.fwd.y, -1, 1))
    local roll = math.atan2 and math.atan2(l.right.y, l.up.y) or 0
    local landable = false
    if self.surface then
        landable = self.surface:isLandable(l.pos.x, l.pos.z, 14)
    end
    return { roll = roll, pitch = pitch, landable = landable }
end

-- ---------------------------------------------------------------------------
-- Autopilot
-- ---------------------------------------------------------------------------
--
-- The autopilot lives in src/flight/autopilot.lua. What is left here is the
-- four entry points the rest of the game calls, so a key binding, a test or a
-- docking routine does not have to know where the logic moved to.

function Flight:toggleAutopilot() return autopilot.toggle(self) end
function Flight:cancelAutopilot(message) return autopilot.cancel(self, message) end
function Flight:updateAutopilot(dt) return autopilot.update(self, dt) end

--- The ship's speed relative to something that is itself moving.
function Flight:relativeSpeed(vel)
    local v = self.ship.vel
    if not vel then return self.speed or v:length() end
    local dx, dy, dz = v.x - (vel[1] or 0), v.y - (vel[2] or 0), v.z - (vel[3] or 0)
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function Flight:faceStationMouth(station) return autopilot.faceStationMouth(self, station) end
function Flight:brakeToApproach() return autopilot.brakeToApproach(self) end




-- ---------------------------------------------------------------------------
-- Controls
-- ---------------------------------------------------------------------------

--- Attitude input.
--
-- The mouse is the primary aim device and is on by default: the pointer is
-- captured and its motion pitches and yaws the nose directly, which is the
-- scheme every space sim converged on because it maps "look where you want to
-- go" onto the device people already point with.  The keyboard keeps a full
-- fallback so the game is playable without a mouse at all.
--- How far the camera is rolled relative to the hull, about the shared nose
--- axis. Zero whenever the view is glued to the hull, which is most of the time.
function Flight:viewRoll(basis)
    local cam = self.game and self.game.camera
    if not cam or not cam.up then return 0 end
    -- the camera lives in world space; the hull's basis may not
    local ux, uy, uz = cam.up.x, cam.up.y, cam.up.z
    if self.surface then
        ux, uy, uz = self.surface:dirToLocal(ux, uy, uz)
    end
    local c = ux * basis.up.x + uy * basis.up.y + uz * basis.up.z
    local s = ux * basis.right.x + uy * basis.right.y + uz * basis.right.z
    if math.abs(s) < 1e-4 and c > 0 then return 0 end
    return atan2(s, c)
end

function Flight:readRotation(dt, basis, agility)
    local pitch, yaw, roll = 0, 0, 0

    if config.down("pitchUp") then pitch = pitch + 1 end
    if config.down("pitchDown") then pitch = pitch - 1 end
    if config.down("yawLeft") then yaw = yaw - 1 end
    if config.down("yawRight") then yaw = yaw + 1 end
    if config.down("rollLeft") then roll = roll - 1 end
    if config.down("rollRight") then roll = roll + 1 end

    -- any manual input takes the ship back: an autopilot you cannot override
    -- instantly is a trap, not a convenience
    if self.autopilot and (pitch ~= 0 or yaw ~= 0 or roll ~= 0
        or math.abs(self.mouseDx or 0) > 0.05 or math.abs(self.mouseDy or 0) > 0.05) then
        self:cancelAutopilot("Autopilot disengaged")
    end

    if self.mouseSteer then
        -- accumulated mouse motion, decayed so the ship settles when the hand
        -- stops rather than drifting on
        pitch = pitch + util.clamp(-(self.mouseDy or 0), -1, 1)
        yaw = yaw + util.clamp(self.mouseDx or 0, -1, 1)
        local decay = math.exp(-16 * dt)
        self.mouseDx = (self.mouseDx or 0) * decay
        self.mouseDy = (self.mouseDy or 0) * decay
    end

    -- Steer in the frame the player is looking through, not the hull's.
    --
    -- Near the ground the camera levels itself to the horizon while the hull
    -- does not, so the two can be a long way apart -- at the limit the view is
    -- upright over a hull that is upside down. Yawing about the *hull's* axis
    -- then moves the view the other way, and the mouse works backwards.
    --
    -- This is the mechanism the rolled-approach test has always asked for. It
    -- appeared to work before only because the surface frame's left-handedness
    -- was mirroring `right` (see mat4.orthonormalize): two wrongs that cancelled
    -- at a half turn and disagreed everywhere else, which is why level flight
    -- had inverted controls while a nearly inverted hull did not.
    --
    -- phi is the roll of the camera relative to the hull about the shared
    -- forward axis; rotating the input by it turns "up and right on screen"
    -- into "up and right for the hull".
    local phi = self:viewRoll(basis)
    if phi ~= 0 then
        local c, s = math.cos(phi), math.sin(phi)
        pitch, yaw = pitch * c - yaw * s, yaw * c + pitch * s
    end

    -- Landing mode: with the gear down close to the ground the ship holds
    -- itself level with the local horizon.  This is the single biggest reason
    -- landing used to feel like being upside down -- there was no up.
    --
    -- The roll term is the angle to level, not just `right.y`. `right.y` is
    -- zero when the ship is upright *and* when it is exactly upside down, so
    -- the old term had a stable equilibrium at inverted: a ship that arrived
    -- on its back stayed on its back, with the camera cheerfully showing a
    -- level horizon over mirrored controls.
    local rollAngle = atan2(basis.right.y, basis.up.y)
    if self.hoverMode then
        -- roll and pitch back towards level, leaving yaw to the player
        roll = roll - util.clamp(rollAngle * 2.0, -1, 1)
        pitch = pitch - util.clamp(basis.fwd.y * 3.2, -1, 1)
    elseif (self.autoLevel ~= false and settings.get("autoLevel")) and self.surface then
        roll = roll - util.clamp(rollAngle * 1.6, -1, 1)
    end

    local a = self.ship.angular
    local rate = agility
    a.x = util.damp(a.x, pitch * FL.pitchRate * rate, FL.rotDamping, dt)
    a.y = util.damp(a.y, yaw * FL.yawRate * rate, FL.rotDamping, dt)
    a.z = util.damp(a.z, roll * FL.rollRate * rate, FL.rotDamping, dt)

    basis.fwd:addScaled(basis.up, a.x * dt)
    basis.fwd:addScaled(basis.right, a.y * dt)
    basis.up:addScaled(basis.right, -a.z * dt)
    basis.fwd:normalize()
    mat4.orthonormalize(basis.right, basis.up, basis.fwd, self:frameHanded())
end

function Flight:readThrottle(dt)
    if config.down("throttleUp") then self.throttle = min(1, self.throttle + dt * 0.9) end
    if config.down("throttleDown") then self.throttle = max(-0.4, self.throttle - dt * 0.9) end
end

-- ---------------------------------------------------------------------------
-- Flight model
-- ---------------------------------------------------------------------------

--- Ceiling on frame shift speed: the closer to a mass, the slower you go.
function Flight:warpCeiling()
    local sys = self.world.system
    local best = math.huge
    local ship = self.ship
    for _, b in ipairs(systemGen.landables(sys)) do
        local d = systemGen.altitude(b, ship.pos.x, ship.pos.y, ship.pos.z)
        best = min(best, max(d, 1))
    end
    local ds = self.starDistance and (self.starDistance - sys.star.radius) or math.huge
    best = min(best, max(ds, 1))
    return util.clamp(best * FL.warpMassLock, FL.warpMinSpeed, FL.warpMaxSpeed), best
end

function Flight:updateWarp(dt)
    -- the autopilot drives the warp state itself
    if self.autopilot then
        local ceiling = self:warpCeiling()
        if self.warpState == "cruise" then
            local target = ceiling * util.clamp(self.throttle, 0.1, 1)
            self.warpSpeed = self.warpSpeed + (target - self.warpSpeed) * util.clamp(FL.warpAccel * dt, 0, 1)
        end
        self.warpFraction = ceiling > 0 and util.clamp(self.warpSpeed / ceiling, 0, 1) or 0
        return
    end
    local wants = config.down("warp")
    local ceiling, clearance = self:warpCeiling()
    self.massLocked = clearance < FL.warpMinAltitude

    if self.warpState == "off" then
        if wants and not self.landedOn then
            if self.massLocked then
                hud.message(L("Mass locked - too close to a surface"), "warn")
                self.warpState = "off"
            else
                self.warpState = "spool"
                self.warpSpool = 0
            end
        end
    elseif self.warpState == "spool" then
        self.warpSpool = self.warpSpool + dt
        if not wants then
            self.warpState = "off"
            self:brakeToApproach()
        elseif self.warpSpool >= FL.warpSpoolTime then
            self.warpState = "cruise"
            self.warpSpeed = max(self.warpSpeed, FL.warpMinSpeed)
            hud.message(L("Frame shift engaged"), "good")
        end
    else
        if not wants or self.massLocked then
            self.warpState = "off"
            self.warpSpeed = 0
            -- the same applies to letting go of the key by hand: cruise
            -- velocity is assigned, not accumulated, so it must not be handed
            -- to the Newtonian integrator as if the hull had earned it
            self:brakeToApproach()
            if self.massLocked then hud.message(L("Frame shift dropped - mass lock"), "warn") end
        else
            local target = ceiling * util.clamp(self.throttle, 0, 1)
            target = max(target, FL.warpMinSpeed * 0.5)
            self.warpSpeed = self.warpSpeed + (target - self.warpSpeed) * util.clamp(FL.warpAccel * dt, 0, 1)
            self.heat = self.heat + dt * 3
        end
    end
    self.warpFraction = ceiling > 0 and util.clamp(self.warpSpeed / ceiling, 0, 1) or 0
end

--- Integrates the ship in whichever frame it currently lives in.
function Flight:updateShip(dt)
    local ship = self.ship
    local stats = self.player.stats
    local onSurface = self.surface ~= nil
    local basis = onSurface and self.local_ or ship
    local pos = onSurface and self.local_.pos or ship.pos
    local vel = onSurface and self.local_.vel or ship.vel

    self:readThrottle(dt)
    self:readRotation(dt, basis, stats.agility or 1)
    self:updateWarp(dt)

    -- boost
    if self.boostCooldown > 0 then self.boostCooldown = self.boostCooldown - dt end
    if self.boostTimer > 0 then self.boostTimer = self.boostTimer - dt end
    self.boosting = self.boostTimer > 0

    if self.warpState == "cruise" then
        -- frame shift: velocity is simply the nose direction times the speed
        vel:copyFrom(basis.fwd):scale(self.warpSpeed)
        pos:addScaled(vel, dt)
        if onSurface then self:syncFromLocal() end
        self.speed = self.warpSpeed
        self:updateHeat(dt)
        return
    end

    local accel = FL.linearAccel * (stats.thrust or 1)
    if self.boosting then accel = accel * FL.boostMultiplier end
    local topSpeed = stats.topSpeed or FL.maxSpeed
    if self.boosting then topSpeed = topSpeed * 1.6 end

    -- Landing mode: gear down, close to the ground, moving slowly.  The ship
    -- holds level (see readRotation), the main drive is capped to a taxi
    -- speed, and the translation thrusters take over -- so setting down is
    -- flying a hovering craft, not aiming a fighter at the dirt.
    self.hoverMode = settings.get("landingAssist") and onSurface and self.gearDown
        and (self.altitude or 1e9) < FL.hoverAltitude
        and self.warpState == "off"
    if self.hoverMode then topSpeed = min(topSpeed, FL.hoverSpeed) end

    -- main drive
    local targetSpeed = topSpeed * self.throttle
    if self.throttle < 0 then targetSpeed = topSpeed * self.throttle * FL.reverseFactor end
    local along = vel.x * basis.fwd.x + vel.y * basis.fwd.y + vel.z * basis.fwd.z
    local delta = util.approach(along, targetSpeed, accel * dt) - along
    vel:addScaled(basis.fwd, delta)

    -- translation thrusters: strafe and vertical, always available.  These
    -- are what make a precise landing possible at all.
    local strafe, lift = 0, 0
    if config.down("strafeLeft") then strafe = strafe - 1 end
    if config.down("strafeRight") then strafe = strafe + 1 end
    if config.down("thrustUp") then lift = lift + 1 end
    if config.down("thrustDown") then lift = lift - 1 end
    -- Landing mode borrows the movement keys.
    --
    -- Hovering holds the ship level, so roll has nothing to do and throttle
    -- has almost nothing; meanwhile the two things that matter -- sliding
    -- sideways and letting yourself down -- were on four keys nobody had been
    -- told about. WASD means "move" everywhere else in the game, so in landing
    -- mode it means it here too.
    if self.hoverMode then
        if config.down("rollLeft") then strafe = strafe - 1 end
        if config.down("rollRight") then strafe = strafe + 1 end
        -- cruise and boost have nothing to do this close to the ground
        if config.down("warp") then lift = lift + 1 end
        if config.down("boost") then lift = lift - 1 end
    end
    local transAccel = accel * FL.lateralFactor
    if strafe ~= 0 then vel:addScaled(basis.right, strafe * transAccel * dt) end
    if lift ~= 0 then vel:addScaled(basis.up, lift * transAccel * dt) end
    self.translating = (strafe ~= 0 or lift ~= 0)

    -- flight assist: bleed off sideways velocity so the ship goes where it points
    local assist = 1 - math.exp(-2.6 * dt)
    if self.hoverMode then assist = 1 - math.exp(-4.5 * dt) end
    local lateralX = vel.x - basis.fwd.x * along
    local lateralY = vel.y - basis.fwd.y * along
    local lateralZ = vel.z - basis.fwd.z * along
    vel.x = vel.x - lateralX * assist
    vel.y = vel.y - lateralY * assist
    vel.z = vel.z - lateralZ * assist

    -- gravity and atmosphere
    if onSurface then
        -- in landing mode the drives carry most of the weight, so the ship
        -- settles gently instead of dropping like a stone
        local weight = self.hoverMode and (self.gravity * FL.hoverGravityRelief) or self.gravity
        vel.y = vel.y - weight * dt
        if self.hoverMode and lift == 0 then
            -- damp vertical drift so it hovers where it was left
            vel.y = vel.y * math.exp(-2.2 * dt)
        end
        if self.airDensity > 0.001 then
            local speed = vel:length()
            local drag = FL.dragSeaLevel * self.airDensity * speed
            vel:scale(max(0, 1 - drag * dt))
            -- lift keeps a nose-up ship flying rather than falling
            local lift = FL.liftFactor * self.airDensity * speed * 0.001
            vel.y = vel.y + lift * basis.up.y * dt * speed * 0.02
            self.heat = self.heat + FL.heatRate * self.airDensity * speed * speed * speed * dt
        end
    elseif self.nearBody and self.upVec and self.altitude and self.altitude < self.nearBody.radius * 6 then
        vel.x = vel.x - self.upVec.x * self.gravity * dt
        vel.y = vel.y - self.upVec.y * self.gravity * dt
        vel.z = vel.z - self.upVec.z * self.gravity * dt
    end

    pos:addScaled(vel, dt)

    if onSurface then
        self:collideGround(dt)
        self:syncFromLocal()
    end

    self.speed = vel:length()
    self:updateHeat(dt)
end

function Flight:updateHeat(dt)
    local stats = self.player.stats
    -- fuel scooping near a star is the classic risk/reward heat source
    if stats.fuelScoop and self.starDistance then
        local corona = self.world.system.star.radius * 2.6
        if self.starDistance < corona then
            local rate = (1 - self.starDistance / corona)
            self.player.fuel = min(stats.fuel, self.player.fuel + rate * 1.4 * dt)
            self.heat = self.heat + rate * 26 * dt
            self.scooping = true
        else
            self.scooping = false
        end
    end
    self.heat = max(0, self.heat - self.heat * FL.heatCooling * dt - dt * 0.6)
    local cap = stats.heatCapacity or 100
    self.overheating = self.heat > cap * 0.85
    if self.heat > cap then
        local over = (self.heat - cap) / cap
        self.ship.hull = self.ship.hull - over * 14 * dt
        if ui.blink(0.35) then hud.message(L("HULL OVERHEATING"), "alert") end
        if self.ship.hull <= 0 then self:destroyed("burned up") end
    end
end

--- Ground contact: land, bounce or crash.
function Flight:collideGround(dt)
    local s, l = self.surface, self.local_
    local ground = s:groundHeight(l.pos.x, l.pos.z)
    local clearance = self.player.shipDef.length * 0.22 + 1.2
    local floorY = ground + clearance

    if l.pos.y > floorY then
        if self.landedOn then
            -- lifted off
            self.landedOn = nil
            self.landedPlace = nil
        end
        return
    end

    local vertical = l.vel.y
    local speed = l.vel:length()
    local nx, ny, nz = s:groundNormal(l.pos.x, l.pos.z, 8)
    local align = l.up.x * nx + l.up.y * ny + l.up.z * nz

    local safe = self.gearDown
        and speed < FL.landingSpeedMax
        and vertical > -FL.landingSpeedMax
        and align > math.cos(FL.landingAngleMax)

    l.pos.y = floorY
    if safe then
        l.vel:set(0, 0, 0)
        if not self.landedOn then
            self.landedOn = self.surface.body
            self.player.record.landings = self.player.record.landings + 1
            local pad = s:padNear(l.pos.x, l.pos.z, FL.landingPadRadius * 3)
            if pad then
                self.landedPlace = pad.settlement.place
                -- one key does both; the prompt says which
                hud.message(L("Landed at {name}  -  {key} to enter", {
                    name = pad.settlement.place.name,
                    key = config.keyName("interact"),
                }), "good")
            else
                self.landedPlace = nil
                hud.message(L("Touchdown  -  {key} to disembark", { key = config.keyName("interact") }), "good")
            end
        end
    else
        -- impact
        local damage = max(0, speed - FL.landingSpeedMax) * 2.6 + (self.gearDown and 0 or 12)
        if damage > 1 then
            combat.damage(self.ship, damage, true, nil)
            self.game.camera:addShake(util.clamp(damage / 40, 0.1, 1.2))
            hud.message(L("Impact! -{n} hull", { n = floor(damage) }), "alert")
            if self.ship.hull <= 0 then self:destroyed("crashed") end
        end
        -- bounce along the surface normal, losing most of the energy
        local vn = l.vel.x * nx + l.vel.y * ny + l.vel.z * nz
        l.vel.x = (l.vel.x - nx * vn * 1.4) * 0.4
        l.vel.y = (l.vel.y - ny * vn * 1.4) * 0.4
        l.vel.z = (l.vel.z - nz * vn * 1.4) * 0.4
    end
end

-- ---------------------------------------------------------------------------
-- Weapons and targeting
-- ---------------------------------------------------------------------------

-- Firing, missiles, shield cells, the contact list, target selection, the
-- scanner and what a kill does to reputation and cargo all live in
-- src/flight/combat_state.lua.

function Flight:updateWeapons(dt) return combatState.updateWeapons(self, dt) end
function Flight:updateContacts() return combatState.updateContacts(self) end
function Flight:cycleTarget(hostileOnly) return combatState.cycleTarget(self, hostileOnly) end
function Flight:targetNearestPort() return combatState.targetNearestPort(self) end
function Flight:updateAutomation(dt) return combatState.updateAutomation(self, dt) end
function Flight:scanProgress() return combatState.scanProgress(self) end
function Flight:scanTarget() return combatState.scanTarget(self) end
function Flight:useShieldCell() return combatState.useShieldCell(self) end
function Flight:fireMissile() return combatState.fireMissile(self) end
function Flight:onKill(victim, killer) return combatState.onKill(self, victim, killer) end









-- ---------------------------------------------------------------------------
-- Docking and landing
-- ---------------------------------------------------------------------------

-- The sensing and the four consequences live in src/flight/docking.lua; what
-- the key is *offering* is decided in src/sim/context.lua, so the prompt the
-- player reads and the action the key runs cannot disagree.

function Flight:updateDockPrompt() return docking.updatePrompt(self) end
function Flight:contextAction() return docking.act(self) end
function Flight:scoop(canister) return docking.scoop(self, canister) end
function Flight:dock() return docking.dock(self) end
function Flight:disembark() return docking.disembark(self) end

-- ---------------------------------------------------------------------------
-- Death
-- ---------------------------------------------------------------------------

function Flight:destroyed(reason)
    if self.dying then return end
    self.dying = true
    combat.effect(self.arena, self.ship.pos.x, self.ship.pos.y, self.ship.pos.z,
        self.ship.radius * 3, "explosion")
    self.game.camera:addShake(1.4)
    self.player.record.deaths = self.player.record.deaths + 1
    local GameOver = require("src.states.gameover")
    self.manager:push(GameOver.new(), reason or "destroyed", self)
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

function Flight:update(dt, background)
    if background then return end
    self.time = self.time + dt
    self.lastDt = dt
    self.world:update(dt)
    if self.dying then return end

    -- The world clock just moved every planet along its orbit.  Re-anchor the
    -- landing frame and re-place the ship inside it *before* anything measures
    -- an altitude, or the ship is compared against a planet that has already
    -- moved on and the whole surface reference goes inconsistent.
    if self.surface then
        self.surface:refreshFrame()
        self:syncFromLocal()
    end

    self:updateEnvironment()
    self:updateAutopilot(dt)
    self:updateShip(dt)
    self:updateWeapons(dt)

    -- NPC traffic
    local ctx = {
        arena = self.arena,
        npcs = self.npcs,
        playerShip = self.ship,
        diplomacy = self.world.diplomacy,
        ports = systemGen.ports(self.world.system),
        time = self.time,
        groundHeight = self.surface and function(x, y, z)
            local lx, ly, lz = self.surface:toLocal(x, y, z)
            return self.surface:altitude(lx, ly, lz)
        end or nil,
        upAt = self.surface and function(x, y, z)
            return self.surface.up.x, self.surface.up.y, self.surface.up.z
        end or nil,
        -- miners need a rock to work; without these the behaviour bailed out
        pickRock = function(e) return self:rockNear(e.pos) end,
        mineRock = function(e, rock) mining.hit(rock, 14, self.rockDamage or {}) end,
    }
    npcMod.maintain(self.npcs, self.world.system, self.player, self.world.diplomacy,
        self.world.day, self.game.camera, dt, self.npcState)
    npcMod.update(self.npcs, dt, ctx)

    -- combat
    local entities = { self.ship }
    for _, e in ipairs(self.npcs) do entities[#entities + 1] = e end
    combat.update(self.arena, dt, {
        entities = entities,
        groundHeight = ctx.groundHeight,
        onKill = function(victim, killer) self:onKill(victim, killer) end,
    })
    combat.regenerate(self.ship, dt, self.player.stats)
    if self.ship.hull <= 0 then self:destroyed("destroyed in combat") end

    -- surface streaming
    if self.surface then
        self.surface:update(self.local_.pos.x, self.local_.pos.z, dt, self.altitude)
    end

    self:updateMining()
    salvage.update(self.canisters, dt)
    self:updateContacts()
    self:updateAutomation(dt)
    self:updateObjective()
    -- spawn() cannot pick a target because the contact list does not exist
    -- until the first update; this hands the new arrival something to fly to
    if self.pendingArrivalTarget then
        self.pendingArrivalTarget = nil
        self:targetNearestPort()
    end
    self:updateDockPrompt()
    self:updateObjectiveMarker()
    self:updateCombatMood(dt)
    self:updateSound(dt)

    self.player.hull = self.ship.hull
    self.player.shield = self.ship.shield

    local camera = self.game.camera
    camera:follow(self.ship, dt)
    -- Level the view with the local horizon as the ground comes up.  Full
    -- lock while landing, tapering off to none by the top of the atmosphere.
    --
    -- The blend has to be an absolute fraction, not a per-frame step. `follow`
    -- rebuilds the camera basis from the hull every frame, so a step of
    -- `1 - exp(-9 dt)` was not accumulating towards level -- it was applying
    -- fourteen percent of the correction to a fresh copy of the hull's roll,
    -- for ever. The horizon lock has therefore never done more than a seventh
    -- of its job, which is why a hull that ended up inverted on approach stayed
    -- visibly inverted. What eases over time is the *strength*, so the view
    -- still settles rather than snapping as the ground comes up.
    if self.upVec and self.altitude then
        local want = util.clamp(1 - (self.altitude / 30000), 0, 1)
            * settings.get("horizonLock")
        if self.hoverMode then want = 1 end
        self.levelBlend = (self.levelBlend or 0)
            + (want - (self.levelBlend or 0)) * (1 - math.exp(-4 * dt))
        if self.levelBlend > 0.002 then
            camera:levelToHorizon(self.upVec, self.levelBlend)
        end
    else
        self.levelBlend = 0
    end
end


-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

-- Every submit* function lives in src/flight/scene.lua: each reads the world
-- and calls renderer:draw, and none of them changes the simulation. What stays
-- here is Flight:draw, which decides the order and the camera.

function Flight:submitBodies(r) return scene.submitBodies(self, r) end
function Flight:submitAir(r, body, basis, dist) return scene.submitAir(self, r, body, basis, dist) end
function Flight:submitCityLights(r, body, basis, dist) return scene.submitCityLights(self, r, body, basis, dist) end
function Flight:bodyBasis(body, spinScale) return scene.bodyBasis(self, body, spinScale) end
function Flight:submitPois(r) return scene.submitPois(self, r) end
function Flight:submitStations(r) return scene.submitStations(self, r) end
function Flight:submitShips(r) return scene.submitShips(self, r) end
function Flight:submitWeather(r, camera) return scene.submitWeather(self, r, camera) end
function Flight:submitCanisters(r) return scene.submitCanisters(self, r) end
function Flight:submitEffects(r) return scene.submitEffects(self, r) end






-- Asteroids -- the working set, the ore a mining bolt frees and the drawing of
-- them -- live in src/flight/rocks.lua.
function Flight:submitRocks(renderer) return rocks.submit(self, renderer) end

--- Re-evaluates what the player should be doing, and says so when it changes.
function Flight:updateObjective()
    if not self.objectives then return end
    local ctx = self._objCtx or {}
    self._objCtx = ctx
    ctx.player = self.player
    ctx.flight = self
    ctx.systemId = self.world.stub and self.world.stub.id
    ctx.sawMap = self.sawMap
    ctx.findPort = function(name)
        for _, c in ipairs(self.contacts) do
            if (c.station and c.station.name == name) or (c.place and c.place.name == name) then
                return c
            end
        end
        return nil
    end

    local before = self.objective and self.objective.id
    local obj = self.objectives:update(ctx)
    self.objective = obj
    -- A change flashes the banner rather than pushing three lines into the
    -- message log: the banner already says the same words, and printing them
    -- twice buried the messages that were actually news.
    if obj and obj.id ~= before then
        self.objectiveFlash = 2.5
    elseif not obj and before then
        hud.message(L("All objectives complete. The galaxy is yours."), "good")
    end
    if self.objectiveFlash then
        self.objectiveFlash = self.objectiveFlash - (self.lastDt or 0)
        if self.objectiveFlash <= 0 then self.objectiveFlash = nil end
    end
end

--- The objective line, translated and with its arguments filled in.
function Flight:objectiveText(obj)
    if not obj then return "" end
    if obj.textArgs then
        local args = {}
        for k, v in pairs(obj.textArgs) do args[k] = i18n.term(v) end
        return L(obj.text, args)
    end
    return L(obj.text)
end

function Flight:objectiveHint(obj)
    if not obj or not obj.hint then return "" end
    if obj.hintArgs then return L(obj.hint, obj.hintArgs) end
    return L(obj.hint)
end

--- The nearest live rock to a point, for an NPC miner to work.
function Flight:rockNear(pos) return rocks.near(self, pos) end
function Flight:updateMining() return rocks.updateMining(self) end







function Flight:draw(background)
    local renderer = self.game.renderer
    local camera = self.game.camera
    local w, h = renderer.width, renderer.height

    renderer:beginFrame(camera)
    self:submitBodies(renderer)
    self:submitStations(renderer)
    self:submitPois(renderer)
    self:submitRocks(renderer)
    if self.surface then
        self.surface:draw(renderer, { nightGlow = self.nightGlow, eye = self.local_.pos })
    end
    self:submitShips(renderer)
    self:submitCanisters(renderer)
    self:submitWeather(renderer, camera)
    self:submitEffects(renderer)

    local sys = self.world.system
    renderer:endFrame(function()
        self.game.sky:draw(camera, w, h, 1 - (renderer.env.atmos or 0) * 0.95, renderer.env.atmos)
        -- The sun disc is 2D and has no depth, so it must not be drawn once
        -- the local horizon has swallowed it.
        if self:sunVisible() then
            self.game.sky:drawSun(camera, sys.star.pos, w, h, sys.star.radius, sys.star.color, false)
        end
    end)
    renderer:present()

    if background then return end

    hud.draw({
        ship = self.ship,
        player = self.player,
        world = self.world,
        camera = camera,
        contacts = self.contacts,
        target = self.target,
        speed = self.speed or 0,
        relativeSpeed = self.relativeTo and self:relativeSpeed(self.relativeTo) or nil,
        throttle = self.throttle,
        altitude = self.altitude,
        verticalSpeed = self.surface and self.local_.vel.y or nil,
        heat = self.heat,
        gearDown = self.gearDown,
        boosting = self.boosting,
        massLocked = self.massLocked and self.warpState ~= "off",
        overheating = self.overheating,
        warpState = self.warpState,
        warpFraction = self.warpFraction,
        hoverMode = self.hoverMode,
        horizon = self:attitude(),
        -- what the HUD should emphasise; see render/hudmode.lua
        cruise = self.warpState ~= "off",
        docking = self.relativeTo ~= nil,
        hostileNear = self.hostileNear,
        sinceCombat = self.sinceCombat,
        -- for the lead ring: the same numbers the bolt itself will use
        weaponSpeed = self.player:weapon().weapon.speed or config.combat.laserSpeed,
        weaponRange = config.combat.laserRange,
        corridor = self.corridor,
        autopilot = self.autopilot ~= nil,
        landed = self.landedOn ~= nil,
        gearDown = self.gearDown,
        dockPrompt = self.dockPrompt ~= nil,
        dockPromptIsPlace = self.dockPrompt and self.dockPrompt.place ~= nil,
        prompt = self.dockPrompt and self.dockPrompt.text or nil,
        objective = self.objective and self:objectiveText(self.objective) or nil,
        objectiveFlash = self.objectiveFlash,
        objectiveHint = self.objective and self:objectiveHint(self.objective) or nil,
        objectiveMarker = self.objectiveMarker,
    }, w, h)

    if settings.get("showHints") and not self.game.showHelp then
        local ctx = {
            hoverMode = self.hoverMode, target = self.target, autopilot = self.autopilot,
            warpState = self.warpState, gearDown = self.gearDown,
            dockPrompt = self.dockPrompt, landed = self.landedOn ~= nil,
            dockPromptIsPlace = self.dockPrompt and self.dockPrompt.place ~= nil,
            contextVerb = context.verb(self.dockPrompt and not self.dockPrompt.blocked
                and self.dockPrompt.kind or nil),
        }
        -- above the left gauge cluster, not on top of the target panel:
        -- both used to be drawn at (26, 26)
        local top = h - 150 - 24
        hints.draw(hints.flight(ctx), 26, top, {
            anchor = "bottom", maxLines = hints.rowsFor(top - 40),
        })
    end

    if self.game.showHelp then self:drawHelp(w, h) end
end

-- The controls panel.
--
-- Every row is generated from the live bindings. The old one was a hand
-- written table that had drifted a long way from reality: it advertised Q/E
-- for strafing, TAB for mouse flight and SPACE for firing, none of which were
-- true. Two columns, because the point of the scheme is that the left one is
-- all you need.
function Flight:drawHelp(w, h)
    local core = input.controlRows(input.flightHelp)
    local extra = input.controlRows(input.advancedHelp)
    local rows = math.max(#core, #extra)
    local colW = 300
    local pw, ph = colW * 2 + 44, rows * 20 + 92
    local px, py = (w - pw) * 0.5, (h - ph) * 0.5
    ui.panel(px, py, pw, ph, L("CONTROLS"))

    local function column(list, x, title)
        ui.text(L(title), x, py + 28, C.uiPrimary, "small")
        for i, r in ipairs(list) do
            local y = py + 50 + (i - 1) * 20
            ui.textFit(L(r[1]), x, y, colW - 96, C.uiText, "small")
            ui.textRight(r[2], x + colW - 22, y, C.uiPrimary, "small")
        end
    end
    column(core, px + 22, "BASICS")
    column(extra, px + 22 + colW, "ADVANCED")

    ui.textCenter(L("Everything on the left is the whole game. F1 to close."),
        px + pw * 0.5, py + ph - 26, C.uiDim, "small")
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function Flight:keypressed(key)
    if config.is("pause", key) then
        local Pause = require("src.states.pause")
        self.manager:push(Pause.new(), self)
        return
    end
    if config.is("help", key) then self.game.showHelp = not self.game.showHelp return end
    if config.is("throttleFull", key) then self.throttle = 1 return end
    if config.is("throttleZero", key) then self.throttle = 0 return end
    if config.is("boost", key) then
        if self.boostCooldown <= 0 and self.warpState == "off" then
            self.boostTimer = FL.boostDuration
            self.boostCooldown = FL.boostCooldown
            self.game.camera:addShake(0.25)
            hud.message(L("Boost"), "info")
        end
        return
    end
    if config.is("landingGear", key) then
        self.gearDown = not self.gearDown
        hud.message(self.gearDown and L("Landing gear down") or L("Landing gear up"), "info")
        return
    end
    if config.is("target", key) then self:cycleTarget(false) return end
    if config.is("nextTarget", key) then self:cycleTarget(true) return end
    if config.is("scan", key) then self:scanTarget() return end
    -- One key, and what it does is exactly what the HUD says it will do.
    if config.is("interact", key) then
        if self:contextAction() then return end
    end
    if config.is("panel", key) then
        local Panel = require("src.states.panel")
        self.manager:push(Panel.new(), self)
        return
    end
    if config.is("utility", key) then
        local Wheel = require("src.states.wheel")
        self.manager:push(Wheel.new(), self, key)
        return
    end
    if config.is("mouseFlight", key) then
        self:setMouseFlight(not self.mouseSteer)
        hud.message(self.mouseSteer and L("Mouse flight on") or L("Mouse flight off"), "info")
        return
    end
    if config.is("autopilot", key) then
        self:toggleAutopilot()
        return
    end
    if config.is("levelOut", key) then
        self.autoLevel = not self.autoLevel
        hud.message(self.autoLevel and L("Auto-level on") or L("Auto-level off"), "info")
        return
    end
    if config.is("view", key) then
        self.game.camera.mode = (self.game.camera.mode == "cockpit") and "chase" or "cockpit"
        return
    end
    if config.is("dock", key) then self:dock() return end
    if config.is("disembark", key) then self:disembark() return end
    if config.is("map", key) then
        local Map = require("src.states.galaxymap")
        self.sawMap = true
        self.manager:push(Map.new(), self)
        return
    end
    if config.is("missions", key) then
        local Log = require("src.states.logbook")
        self.manager:push(Log.new(), self)
        return
    end
    if config.is("colony", key) then
        local Colonies = require("src.states.colonies")
        self.manager:push(Colonies.new(), self, self.landedOn and self.surface or nil, self.local_)
        return
    end
    if config.is("ship", key) then
        local ShipInfo = require("src.states.shipinfo")
        self.manager:push(ShipInfo.new())
        return
    end
    if config.is("save", key) then
        local ok, err = self.game:saveGame()
        hud.message(ok and L("Game saved") or L("Save failed: {reason}", { reason = tostring(err) }),
            ok and "good" or "alert")
        return
    end
    if config.is("load", key) then
        local ok, err = self.game:loadGame()
        if ok then
            self.manager:switch(Flight.new())
        else
            hud.message(L("Load failed: {reason}", { reason = tostring(err) }), "alert")
        end
        return
    end
    -- Missiles were unreachable: this tested `key == "m"`, but `m` is the
    -- galaxy map binding and the map branch above returns first. Meanwhile the
    -- real binding (2 / middle mouse) was never queried by anything, so the
    -- two missiles a new pilot starts with, the ones the port sells at 1200
    -- credits each, and the key the help panel advertised could not be fired.
    if config.is("missile", key) then self:fireMissile() end
    if config.is("shieldCell", key) then self:useShieldCell() end
end



function Flight:setMouseFlight(on)
    self.mouseSteer = on
    self.mouseDx, self.mouseDy = 0, 0
    if love and love.mouse then love.mouse.setRelativeMode(on) end
end

function Flight:mousepressed(x, y, button)
    if button == 2 then
        self:setMouseFlight(not self.mouseSteer)
        hud.message(self.mouseSteer and L("Mouse flight on") or L("Mouse flight off"), "info")
    end
end

function Flight:mousemoved(x, y, dx, dy)
    if self.mouseSteer then
        local sens = settings.get("mouseSensitivity")
        local invert = settings.get("invertY") and -1 or 1
        self.mouseDx = util.clamp((self.mouseDx or 0) + dx * sens, -1.6, 1.6)
        self.mouseDy = util.clamp((self.mouseDy or 0) + dy * sens * invert, -1.6, 1.6)
    end
end

function Flight:wheelmoved(x, y)
    if settings.get("throttleWheel") then
        self.throttle = util.clamp(self.throttle + y * 0.1, -0.4, 1)
    end
end

function Flight:resume()
    self:setMouseFlight(self.mouseSteer ~= false)
    -- coming back from a docked screen: the ship may have been outfitted
    self.ship.stats = self.player.stats
    self.ship.hull = self.player.hull
    self.ship.shield = self.player.shield
    self.ship.shipDef = self.player.shipDef
    self.ship.radius = self.player.shipDef.radius
    self.ship.hardpoints = self.player.shipDef.hardpoints
end

function Flight:pause()
    if love and love.mouse then love.mouse.setRelativeMode(false) end
end

function Flight:exit()
    if self.surface then self.surface:release() end
    if love and love.mouse then love.mouse.setRelativeMode(false) end
end

return Flight

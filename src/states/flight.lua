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
local factions = require("src.sim.factions")
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
local weather = require("src.sim.weather")
local context = require("src.sim.context")
local autopilot = require("src.flight.autopilot")
local rocks = require("src.flight.rocks")
local docking = require("src.flight.docking")
local scene = require("src.flight.scene")

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
        mat4.orthonormalize(self.local_.right, self.local_.up, self.local_.fwd)
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
    mat4.orthonormalize(l.right, l.up, l.fwd)
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

--- Recomputes lighting, atmosphere and gravity for the ship's position.
-- `skipHandover` is passed by states that borrow the environment (on foot,
-- interiors) and must not have the terrain patch swapped under them.
function Flight:updateEnvironment(skipHandover)
    local sys = self.world.system
    local ship = self.ship
    local env = self.game.renderer.env

    -- sun: direction light travels, from the star outward
    local sx = ship.pos.x - sys.star.pos.x
    local sy = ship.pos.y - sys.star.pos.y
    local sz = ship.pos.z - sys.star.pos.z
    local dx, dy, dz = vec3.normT(sx, sy, sz)
    env.sunDir:set(dx, dy, dz)
    env.sunColor = sys.star.color
    self.starDistance = sqrt(sx * sx + sy * sy + sz * sz)

    local body = systemGen.dominantBody(sys, ship.pos.x, ship.pos.y, ship.pos.z)
    self.nearBody = body
    local altitude, density = nil, 0

    if body then
        altitude = systemGen.altitude(body, ship.pos.x, ship.pos.y, ship.pos.z)
        self.altitude = altitude
        local up = vec3(ship.pos.x - body.pos.x, ship.pos.y - body.pos.y, ship.pos.z - body.pos.z):normalize()
        env.worldUp:copyFrom(up)
        self.upVec = up
        self.gravity = (body.gravity or 9) * (body.radius / max(body.radius + max(altitude, 0), 1)) ^ 2

        if (body.atmosphere or 0) > 0.03 then
            local scaleHeight = S.atmosphereHeight * 0.34
            density = (body.atmosphere or 0) * math.exp(-max(altitude, 0) / scaleHeight)
            density = util.clamp(density, 0, 2.2)
        end
    else
        self.altitude = nil
        self.gravity = 0
        env.worldUp:copyFrom(self.game.camera.up)
        self.upVec = nil
    end
    self.airDensity = density

    -- sky and fog follow the atmosphere and the sun angle
    local atmos = util.clamp(density * 1.1, 0, 1)
    env.atmos = atmos
    -- the preset's nebula weight was declared in all four quality tables and
    -- read by nothing
    env.nebula = (1 - atmos) * (settings.q().nebula or 1)
    if body and atmos > 0.01 then
        local sunUp = 0
        if self.upVec then
            sunUp = -(env.sunDir.x * self.upVec.x + env.sunDir.y * self.upVec.y + env.sunDir.z * self.upVec.z)
        end
        local day = util.clamp(sunUp * 2 + 0.2, 0, 1)
        local base = self:skyTint(body)
        env.zenith = { base[1] * (0.12 + day * 0.85), base[2] * (0.14 + day * 0.85), base[3] * (0.2 + day * 0.9) }
        local warm = util.clamp(1 - abs(sunUp) * 3, 0, 1)
        env.horizon = {
            util.lerp(base[1] * 0.4, 0.95, day * 0.55) * (1 + warm * 0.5),
            util.lerp(base[2] * 0.4, 0.82, day * 0.5) * (1 + warm * 0.15),
            util.lerp(base[3] * 0.4, 0.78, day * 0.6) * (1 - warm * 0.25),
        }
        env.ground = { base[1] * 0.16, base[2] * 0.15, base[3] * 0.14 }
        env.fogColor = env.horizon
        -- Fog has to start well past the ship or it paints the ground you are
        -- standing on, which reads as a flat glossy sheet rather than as haze.
        env.fogAmount = util.clamp(atmos * 0.55, 0, 0.62)
        env.fogNear = util.lerp(26000, 5200, atmos)
        env.fogFar = util.lerp(90000, S.terrainViewRange * 1.6, atmos)

        -- Weather, once there is ground close enough for it to be over.
        --
        -- Every biome has always declared what its sky does and nothing read
        -- any of it, so a dune sea and a rainforest had the same clear air.
        self:updateWeather(body)
        local cond = self.weather
        if cond and cond.strength > 0 then
            env.fogColor = weather.tint(cond, env.fogColor)
            env.fogAmount = util.clamp(env.fogAmount + cond.fog * 0.55, 0, 0.92)
            -- a storm closes in around you rather than sitting on the horizon
            env.fogNear = env.fogNear * util.lerp(1, 0.12, cond.fog)
            env.fogFar = env.fogFar * util.lerp(1, 0.35, cond.fog)
        end
        -- A night side lit only by the sun is a black hole you cannot fly
        -- over.  Starlight, airglow and the ship's own floods put a floor
        -- under it, so the ground stays readable after dark.
        local nightFloor = 0.26
        env.ambient = {
            nightFloor * base[1] + day * 0.30 * base[1],
            nightFloor * base[2] + day * 0.30 * base[2],
            nightFloor * base[3] * 1.15 + day * 0.32 * base[3],
        }
        env.shadeFloor = 0.10
        self.dayFactor = day
    else
        env.fogAmount = 0
        env.ambient = { 0.075, 0.08, 0.105 }
        env.shadeFloor = 0.06
        -- Each system carries its own nebula palette, derived from its seed and
        -- warmed towards its star's colour, so jumping somewhere new actually
        -- looks like somewhere new instead of the same violet fog everywhere.
        env.zenith = self:nebulaHue()
        self.dayFactor = 1
    end

    self.game:applyLighting()

    -- how bright the settlement windows should be
    self.nightGlow = util.clamp(1.25 - (self.dayFactor or 1) * 1.05, 0.18, 1.25)

    -- terrain handover
    if skipHandover then return end
    if body and body.landable and altitude and altitude < S.surfaceHandover then
        local lat, lon = systemGen.surfaceCoords(body, ship.pos.x, ship.pos.y, ship.pos.z)
        if not self.surface or self.surface.body ~= body then
            self:enterSurface(body, lat, lon)
        else
            -- re-origin when the ship has travelled far across the patch
            local x, _, z = self.surface:toLocal(ship.pos.x, ship.pos.y, ship.pos.z)
            if sqrt(x * x + z * z) > Surface.CHUNK * 5 then
                self.surface:setOrigin(lat, lon, body.settlements or {})
                self:syncToLocal()
            end
        end
    elseif self.surface and (not altitude or altitude > S.surfaceHandover * 1.35) then
        self:leaveSurface()
    end
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

--- The nebula hue for the current system, cached per system id.
function Flight:nebulaHue()
    local id = self.world.stub and self.world.stub.id
    if self._hueId == id and self._hue then return self._hue end
    local Rng = require("src.lib.rng")
    local rng = Rng.new(self.world.stub and self.world.stub.seed or 1, "nebula")
    -- pick from a set of hues that read well against black, then lean the
    -- choice towards the star's own colour so the two agree
    local hues = {
        { 0.30, 0.10, 0.46 },   -- violet
        { 0.10, 0.26, 0.44 },   -- deep blue
        { 0.44, 0.14, 0.22 },   -- crimson
        { 0.10, 0.36, 0.32 },   -- teal
        { 0.42, 0.24, 0.10 },   -- amber
        { 0.32, 0.12, 0.34 },   -- magenta
        { 0.14, 0.34, 0.16 },   -- green
    }
    local h = hues[rng:int(1, #hues)]
    local star = self.world.system and self.world.system.star.color or { 1, 1, 1 }
    local k = rng:range(0.15, 0.4)
    self._hue = {
        h[1] * (1 - k) + star[1] * k * 0.5,
        h[2] * (1 - k) + star[2] * k * 0.5,
        h[3] * (1 - k) + star[3] * k * 0.5,
    }
    self._hueId = id
    return self._hue
end

--- False once the star has set behind the body we are standing on: the sun
--- sprite is drawn without depth, so it has to be culled by hand.
function Flight:sunVisible()
    local body, up = self.nearBody, self.upVec
    if not body or not up then return true end
    local alt = self.altitude or 0
    if alt > body.radius then return true end
    -- how far below the horizontal the horizon sits at this altitude
    local dip = math.sqrt(math.max(2 * alt / body.radius, 0))
    local sunUp = -(self.game.renderer.env.sunDir.x * up.x
                  + self.game.renderer.env.sunDir.y * up.y
                  + self.game.renderer.env.sunDir.z * up.z)
    return sunUp > -dip - 0.02
end

function Flight:skyTint(body)
    local t = body.type
    if t == "terran" then return { 0.42, 0.60, 0.95 } end
    if t == "ocean" then return { 0.36, 0.58, 0.92 } end
    if t == "desert" then return { 0.92, 0.72, 0.46 } end
    if t == "ice" then return { 0.66, 0.80, 0.95 } end
    if t == "volcanic" then return { 0.85, 0.42, 0.28 } end
    if t == "toxic" then return { 0.72, 0.85, 0.40 } end
    return { 0.55, 0.55, 0.60 }
end

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
    mat4.orthonormalize(basis.right, basis.up, basis.fwd)
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

function Flight:updateWeapons(dt)
    self.fireTimer = max(0, self.fireTimer - dt)
    if config.down("fire") and self.fireTimer <= 0 and not self.landedOn then
        local w = self.player:weapon()
        local def = w.weapon
        self.fireTimer = 1 / def.rate
        local ship = self.ship
        combat.fire(self.arena, ship, w, ship.fwd.x, ship.fwd.y, ship.fwd.z, self.muzzle)
        self.muzzle = self.muzzle + 1
        self.heat = self.heat + def.energy * 0.8
        self.game.camera:addShake(0.035)
    end
end

--- Rebuilds the contact list used by the HUD, scanner and targeting.
function Flight:updateContacts()
    local sys = self.world.system
    local ship = self.ship
    local list = self.contacts
    for i = #list, 1, -1 do list[i] = nil end

    local function add(entry) list[#list + 1] = entry end

    for _, e in ipairs(self.npcs) do
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
    for _, p in ipairs(self.pois) do
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
    if self.target then
        local found = false
        for _, c in ipairs(list) do
            if (c.entity and c.entity == self.target.entity)
                or (c.station and c.station == self.target.station)
                or (c.body and c.body == self.target.body)
                or (c.place and c.place == self.target.place)
                or (c.poi and c.poi == self.target.poi) then
                self.target = c
                found = true
                break
            end
        end
        if not found then self.target = nil end
    end

    if self.target then
        local t = self.target
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

function Flight:cycleTarget(hostileOnly)
    local best, bestIndex = nil, 0
    local startIndex = 0
    for i, c in ipairs(self.contacts) do
        if c == self.target then startIndex = i break end
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
    local n = #self.contacts
    local scanRange = config.combat.scanRange * 4
    for k = 1, n do
        local i = ((startIndex + k - 1) % n) + 1
        local c = self.contacts[i]
        local ok = c.marker
        if c.kind == "ship" then ok = ok and c.distance < scanRange end
        if hostileOnly then ok = ok and c.hostile end
        if ok then
            best, bestIndex = c, i
            break
        end
    end
    self.target = best
    if best then hud.message(L("Target: {name}", { name = best.label or "?" }), "info") end
end

--- Picks the nearest station, or failing that any dockable place, as a target.
--- Used on arrival so a new pilot has somewhere to point at.
function Flight:targetNearestPort()
    local best, bestD = nil, math.huge
    for _, c in ipairs(self.contacts) do
        if c.station or c.place then
            if c.distance < bestD then best, bestD = c, c.distance end
        end
    end
    if best then self.target = best end
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
function Flight:updateAutomation(dt)
    -- scanner lock
    if settings.get("autoScan") ~= false then
        local t = self.target
        local range = self.player.stats.scanRange or config.combat.scanRange
        local unscanned = t and ((t.entity and not t.entity.scanned) or (t.body and not t.bodyScanned))
        if t and unscanned and (t.distance or 1e12) < range
            and self.game.camera:angleTo(t.pos.x, t.pos.y, t.pos.z) < 0.12 then
            self.scanHold = (self.scanHold or 0) + dt
            if self.scanHold >= 2.0 then
                self.scanHold = 0
                if t.body then t.bodyScanned = true end
                self:scanTarget()
            end
        else
            self.scanHold = 0
        end
    end

    -- shield cells, at the last moment they are still worth anything
    if settings.get("autoShieldCell") ~= false and (self.player.shieldCells or 0) > 0 then
        local maxShield = self.player.stats.maxShield or 0
        if maxShield > 0 and self.player.shield < maxShield * 0.15 then
            self:useShieldCell()
        end
    end
end

--- How long the scanner has been holding the current target, 0..1.
function Flight:scanProgress()
    if not self.scanHold or self.scanHold <= 0 then return 0 end
    return util.clamp(self.scanHold / 2.0, 0, 1)
end

function Flight:scanTarget()
    local t = self.target
    if not t then hud.message(L("No target"), "warn") return end
    if t.distance > (self.player.stats.scanRange or config.combat.scanRange) then
        hud.message(L("Out of scanner range"), "warn")
        return
    end
    if t.entity then
        t.entity.scanned = true
        self.player.record.scanned = self.player.record.scanned + 1
        hud.message(L("{pilot} scanned - {faction}, {cash} cr cargo", {
            pilot = t.entity.pilot,
            faction = L(factions.get(t.entity.faction).name),
            cash = util.money(t.entity.cargoValue) }), "good")
    elseif t.body then
        self.world.player:addLog(L("Surveyed {name}", { name = t.body.name }), self.world.day, "nav")
        hud.message(L("{name}: {kind}, gravity {g} m/s2, atmosphere {atm} atm", {
            name = t.body.name, kind = L(t.body.typeName or "moon"),
            g = string.format("%.1f", t.body.gravity or 0),
            atm = string.format("%.2f", t.body.atmosphere or 0) }), "good")
    else
        hud.message(L("Nothing to scan"), "warn")
    end
end

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

function Flight:onKill(victim, killer)
    if killer == self.ship then
        self.player.record.kills = self.player.record.kills + 1
        local faction = victim.faction
        if faction == "pirates" then
            local bounty = victim.bounty or config.combat.bountyPerKill
            self.player:earn(bounty)
            hud.message(L("Bounty claimed: {cash} cr", { cash = util.money(bounty) }), "good")
            self.player:addReputation(self.world.system.factionId, 0.02)
        else
            -- killing a lawful ship is a crime where its owners have authority
            local fine = math.floor(1200 + (victim.stats.maxHull or 100) * 6)
            self.player:addBounty(faction, fine)
            hud.message(L("Bounty issued against you: {cash} cr", { cash = util.money(fine) }), "alert")
            npcMod.alert(self.npcs, faction, self.ship.pos, 14000)
        end
        local missionsMod = require("src.sim.missions")
        local touched = missionsMod.recordKill(self.player, faction, victim.pilot)
        for _, m in ipairs(touched) do
            hud.message(string.format("%s  (%d/%d)", missionsMod.title(m), m.progress or 0, m.quantity), "good")
        end
    end
    -- A hold does not evaporate with the ship around it. The scanner has
    -- always told the player what a target was carrying; now that number can
    -- actually be collected.
    local spilled = salvage.fromWreck(self.canisters, victim)
    if spilled > 0 and killer == self.ship then
        hud.message(L("Cargo scattered - scoop it before it drifts"), "info")
    end
    victim.dead = true
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


--- The weather over the ship, when it is low enough to be under any.
--
-- Sampled at a couple of hertz rather than every frame: fronts move over
-- kilometres and hours, so sixty evaluations a second of a noise field would
-- be sixty times the cost for an answer that has not changed.
function Flight:updateWeather(body)
    if not self.surface or not self.altitude or self.altitude > S.atmosphereHeight then
        self.weather = nil
        self.weatherTimer = 0
        return
    end
    self.weatherTimer = (self.weatherTimer or 0) - (self.lastDt or 0.016)
    if self.weather and self.weatherTimer > 0 then return end
    self.weatherTimer = 0.5

    local x, z = self.local_.pos.x, self.local_.pos.z
    local biome = self.surface.field:biomeAt(x, z)
    self.weather = weather.at(body, biome, x, z, self.world.day, self.weather)
    self.weatherBiome = biome
end




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
        autopilot = self.autopilot ~= nil,
        landed = self.landedOn ~= nil,
        gearDown = self.gearDown,
        dockPrompt = self.dockPrompt ~= nil,
        dockPromptIsPlace = self.dockPrompt and self.dockPrompt.place ~= nil,
        prompt = self.dockPrompt and self.dockPrompt.text or nil,
        objective = self.objective and self:objectiveText(self.objective) or nil,
        objectiveFlash = self.objectiveFlash,
        objectiveHint = self.objective and self:objectiveHint(self.objective) or nil,
        objectiveMarker = self.objectives and select(1, self.objectives:markerPos(self._objCtx)) and
            { self.objectives:markerPos(self._objCtx) } or nil,
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

--- Burns one shield cell to restore the shield.
--
-- The Shield Cell Bank granted `stats.shieldCells`, the player tracked and
-- saved the count, and nothing anywhere consumed one -- 34,000 credits for a
-- number that only ever went up.
function Flight:useShieldCell()
    if (self.player.shieldCells or 0) <= 0 then
        hud.message(L("No shield cells"), "warn")
        return
    end
    local maxShield = self.player.stats.maxShield or 0
    if self.player.shield >= maxShield - 0.5 then
        hud.message(L("Shield already full"), "warn")
        return
    end
    self.player.shieldCells = self.player.shieldCells - 1
    self.player.shield = min(maxShield, self.player.shield + maxShield * 0.6)
    self.ship.shield = self.player.shield
    -- the recharge dumps heat, so it is not free in a long fight
    self.heat = min(1, (self.heat or 0) + 0.18)
    hud.message(L("Shield cell fired ({n} left)", { n = self.player.shieldCells }), "good")
end

function Flight:fireMissile()
    if self.player.missiles <= 0 then
        hud.message(L("No missiles"), "warn")
        return
    end
    if not (self.target and self.target.entity) then
        hud.message(L("Missiles need a ship target"), "warn")
        return
    end
    self.player.missiles = self.player.missiles - 1
    local w = { weapon = { damage = 140, rate = 1, energy = 0, speed = config.combat.missileSpeed,
                           color = { 1, 0.8, 0.4 } } }
    combat.fire(self.arena, self.ship, w, self.ship.fwd.x, self.ship.fwd.y, self.ship.fwd.z, 0)
    hud.message(L("Missile away ({n} left)", { n = self.player.missiles }), "info")
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

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
local bodies = require("src.render.bodies")
local stationGen = require("src.procgen.stations")
local systemGen = require("src.procgen.system")
local Surface = require("src.procgen.surface")
local combat = require("src.sim.combat")
local npcMod = require("src.sim.npc")
local factions = require("src.sim.factions")
local equipment = require("src.sim.equipment")
local hud = require("src.render.hud")
local ui = require("src.ui.widgets")

local Flight = class("FlightState")

local sqrt, min, max, abs, floor = math.sqrt, math.min, math.max, math.abs, math.floor
local FL = config.flight
local S = config.scale
local C = palette.colors

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

    self:spawn(spawnOpts)
    self.game.camera.mode = self.game.camera.mode or "cockpit"
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
        hud.message("Launched from " .. opts.atPort.name, "info")
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
        hud.message("On the pad at " .. place.name, "info")
        return
    end

    -- default arrival: near the first planet, or by the star
    local target = nil
    for _, b in ipairs(sys.bodies) do
        if b.kind == "planet" then target = b break end
    end
    local d = target and (target.radius * 14) or (sys.star.radius * 8)
    local base = target and target.pos or sys.star.pos
    ship.pos:set(base.x + d, base.y + d * 0.25, base.z + d)
    local dx, dy, dz = vec3.normT(base.x - ship.pos.x, base.y - ship.pos.y, base.z - ship.pos.z)
    ship.fwd:set(dx, dy, dz)
    ship.up:set(0, 1, 0)
    mat4.orthonormalize(ship.right, ship.up, ship.fwd)
    ship.vel:set(0, 0, 0)
    self.throttle = 0
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
    hud.message(string.format("Approaching %s", body.name), "info")
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
    env.nebula = 1 - atmos
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
        env.fogAmount = util.clamp(atmos * 0.85, 0, 0.9)
        env.fogNear = util.lerp(20000, 1200, atmos)
        env.fogFar = util.lerp(60000, S.terrainViewRange * 1.1, atmos)
        env.ambient = {
            0.09 + day * 0.22 * base[1],
            0.10 + day * 0.22 * base[2],
            0.13 + day * 0.24 * base[3],
        }
        self.dayFactor = day
    else
        env.fogAmount = 0
        env.ambient = { 0.075, 0.08, 0.105 }
        self.dayFactor = 1
    end

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

function Flight:readRotation(dt, basis, agility)
    local pitch, yaw, roll = 0, 0, 0
    if config.down("pitchUp") then pitch = pitch + 1 end
    if config.down("pitchDown") then pitch = pitch - 1 end
    if config.down("yawLeft") then yaw = yaw - 1 end
    if config.down("yawRight") then yaw = yaw + 1 end
    if config.down("rollLeft") then roll = roll - 1 end
    if config.down("rollRight") then roll = roll + 1 end

    -- mouse steering when the pointer is captured
    if self.mouseSteer then
        pitch = pitch + util.clamp(-self.mouseDy * 0.06, -1, 1)
        yaw = yaw + util.clamp(self.mouseDx * 0.06, -1, 1)
        self.mouseDx, self.mouseDy = 0, 0
    end

    local a = self.ship.angular
    local rate = agility
    a.x = util.damp(a.x, pitch * FL.pitchRate * rate, FL.rotDamping, dt)
    a.y = util.damp(a.y, yaw * FL.yawRate * rate, FL.rotDamping, dt)
    a.z = util.damp(a.z, roll * FL.rollRate * rate, FL.rotDamping, dt)

    -- integrate: pitch about right, yaw about up, roll about forward
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
    local wants = config.down("warp")
    local ceiling, clearance = self:warpCeiling()
    self.massLocked = clearance < FL.warpMinAltitude

    if self.warpState == "off" then
        if wants and not self.landedOn then
            if self.massLocked then
                hud.message("Mass locked - too close to a surface", "warn")
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
        elseif self.warpSpool >= FL.warpSpoolTime then
            self.warpState = "cruise"
            self.warpSpeed = max(self.warpSpeed, FL.warpMinSpeed)
            hud.message("Frame shift engaged", "good")
        end
    else
        if not wants or self.massLocked then
            self.warpState = "off"
            self.warpSpeed = 0
            if self.massLocked then hud.message("Frame shift dropped - mass lock", "warn") end
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

    -- main drive
    local targetSpeed = topSpeed * self.throttle
    if self.throttle < 0 then targetSpeed = topSpeed * self.throttle * FL.reverseFactor end
    local along = vel.x * basis.fwd.x + vel.y * basis.fwd.y + vel.z * basis.fwd.z
    local delta = util.approach(along, targetSpeed, accel * dt) - along
    vel:addScaled(basis.fwd, delta)

    -- flight assist: bleed off sideways velocity so the ship goes where it points
    local assist = 1 - math.exp(-2.6 * dt)
    local lateralX = vel.x - basis.fwd.x * along
    local lateralY = vel.y - basis.fwd.y * along
    local lateralZ = vel.z - basis.fwd.z * along
    vel.x = vel.x - lateralX * assist
    vel.y = vel.y - lateralY * assist
    vel.z = vel.z - lateralZ * assist

    -- gravity and atmosphere
    if onSurface then
        vel.y = vel.y - self.gravity * dt
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
        if ui.blink(0.35) then hud.message("HULL OVERHEATING", "alert") end
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
                hud.message("Landed at " .. pad.settlement.place.name .. "  -  " ..
                    config.keyName("dock") .. " to enter, " .. config.keyName("disembark") .. " to disembark", "good")
            else
                self.landedPlace = nil
                hud.message("Touchdown  -  " .. config.keyName("disembark") .. " to disembark", "good")
            end
        end
    else
        -- impact
        local damage = max(0, speed - FL.landingSpeedMax) * 2.6 + (self.gearDown and 0 or 12)
        if damage > 1 then
            combat.damage(self.ship, damage, true, nil)
            self.game.camera:addShake(util.clamp(damage / 40, 0.1, 1.2))
            hud.message(string.format("Impact! -%d hull", floor(damage)), "alert")
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
                label = e.shipDef.roleName .. " [" .. faction.short .. "]",
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
                or (c.place and c.place == self.target.place) then
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
            t.detail2 = t.entity.scanned
                and string.format("cargo ~%s cr%s", util.money(t.entity.cargoValue),
                    t.entity.bounty > 0 and ("  -  bounty " .. util.money(t.entity.bounty)) or "")
                or "unscanned"
        elseif t.station then
            t.hull, t.shield = nil, nil
            t.detail = t.station.stationKindName .. " station"
            t.detail2 = factions.get(t.station.factionId).name
        elseif t.body then
            t.hull, t.shield = nil, nil
            t.detail = t.body.typeName or "moon"
            t.detail2 = t.body.landable and "landable" or "no surface"
        elseif t.place then
            t.hull, t.shield = nil, nil
            t.detail = "settlement on " .. (t.place.bodyName or "?")
            t.detail2 = string.format("pop %s", util.money(t.place.population))
        end
    end
end

function Flight:cycleTarget(hostileOnly)
    local best, bestIndex = nil, 0
    local startIndex = 0
    for i, c in ipairs(self.contacts) do
        if c == self.target then startIndex = i break end
    end
    local n = #self.contacts
    for k = 1, n do
        local i = ((startIndex + k - 1) % n) + 1
        local c = self.contacts[i]
        local ok = c.marker and c.distance < config.combat.scanRange * 4
        if hostileOnly then ok = ok and c.hostile end
        if ok then
            best, bestIndex = c, i
            break
        end
    end
    self.target = best
    if best then hud.message("Target: " .. (best.label or "?"), "info") end
end

function Flight:scanTarget()
    local t = self.target
    if not t then hud.message("No target", "warn") return end
    if t.distance > (self.player.stats.scanRange or config.combat.scanRange) then
        hud.message("Out of scanner range", "warn")
        return
    end
    if t.entity then
        t.entity.scanned = true
        self.player.record.scanned = self.player.record.scanned + 1
        hud.message(string.format("%s scanned - %s, %s cr cargo", t.entity.pilot,
            factions.get(t.entity.faction).name, util.money(t.entity.cargoValue)), "good")
    elseif t.body then
        self.world.player:addLog("Surveyed " .. t.body.name, self.world.day, "nav")
        hud.message(string.format("%s: %s, gravity %.1f m/s2, atmosphere %.2f atm",
            t.body.name, t.body.typeName or "moon", t.body.gravity or 0, t.body.atmosphere or 0), "good")
    else
        hud.message("Nothing to scan", "warn")
    end
end

-- ---------------------------------------------------------------------------
-- Docking and landing
-- ---------------------------------------------------------------------------

function Flight:updateDockPrompt()
    self.dockPrompt = nil
    if self.warpState == "cruise" then return end
    local ship = self.ship

    -- orbital stations
    for _, st in ipairs(self.world.system.stations) do
        local mesh = self:stationMesh(st)
        local mx, my, mz, nx, ny, nz = stationGen.mouthWorld(st, mesh)
        local dx, dy, dz = ship.pos.x - mx, ship.pos.y - my, ship.pos.z - mz
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < st.size * 0.55 then
            if st.derelict then
                self.dockPrompt = { text = st.name .. " is derelict - no docking control", station = st, blocked = true }
            elseif self.speed > 120 then
                self.dockPrompt = { text = "Slow to under 120 m/s to dock", station = st, blocked = true }
            else
                self.dockPrompt = {
                    text = string.format("%s to dock at %s", config.keyName("dock"), st.name),
                    station = st,
                }
            end
            return
        end
    end

    -- landed at a settlement pad
    if self.landedOn and self.landedPlace then
        self.dockPrompt = {
            text = string.format("%s to enter %s", config.keyName("dock"), self.landedPlace.name),
            place = self.landedPlace,
        }
        return
    end
    if self.landedOn then
        self.dockPrompt = {
            text = string.format("%s to disembark", config.keyName("disembark")),
            surface = true,
        }
    end
end

function Flight:dock()
    local p = self.dockPrompt
    if not p or p.blocked then return end
    local Port = require("src.states.port")
    local place = p.station or p.place
    if not place then return end
    -- Port itself files the arrival, so missions and fees are counted once
    self.player.hull = self.ship.hull
    self.player.shield = self.ship.shield
    hud.message((p.station and "Docked at " or "Entered ") .. place.name, "good")
    self.manager:push(Port.new(), place, { flight = self, docked = true })
end

function Flight:disembark()
    if not self.landedOn or not self.surface then
        hud.message("Land first", "warn")
        return
    end
    local OnFoot = require("src.states.onfoot")
    self.manager:push(OnFoot.new(), {
        surface = self.surface,
        flight = self,
        x = self.local_.pos.x,
        z = self.local_.pos.z + 12,
    })
end

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
    self.world:update(dt)
    if self.dying then return end

    self:updateEnvironment()
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
        self.surface:update(self.local_.pos.x, self.local_.pos.z, dt)
    end

    self:updateContacts()
    self:updateDockPrompt()

    self.player.hull = self.ship.hull
    self.player.shield = self.ship.shield

    self.game.camera:follow(self.ship, dt)
end

function Flight:onKill(victim, killer)
    if killer == self.ship then
        self.player.record.kills = self.player.record.kills + 1
        local faction = victim.faction
        if faction == "pirates" then
            local bounty = victim.bounty or config.combat.bountyPerKill
            self.player:earn(bounty)
            hud.message(string.format("Bounty claimed: %s cr", util.money(bounty)), "good")
            self.player:addReputation(self.world.system.factionId, 0.02)
        else
            -- killing a lawful ship is a crime where its owners have authority
            local fine = math.floor(1200 + (victim.stats.maxHull or 100) * 6)
            self.player:addBounty(faction, fine)
            hud.message(string.format("Bounty issued against you: %s cr", util.money(fine)), "alert")
            npcMod.alert(self.npcs, faction, self.ship.pos, 14000)
        end
        local missionsMod = require("src.sim.missions")
        local touched = missionsMod.recordKill(self.player, faction, victim.pilot)
        for _, m in ipairs(touched) do
            hud.message(string.format("%s  (%d/%d)", m.title, m.progress or 0, m.quantity), "good")
        end
    end
    victim.dead = true
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

function Flight:submitBodies(renderer)
    local sys = self.world.system
    local camPos = self.game.camera.pos
    local IDENT = self._identBasis or { right = vec3(1, 0, 0), up = vec3(0, 1, 0), fwd = vec3(0, 0, -1) }
    self._identBasis = IDENT

    -- star
    renderer:draw(bodies.star(sys.star), sys.star.pos, IDENT, {
        scale = sys.star.radius, emissive = 1, layer = renderer.LAYER_FAR,
    })

    for _, b in ipairs(sys.bodies) do
        if b.kind == "planet" then
            local dist = vec3.distance(b.pos, camPos)
            -- more segments when it fills the sky
            local detail = (dist < b.radius * 12) and 64 or 32
            local basis = self:bodyBasis(b)
            renderer:draw(bodies.planet(b, detail), b.pos, basis, { scale = b.radius })
            local atmo = bodies.atmosphere(b)
            if atmo then
                renderer:draw(atmo, b.pos, basis, {
                    scale = b.radius * (1 + S.atmosphereHeight / b.radius),
                    alpha = 0.55, additive = true, layer = renderer.LAYER_FAR,
                })
            end
            local rings = bodies.rings(b)
            if rings then
                renderer:draw(rings, b.pos, basis, { scale = b.radius })
            end
            for _, m in ipairs(b.moons) do
                renderer:draw(bodies.planet(m, 24), m.pos, self:bodyBasis(m), { scale = m.radius })
            end
        end
    end
end

--- Basis for a body, applying its spin about a polar axis tilted by
--- `axialTilt`.  The sphere mesh is generated pole-up, so `up` is that axis.
function Flight:bodyBasis(body)
    body._basis = body._basis or { right = vec3(), up = vec3(), fwd = vec3() }
    local b = body._basis
    local spin = body.spin or 0
    local tilt = body.axialTilt or 0
    local ct, st = math.cos(tilt), math.sin(tilt)
    local cs, ss = math.cos(spin), math.sin(spin)

    -- polar axis, tilted about X
    b.up:set(0, ct, st)
    -- an equatorial reference, rotated by the spin about that axis
    b.right:set(cs, st * ss, -ct * ss)
    -- our convention is right x up = -fwd (see mat4.orthonormalize)
    b.fwd:set(-ss, cs * st, -cs * ct)
    mat4.orthonormalize(b.right, b.up, b.fwd)
    return b
end

function Flight:submitStations(renderer)
    local IDENT = self._identBasis
    for _, st in ipairs(self.world.system.stations) do
        local mesh = self:stationMesh(st)
        local basis = st._basis or { right = vec3(), up = vec3(), fwd = vec3(0, 0, -1) }
        st._basis = basis
        local spin = st.spin or 0
        local axis = mesh.spin or { x = 0, y = 0, z = 1 }
        if axis.y == 1 then
            basis.right:set(math.cos(spin), 0, -math.sin(spin))
            basis.up:set(0, 1, 0)
            basis.fwd:set(-math.sin(spin), 0, -math.cos(spin))
        else
            basis.right:set(math.cos(spin), math.sin(spin), 0)
            basis.up:set(-math.sin(spin), math.cos(spin), 0)
            basis.fwd:set(0, 0, -1)
        end
        mat4.orthonormalize(basis.right, basis.up, basis.fwd)
        renderer:draw(mesh.model, st.pos, basis)
        if mesh.glowModel then
            renderer:draw(mesh.glowModel, st.pos, basis, { emissive = 1 })
        end
    end
end

function Flight:submitShips(renderer)
    for _, e in ipairs(self.npcs) do
        if not e.dead then
            renderer:draw(e.shipDef.model, e.pos, e)
            -- engine glow scales with throttle
            local glow = util.clamp(e.throttle, 0, 1)
            if glow > 0.05 and e.engines then
                for _, en in ipairs(e.engines) do
                    local x = e.pos.x + e.right.x * en.x + e.up.x * en.y - e.fwd.x * en.z
                    local y = e.pos.y + e.right.y * en.x + e.up.y * en.y - e.fwd.y * en.z
                    local z = e.pos.z + e.right.z * en.x + e.up.z * en.y - e.fwd.z * en.z
                    renderer:drawAt(combat.boltMesh(C.engine), x, y, z, {
                        scale = en.radius * (0.6 + glow), additive = true, alpha = 0.5 * glow,
                    })
                end
            end
        end
    end

    -- the player's own ship, in chase view only
    if self.game.camera.mode ~= "cockpit" then
        renderer:draw(self.player.shipDef.model, self.ship.pos, self.ship)
        local glow = util.clamp(self.throttle, 0, 1) + (self.boosting and 0.6 or 0)
        if glow > 0.05 then
            for _, en in ipairs(self.player.shipDef.engines) do
                local s = self.ship
                local x = s.pos.x + s.right.x * en.x + s.up.x * en.y - s.fwd.x * en.z
                local y = s.pos.y + s.right.y * en.x + s.up.y * en.y - s.fwd.y * en.z
                local z = s.pos.z + s.right.z * en.x + s.up.z * en.y - s.fwd.z * en.z
                renderer:drawAt(combat.boltMesh(self.boosting and C.engineHot or C.engine), x, y, z, {
                    scale = en.radius * (0.7 + glow * 1.1), additive = true, alpha = 0.6,
                })
            end
        end
    end
end

function Flight:submitEffects(renderer)
    local arena = self.arena
    for i = 1, arena.nProjectiles do
        local p = arena.projectiles[i]
        local basis = p._basis or { right = vec3(), up = vec3(), fwd = vec3() }
        p._basis = basis
        basis.fwd:copyFrom(p.dir)
        basis.up:set(0, 1, 0)
        mat4.orthonormalize(basis.right, basis.up, basis.fwd)
        renderer:draw(combat.boltMesh(p.color), p.pos, basis, {
            scale = p.scale, additive = true, emissive = 1,
        })
    end
    for i = 1, arena.nEffects do
        local e = arena.effects[i]
        local t = 1 - (e.life / e.maxLife)
        if e.kind == "explosion" then
            local s = e.size * (0.4 + t * 1.6)
            renderer:draw(combat.debrisMesh(), e.pos, nil, {
                scale = s, additive = true, alpha = (1 - t) * 0.9, emissive = 1,
            })
            for _, sh in ipairs(e.shards or {}) do
                local d = t * sh[4] * 8
                renderer:drawAt(combat.debrisMesh(),
                    e.pos.x + sh[1] * d, e.pos.y + sh[2] * d, e.pos.z + sh[3] * d, {
                        scale = sh[4] * (1 - t), additive = true, alpha = (1 - t) * 0.8, emissive = 1,
                    })
            end
        else
            renderer:draw(combat.boltMesh(e.color), e.pos, nil, {
                scale = e.size * (0.5 + t * 1.4), additive = true, alpha = 1 - t, emissive = 1,
            })
        end
    end
end

function Flight:draw(background)
    local renderer = self.game.renderer
    local camera = self.game.camera
    local w, h = renderer.width, renderer.height

    renderer:beginFrame(camera)
    self:submitBodies(renderer)
    self:submitStations(renderer)
    if self.surface then
        self.surface:draw(renderer, { nightGlow = self.nightGlow })
    end
    self:submitShips(renderer)
    self:submitEffects(renderer)

    local sys = self.world.system
    renderer:endFrame(function()
        self.game.sky:draw(camera, w, h, 1 - (renderer.env.atmos or 0) * 0.95)
        self.game.sky:drawSun(camera, sys.star.pos, w, h, sys.star.radius, sys.star.color, false)
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
        prompt = self.dockPrompt and self.dockPrompt.text or nil,
    }, w, h)

    if self.game.showHelp then self:drawHelp(w, h) end
end

function Flight:drawHelp(w, h)
    local lines = {
        { "Pitch / roll", "W S / A D" },
        { "Yaw", config.keyName("yawLeft") .. " " .. config.keyName("yawRight") },
        { "Throttle up / down", config.keyName("throttleUp") .. " / " .. config.keyName("throttleDown") },
        { "Full / cut throttle", config.keyName("throttleFull") .. " / " .. config.keyName("throttleZero") },
        { "Boost", "SHIFT" },
        { "Frame shift cruise (hold)", config.keyName("warp") },
        { "Fire", "SPACE" },
        { "Target next / scan", config.keyName("target") .. " / " .. config.keyName("scan") },
        { "Landing gear", config.keyName("landingGear") },
        { "Dock / enter", config.keyName("dock") },
        { "Disembark on foot", config.keyName("disembark") },
        { "Galaxy map", "TAB" },
        { "Mission log", config.keyName("missions") },
        { "Colonies", config.keyName("colony") },
        { "View (cockpit/chase)", config.keyName("view") },
        { "Save / load", "F5 / F9" },
        { "Wireframe / post / debug", "F2 / F4 / F3" },
    }
    local pw, ph = 380, #lines * 20 + 54
    local px, py = (w - pw) * 0.5, (h - ph) * 0.5
    ui.panel(px, py, pw, ph, "CONTROLS")
    for i, l in ipairs(lines) do
        ui.text(l[1], px + 22, py + 30 + (i - 1) * 20, C.uiText, "small")
        ui.textRight(l[2], px + pw - 22, py + 30 + (i - 1) * 20, C.uiPrimary, "small")
    end
    ui.textCenter("F1 to close", px + pw * 0.5, py + ph - 20, C.uiDim, "small")
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
            hud.message("Boost", "info")
        end
        return
    end
    if config.is("landingGear", key) then
        self.gearDown = not self.gearDown
        hud.message(self.gearDown and "Landing gear down" or "Landing gear up", "info")
        return
    end
    if config.is("target", key) then self:cycleTarget(false) return end
    if config.is("nextTarget", key) then self:cycleTarget(true) return end
    if config.is("scan", key) then self:scanTarget() return end
    if config.is("view", key) then
        self.game.camera.mode = (self.game.camera.mode == "cockpit") and "chase" or "cockpit"
        return
    end
    if config.is("dock", key) then self:dock() return end
    if config.is("disembark", key) then self:disembark() return end
    if config.is("map", key) then
        local Map = require("src.states.galaxymap")
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
    if config.is("save", key) then
        local ok, err = self.game:saveGame()
        hud.message(ok and "Game saved" or ("Save failed: " .. tostring(err)), ok and "good" or "alert")
        return
    end
    if config.is("load", key) then
        local ok, err = self.game:loadGame()
        if ok then
            self.manager:switch(Flight.new())
        else
            hud.message("Load failed: " .. tostring(err), "alert")
        end
        return
    end
    if key == "m" and self.target and self.target.entity and self.player.missiles > 0 then
        self.player.missiles = self.player.missiles - 1
        local w = { weapon = { damage = 140, rate = 1, energy = 0, speed = config.combat.missileSpeed,
                               color = { 1, 0.8, 0.4 } } }
        combat.fire(self.arena, self.ship, w, self.ship.fwd.x, self.ship.fwd.y, self.ship.fwd.z, 0)
        hud.message("Missile away (" .. self.player.missiles .. " left)", "info")
    end
end

function Flight:mousepressed(x, y, button)
    if button == 2 then
        self.mouseSteer = not self.mouseSteer
        love.mouse.setRelativeMode(self.mouseSteer)
        self.mouseDx, self.mouseDy = 0, 0
        hud.message(self.mouseSteer and "Mouse flight on" or "Mouse flight off", "info")
    end
end

function Flight:mousemoved(x, y, dx, dy)
    if self.mouseSteer then
        self.mouseDx = (self.mouseDx or 0) + dx * config.walk.mouseSens * 40
        self.mouseDy = (self.mouseDy or 0) + dy * config.walk.mouseSens * 40
    end
end

function Flight:wheelmoved(x, y)
    self.throttle = util.clamp(self.throttle + y * 0.1, -0.4, 1)
end

function Flight:resume()
    -- coming back from a docked screen: the ship may have been outfitted
    self.ship.stats = self.player.stats
    self.ship.hull = self.player.hull
    self.ship.shield = self.player.shield
    self.ship.shipDef = self.player.shipDef
    self.ship.radius = self.player.shipDef.radius
    self.ship.hardpoints = self.player.shipDef.hardpoints
end

function Flight:exit()
    if self.surface then self.surface:release() end
    if self.mouseSteer then love.mouse.setRelativeMode(false) end
end

return Flight

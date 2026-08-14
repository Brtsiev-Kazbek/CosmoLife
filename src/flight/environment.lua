-- What the world around the ship is doing, and what the renderer needs to know
-- about it.
--
-- Lighting, atmosphere, gravity, the surface handover, the nebula colour, the
-- sky tint and the weather overhead. This is the part of the flight state that
-- is about *where the ship is* rather than about what the pilot is doing, and
-- it changes for reasons the pilot has no say in.
--
-- `updateEnvironment` is also the surface handover: crossing
-- `config.scale.surfaceHandover` swaps the ship between absolute world
-- coordinates and a tangent frame on the body, which is what makes landing
-- seamless. States that borrow the environment without owning it -- on foot,
-- interiors -- pass `skipHandover` so the terrain patch is not swapped under
-- them.
--
-- The flight state arrives as an explicit first argument, as in the other
-- flight modules; `states/flight.lua` keeps forwarding methods.

local vec3 = require("src.lib.vec3")
local util = require("src.lib.util")
local config = require("src.config")
local systemGen = require("src.procgen.system")
local Surface = require("src.procgen.surface")
local settings = require("src.settings")
local weather = require("src.sim.weather")

local environment = {}

local sqrt, max, abs, floor = math.sqrt, math.max, math.abs, math.floor
local S = config.scale

--- Recomputes lighting, atmosphere and gravity for the ship's position.
-- `skipHandover` is passed by states that borrow the environment (on foot,
-- interiors) and must not have the terrain patch swapped under them.
function environment.updateEnvironment(f, skipHandover)
    local sys = f.world.system
    local ship = f.ship
    local env = f.game.renderer.env

    -- sun: direction light travels, from the star outward
    local sx = ship.pos.x - sys.star.pos.x
    local sy = ship.pos.y - sys.star.pos.y
    local sz = ship.pos.z - sys.star.pos.z
    local dx, dy, dz = vec3.normT(sx, sy, sz)
    env.sunDir:set(dx, dy, dz)
    env.sunColor = sys.star.color
    f.starDistance = sqrt(sx * sx + sy * sy + sz * sz)

    local body = systemGen.dominantBody(sys, ship.pos.x, ship.pos.y, ship.pos.z)
    f.nearBody = body
    local altitude, density = nil, 0

    if body then
        altitude = systemGen.altitude(body, ship.pos.x, ship.pos.y, ship.pos.z)
        f.altitude = altitude
        local up = vec3(ship.pos.x - body.pos.x, ship.pos.y - body.pos.y, ship.pos.z - body.pos.z):normalize()
        env.worldUp:copyFrom(up)
        f.upVec = up
        f.gravity = (body.gravity or 9) * (body.radius / max(body.radius + max(altitude, 0), 1)) ^ 2

        if (body.atmosphere or 0) > 0.03 then
            local scaleHeight = S.atmosphereHeight * 0.34
            density = (body.atmosphere or 0) * math.exp(-max(altitude, 0) / scaleHeight)
            density = util.clamp(density, 0, 2.2)
        end
    else
        f.altitude = nil
        f.gravity = 0
        env.worldUp:copyFrom(f.game.camera.up)
        f.upVec = nil
    end
    f.airDensity = density

    -- sky and fog follow the atmosphere and the sun angle
    local atmos = util.clamp(density * 1.1, 0, 1)
    env.atmos = atmos
    -- the preset's nebula weight was declared in all four quality tables and
    -- read by nothing
    env.nebula = (1 - atmos) * (settings.q().nebula or 1)
    if body and atmos > 0.01 then
        local sunUp = 0
        if f.upVec then
            sunUp = -(env.sunDir.x * f.upVec.x + env.sunDir.y * f.upVec.y + env.sunDir.z * f.upVec.z)
        end
        local day = util.clamp(sunUp * 2 + 0.2, 0, 1)
        local base = environment.skyTint(f, body)
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
        environment.updateWeather(f, body)
        local cond = f.weather
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
        f.dayFactor = day
    else
        env.fogAmount = 0
        env.ambient = { 0.075, 0.08, 0.105 }
        env.shadeFloor = 0.06
        -- Each system carries its own nebula palette, derived from its seed and
        -- warmed towards its star's colour, so jumping somewhere new actually
        -- looks like somewhere new instead of the same violet fog everywhere.
        env.zenith = environment.nebulaHue(f)
        f.dayFactor = 1
    end

    f.game:applyLighting()

    -- how bright the settlement windows should be
    f.nightGlow = util.clamp(1.25 - (f.dayFactor or 1) * 1.05, 0.18, 1.25)

    -- terrain handover
    if skipHandover then return end
    if body and body.landable and altitude and altitude < S.surfaceHandover then
        local lat, lon = systemGen.surfaceCoords(body, ship.pos.x, ship.pos.y, ship.pos.z)
        if not f.surface or f.surface.body ~= body then
            f:enterSurface(body, lat, lon)
        else
            -- re-origin when the ship has travelled far across the patch
            local x, _, z = f.surface:toLocal(ship.pos.x, ship.pos.y, ship.pos.z)
            if sqrt(x * x + z * z) > Surface.CHUNK * 5 then
                f.surface:setOrigin(lat, lon, body.settlements or {})
                f:syncToLocal()
            end
        end
    elseif f.surface and (not altitude or altitude > S.surfaceHandover * 1.35) then
        f:leaveSurface()
    end
end

--- The nebula hue for the current system, cached per system id.
function environment.nebulaHue(f)
    local id = f.world.stub and f.world.stub.id
    if f._hueId == id and f._hue then return f._hue end
    local Rng = require("src.lib.rng")
    local rng = Rng.new(f.world.stub and f.world.stub.seed or 1, "nebula")
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
    local star = f.world.system and f.world.system.star.color or { 1, 1, 1 }
    local k = rng:range(0.15, 0.4)
    f._hue = {
        h[1] * (1 - k) + star[1] * k * 0.5,
        h[2] * (1 - k) + star[2] * k * 0.5,
        h[3] * (1 - k) + star[3] * k * 0.5,
    }
    f._hueId = id
    return f._hue
end

--- False once the star has set behind the body we are standing on: the sun
--- sprite is drawn without depth, so it has to be culled by hand.
function environment.sunVisible(f)
    local body, up = f.nearBody, f.upVec
    if not body or not up then return true end
    local alt = f.altitude or 0
    if alt > body.radius then return true end
    -- how far below the horizontal the horizon sits at this altitude
    local dip = math.sqrt(math.max(2 * alt / body.radius, 0))
    local sunUp = -(f.game.renderer.env.sunDir.x * up.x
                  + f.game.renderer.env.sunDir.y * up.y
                  + f.game.renderer.env.sunDir.z * up.z)
    return sunUp > -dip - 0.02
end

function environment.skyTint(f, body)
    local t = body.type
    if t == "terran" then return { 0.42, 0.60, 0.95 } end
    if t == "ocean" then return { 0.36, 0.58, 0.92 } end
    if t == "desert" then return { 0.92, 0.72, 0.46 } end
    if t == "ice" then return { 0.66, 0.80, 0.95 } end
    if t == "volcanic" then return { 0.85, 0.42, 0.28 } end
    if t == "toxic" then return { 0.72, 0.85, 0.40 } end
    return { 0.55, 0.55, 0.60 }
end

--- The weather over the ship, when it is low enough to be under any.
--
-- Sampled at a couple of hertz rather than every frame: fronts move over
-- kilometres and hours, so sixty evaluations a second of a noise field would
-- be sixty times the cost for an answer that has not changed.
function environment.updateWeather(f, body)
    if not f.surface or not f.altitude or f.altitude > S.atmosphereHeight then
        f.weather = nil
        f.weatherTimer = 0
        return
    end
    f.weatherTimer = (f.weatherTimer or 0) - (f.lastDt or 0.016)
    if f.weather and f.weatherTimer > 0 then return end
    f.weatherTimer = 0.5

    local x, z = f.local_.pos.x, f.local_.pos.z
    local biome = f.surface.field:biomeAt(x, z)
    f.weather = weather.at(body, biome, x, z, f.world.day, f.weather)
    f.weatherBiome = biome
end
return environment

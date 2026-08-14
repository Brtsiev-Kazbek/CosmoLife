-- Celestial body meshes, cached per body seed.
--
-- Planets are unit spheres coloured by the *same* height field the ground uses
-- (see procgen.terrain), scaled up at draw time.  That is what makes the
-- descent honest: the brown wedge of desert you aimed at from orbit is the
-- desert you land in.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")
local palette = require("src.render.palette")
local terrain = require("src.procgen.terrain")
local noise = require("src.lib.noise")

local bodies = {}

local cos, sin, pi, floor = math.cos, math.sin, math.pi, math.floor
local TAU = pi * 2

local cache = {}
local order = {}

local function remember(key, value)
    cache[key] = value
    order[#order + 1] = key
    if #order > 120 then
        local old = table.remove(order, 1)
        local m = cache[old]
        if m and m.mesh and m.mesh.release then m.mesh:release() end
        cache[old] = nil
    end
    return value
end

-- ---------------------------------------------------------------------------

--- Unit sphere for a planet or moon, coloured from its terrain field.
function bodies.planet(body, detail)
    local segments = detail or 40
    local rings = floor(segments * 0.55)
    local key = string.format("p%s:%d", tostring(body.seed), segments)
    if cache[key] then return cache[key] end

    local b = MeshBuilder.new()
    if body.giant then
        -- gas giants get latitude bands and a storm spot instead of terrain
        local rng = Rng.new(body.seed, "giant")
        local base = rng:pick({
            palette.colors.sand, palette.colors.copper, palette.colors.hullLight,
            palette.colors.teal, palette.colors.rockDry, palette.colors.hullBright,
        })
        local bandCount = rng:int(7, 14)
        local bands = {}
        for i = 1, bandCount do
            bands[i] = palette.shade(base, 0.7 + (i % 3) * 0.14 + rng:range(-0.06, 0.06))
        end
        local spotLat = rng:range(-0.5, 0.5)
        local spotLon = rng:range(0, TAU)
        geometry.sphere(b, 1.0, segments, rings, function(_, u, v)
            local lat = (v - 0.5) * pi
            local band = bands[(floor((v * bandCount) % bandCount)) + 1]
            local lon = u * TAU
            local dl = math.abs(((lon - spotLon + pi) % TAU) - pi)
            if dl < 0.35 and math.abs(lat - spotLat) < 0.16 then
                return palette.mix(band, palette.colors.rust, 0.7)
            end
            return band
        end)
    else
        local field = terrain.field(body)
        geometry.sphere(b, 1.0, segments, rings, function(_, u, v)
            local lat = (v - 0.5) * pi
            local lon = u * TAU
            local cl = cos(lat)
            local dx, dy, dz = cl * cos(lon), sin(lat), cl * sin(lon)
            local h = field:heightDir(dx, dy, dz)
            -- the same biome question the ground asks, so the wedge of desert
            -- aimed at from orbit is the desert that gets landed in
            return field:colorDir(dx, dy, dz, h)
        end)
    end
    return remember(key, b:build())
end

--- The colour a body's air scatters.
function bodies.airTint(body)
    local kind = body.terrain or body.type
    if kind == "toxic" then return palette.colors.moss end
    if kind == "ice" then return palette.colors.rockIce end
    if kind == "volcanic" then return palette.colors.orange end
    if kind == "desert" then return palette.colors.ochre end
    if body.giant then return palette.colors.hullLight end
    return palette.colors.blue
end

--- Atmosphere shell, drawn additively just outside the surface.
--
-- The mesh is only a sphere: the scattering -- limb brightening, the day/night
-- falloff and the warm terminator band -- is in the `u_shell` branch of
-- flat3d, because all three depend on where the camera is and a baked mesh
-- cannot know that. It is finer than it used to be because the limb is now a
-- gradient across the silhouette rather than a flat wash, and a coarse sphere
-- showed that gradient as facets.
function bodies.atmosphere(body)
    if not body.atmosphere or body.atmosphere <= 0.03 then return nil end
    local key = "a" .. tostring(body.seed)
    if cache[key] then return cache[key] end
    local tint = bodies.airTint(body)
    local a = util.clamp(0.30 + body.atmosphere * 0.45, 0.24, 0.78)
    local col = { tint[1], tint[2], tint[3], a }
    local b = MeshBuilder.new()
    geometry.sphere(b, 1.0, 48, 26, col)
    return remember(key, b:build())
end

--- A cloud deck: only the cloudy cells of a lat/lon grid, as a shell.
--
-- Worlds with air had none, so an ocean world and a bare rock had the same
-- silhouette from orbit. The cover comes from the same kind of domain-warped
-- fbm the terrain uses, so the bands stretch out east-west the way weather
-- does on a spinning planet, and only the cells above the cover threshold
-- become geometry -- a clear sky costs nothing to draw.
function bodies.clouds(body)
    if body.giant then return nil end
    local air = body.atmosphere or 0
    if air <= 0.25 then return nil end
    local key = "cl" .. tostring(body.seed)
    if cache[key] ~= nil then return cache[key] or nil end

    local seed = (body.seed or 1) + 5501
    local cols, rows = 96, 48
    -- how much of the sky is covered, from the thickness of the air
    local threshold = util.lerp(0.62, 0.30, util.clamp((air - 0.25) / 1.2, 0, 1))
    local b = MeshBuilder.new()
    local any = false

    local function cover(lat, lon)
        local cl = cos(lat)
        local dx, dy, dz = cl * cos(lon), sin(lat), cl * sin(lon)
        -- stretched east-west: banded weather, not round blobs
        local n = noise.fbm3(seed, dx * 2.2, dy * 5.5, dz * 2.2, 4, 2.1, 0.55) * 0.5 + 0.5
        local warp = noise.perlin3(seed + 31, dx * 1.1, dy * 2.0, dz * 1.1) * 0.35
        n = n + warp
        -- thinner over the poles and along the equator, as on a real world
        n = n - math.abs(math.abs(lat) - 0.62) * 0.22
        return n
    end

    local white = palette.colors.white
    for j = 0, rows - 1 do
        local lat0 = (j / rows - 0.5) * pi
        local lat1 = ((j + 1) / rows - 0.5) * pi
        for i = 0, cols - 1 do
            local lon0 = i / cols * TAU
            local lon1 = (i + 1) / cols * TAU
            local c = cover((lat0 + lat1) * 0.5, (lon0 + lon1) * 0.5)
            if c > threshold then
                -- denser cloud is brighter and more opaque
                local t = util.clamp((c - threshold) / 0.22, 0, 1)
                local col = { white[1], white[2], white[3], 0.10 + t * 0.30 }
                local function p(lat, lon)
                    local cl = cos(lat)
                    return cl * cos(lon), sin(lat), cl * sin(lon)
                end
                local ax, ay, az = p(lat0, lon0)
                local bx, by, bz = p(lat0, lon1)
                local cx, cy, cz = p(lat1, lon1)
                local dx2, dy2, dz2 = p(lat1, lon0)
                b:tri(ax, ay, az, bx, by, bz, cx, cy, cz, col)
                b:tri(ax, ay, az, cx, cy, cz, dx2, dy2, dz2, col)
                any = true
            end
        end
    end
    if not any then
        cache[key] = false
        return nil
    end
    return remember(key, b:build())
end

--- Ring system as a flat annulus of coloured bands.
function bodies.rings(body)
    if not body.hasRings then return nil end
    local key = "r" .. tostring(body.seed)
    if cache[key] then return cache[key] end
    local rng = Rng.new(body.seed, "rings")
    local b = MeshBuilder.new()
    local inner = 1.45
    local outer = rng:range(2.1, 3.2)
    local bands = rng:int(6, 14)
    local segs = 64
    local base = palette.shade(rng:pick({
        palette.colors.rockIce, palette.colors.sand, palette.colors.hullLight,
    }), 1.0)
    for k = 0, bands - 1 do
        local r0 = inner + (outer - inner) * (k / bands)
        local r1 = inner + (outer - inner) * ((k + 0.86) / bands)
        local col = palette.shade(base, 0.55 + rng:float() * 0.6)
        col = { col[1], col[2], col[3], 0.55 + rng:float() * 0.4 }
        for i = 0, segs - 1 do
            local a0, a1 = i / segs * TAU, (i + 1) / segs * TAU
            b:quad(cos(a0) * r0, 0, sin(a0) * r0,
                   cos(a1) * r0, 0, sin(a1) * r0,
                   cos(a1) * r1, 0, sin(a1) * r1,
                   cos(a0) * r1, 0, sin(a0) * r1, col)
        end
    end
    return remember(key, b:build())
end

--- The star itself: a unit sphere in its own colour, drawn unlit.
function bodies.star(star)
    local key = "s" .. tostring(star.class)
    if cache[key] then return cache[key] end
    local b = MeshBuilder.new()
    local col = { star.color[1], star.color[2], star.color[3], 1 }
    geometry.sphere(b, 1.0, 32, 18, function(_, u, v)
        -- faint granulation so the disc is not a flat circle
        local n = ((floor(u * 24) + floor(v * 16)) % 3) * 0.03
        return { col[1] - n, col[2] - n * 0.9, col[3] - n * 0.7, 1 }
    end)
    return remember(key, b:build())
end

--- A handful of asteroid shapes, reused across a belt.
function bodies.asteroids(seed)
    local key = "ast" .. tostring(seed)
    if cache[key] then return cache[key] end
    local set = {}
    for i = 1, 5 do
        local rng = Rng.new(seed, "rock", i)
        local b = MeshBuilder.new()
        local col = rng:pick({
            palette.colors.rockGrey, palette.colors.rockDry, palette.colors.ash,
            palette.colors.rockRed, palette.colors.hullDark,
        })
        geometry.rock(b, 1.0, rng:int(8, 12), rng:int(6, 9), rng, rng:range(0.22, 0.42), function(i2)
            return (i2 % 7 == 0) and palette.shade(col, 1.25) or col
        end)
        set[i] = b:build()
    end
    cache[key] = set
    order[#order + 1] = key
    return set
end

--- Distant marker for a settlement seen from orbit: a cluster of lit points.
function bodies.settlementGlow()
    local key = "sglow"
    if cache[key] then return cache[key] end
    local b = MeshBuilder.new()
    geometry.sphere(b, 1.0, 8, 5, { 1.0, 0.85, 0.55, 1 })
    return remember(key, b:build())
end

--- A cargo canister: a stubby ribbed drum with a coloured band, drawn at unit
--- radius and scaled at draw time.
function bodies.canister()
    local key = "canister"
    if cache[key] then return cache[key] end
    local b = MeshBuilder.new()
    local C = palette.colors
    -- body
    geometry.cylinder(b, 0.55, 1.6, 10, C.hull, palette.shade(C.hull, 0.8), 1, true)
    -- end caps, darker so the shape reads end-on as well as side-on
    for _, y in ipairs({ -0.82, 0.82 }) do
        b:push():translate(0, y, 0)
        geometry.cylinder(b, 0.62, 0.14, 10, C.hullDark, C.steel, 1, true)
        b:pop()
    end
    -- hazard band around the middle
    b:push():translate(0, 0, 0)
    geometry.cylinder(b, 0.58, 0.34, 10, C.amber, palette.shade(C.amber, 0.7), 1, false)
    b:pop()
    return remember(key, b:build())
end

--- A cube of falling particles, for rain, snow and blown dust.
--
-- One mesh, drawn once, moved as a whole: the cube is `SIZE` metres on a side
-- and is drawn centred on the camera with an offset that wraps at `SIZE`, so
-- the particles fall continuously and the seam never arrives. Animating them
-- individually would need either a shader or a rebuilt mesh every frame, and
-- neither buys anything a wrapping cube does not already give.
--
-- `long` stretches each particle into a streak, which is the difference
-- between rain and snow at a glance.
function bodies.precipitation(long)
    local key = long and "precipL" or "precipS"
    if cache[key] then return cache[key] end
    local rng = Rng.new(9182, "precip", long and 1 or 0)
    local b = MeshBuilder.new()
    local SIZE = bodies.PRECIP_SIZE
    local n = 520
    local col = { 1, 1, 1, 1 }
    for _ = 1, n do
        local x = rng:range(-SIZE * 0.5, SIZE * 0.5)
        local y = rng:range(-SIZE * 0.5, SIZE * 0.5)
        local z = rng:range(-SIZE * 0.5, SIZE * 0.5)
        local w = long and 0.05 or 0.11
        local h = long and rng:range(0.9, 2.2) or rng:range(0.1, 0.22)
        -- a two-triangle sliver; it is always seen against the sky or the
        -- ground, never end-on for long enough to matter
        b:quad(x - w, y, z, x + w, y, z, x + w, y + h, z, x - w, y + h, z, col)
        b:quad(x, y, z - w, x, y, z + w, x, y + h, z + w, x, y + h, z - w, col)
    end
    return remember(key, b:build())
end

bodies.PRECIP_SIZE = 70

function bodies.clear()
    for _, m in pairs(cache) do
        if m and m.mesh and m.mesh.release then m.mesh:release() end
    end
    cache, order = {}, {}
end

return bodies

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
            local h = field:heightDir(cl * cos(lon), sin(lat), cl * sin(lon))
            return field:colorForHeight(h, lat)
        end)
    end
    return remember(key, b:build())
end

--- Translucent atmosphere shell, drawn additively just outside the surface.
function bodies.atmosphere(body)
    if not body.atmosphere or body.atmosphere <= 0.03 then return nil end
    local key = "a" .. tostring(body.seed)
    if cache[key] then return cache[key] end
    local rng = Rng.new(body.seed, "atmos")
    local tint
    if body.type == "toxic" then tint = palette.colors.moss
    elseif body.type == "ice" then tint = palette.colors.rockIce
    elseif body.type == "volcanic" then tint = palette.colors.orange
    elseif body.giant then tint = palette.colors.hullLight
    else tint = palette.colors.blue end
    local a = util.clamp(0.10 + body.atmosphere * 0.10, 0.06, 0.30)
    local col = { tint[1], tint[2], tint[3], a }
    local b = MeshBuilder.new()
    geometry.sphere(b, 1.0, 28, 16, col)
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

function bodies.clear()
    for _, m in pairs(cache) do
        if m and m.mesh and m.mesh.release then m.mesh:release() end
    end
    cache, order = {}, {}
end

return bodies

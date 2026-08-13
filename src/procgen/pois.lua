-- Points of interest.
--
-- Empty space between planets is honest but boring, so this module scatters
-- things worth flying to: asteroid clusters, derelict hulks, drifting cargo,
-- nav beacons. They are placed deterministically from the system seed on a
-- coarse grid, and only the cells near the player are ever built -- the same
-- trick the galaxy uses, one scale down. Nothing is stored, so a system can
-- have thousands of them and cost nothing until you fly there.
--
-- Surface points of interest work the same way over a planet's tangent frame:
-- crash sites, ruins, monoliths and abandoned mining claims, so a landing far
-- from any settlement still finds something.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")
local palette = require("src.render.palette")
local ships = require("src.procgen.ships")
local buildings = require("src.procgen.buildings")

local pois = {}

local C = palette.colors
local floor, sqrt, cos, sin = math.floor, math.sqrt, math.cos, math.sin
local TAU = math.pi * 2

-- Space is diced into cells this big; each may hold one point of interest.
local CELL = 26000
local VIEW_CELLS = 2          -- how many cells around the player to consider

pois.SPACE_KINDS = {
    { id = "asteroids", weight = 42, name = "Asteroid cluster", scan = "minerals" },
    { id = "derelict",  weight = 16, name = "Derelict",         scan = "salvage" },
    { id = "cargo",     weight = 18, name = "Cargo canister",   scan = "cargo" },
    { id = "beacon",    weight = 10, name = "Nav beacon",       scan = "data" },
    { id = "debris",    weight = 14, name = "Debris field",     scan = "salvage" },
}

pois.SURFACE_KINDS = {
    { id = "crash",    weight = 26, name = "Crash site" },
    { id = "ruins",    weight = 22, name = "Ruins" },
    { id = "monolith", weight = 12, name = "Monolith" },
    { id = "claim",    weight = 24, name = "Mining claim" },
    { id = "arch",     weight = 16, name = "Rock arch" },
}

local function pickKind(rng, list)
    local total = 0
    for _, k in ipairs(list) do total = total + k.weight end
    local r = rng:float() * total
    for _, k in ipairs(list) do
        r = r - k.weight
        if r <= 0 then return k end
    end
    return list[#list]
end

-- ---------------------------------------------------------------------------
-- Meshes (built once, reused by every instance of a kind)
-- ---------------------------------------------------------------------------

local meshCache = {}

local function cached(key, build)
    if meshCache[key] == nil then meshCache[key] = build() or false end
    return meshCache[key] or nil
end

--- A hulk: a ship hull, broken and unlit.
local function derelictMesh(seed)
    return cached("derelict" .. (seed % 8), function()
        local rng = Rng.new(seed, "derelict")
        local def = ships.generate(seed, rng:pick({ "hauler", "trader", "freighter", "gunship" }))
        return def.model
    end)
end

local function cargoMesh()
    return cached("cargo", function()
        local b = MeshBuilder.new()
        -- a canister: octagonal drum with end caps and a stripe
        geometry.cylinder(b, 1.2, 3.0, 8, C.steel, C.hullDark, 1, true)
        b:push():translate(0, 1.5, 0)
        geometry.cylinder(b, 1.28, 0.35, 8, C.hazard, C.hazard, 1, false)
        b:pop()
        b:push():translate(0, 0.4, 0)
        geometry.cylinder(b, 1.26, 0.25, 8, C.rust, C.rust, 1, false)
        b:pop()
        return b:build()
    end)
end

local function beaconMesh()
    return cached("beacon", function()
        local b = MeshBuilder.new()
        geometry.truss(b, 3.0, 16, 5, 0.25, C.hullLight)
        b:push():translate(0, 16, 0)
        geometry.sphere(b, 2.2, 10, 6, C.hullBright)
        b:pop()
        for i = 0, 3 do
            local a = i / 4 * TAU
            b:push():translate(cos(a) * 3.4, 6, sin(a) * 3.4)
            b:rotateZ(cos(a) * 0.5)
            geometry.box(b, 0.4, 5, 2.6, C.darkBlue)
            b:pop()
        end
        return b:build()
    end)
end

local function beaconGlowMesh()
    return cached("beaconGlow", function()
        local b = MeshBuilder.new()
        b:push():translate(0, 18.4, 0)
        geometry.sphere(b, 1.1, 8, 5, C.cyan)
        b:pop()
        return b:build()
    end)
end

local function debrisMesh(seed)
    return cached("debris" .. (seed % 6), function()
        local rng = Rng.new(seed, "debris")
        local b = MeshBuilder.new()
        for _ = 1, rng:int(10, 22) do
            b:push()
            b:translate(rng:range(-70, 70), rng:range(-40, 40), rng:range(-70, 70))
            b:rotateY(rng:range(0, TAU))
            b:rotateX(rng:range(0, TAU))
            local s = rng:range(1.2, 6)
            if rng:bool(0.5) then
                geometry.box(b, s, s * rng:range(0.3, 1.4), s * rng:range(0.6, 2.4),
                    rng:pick({ C.hullDark, C.steel, C.rust, C.hull }))
            else
                geometry.rock(b, s * 0.8, 7, 5, rng, 0.4, C.rockGrey)
            end
            b:pop()
        end
        return b:build()
    end)
end

local function asteroidClusterMesh(seed)
    return cached("rocks" .. (seed % 10), function()
        local rng = Rng.new(seed, "cluster")
        local b = MeshBuilder.new()
        local n = rng:int(8, 18)
        for _ = 1, n do
            b:push()
            b:translate(rng:range(-260, 260), rng:range(-120, 120), rng:range(-260, 260))
            b:rotateY(rng:range(0, TAU))
            b:rotateX(rng:range(0, TAU))
            local col = rng:pick({ C.rockGrey, C.rockDry, C.ash, C.rockRed })
            geometry.rock(b, rng:range(12, 52), rng:int(8, 11), rng:int(6, 8), rng, 0.35,
                function(i) return (i % 9 == 0) and palette.shade(col, 1.3) or col end)
            b:pop()
        end
        return b:build()
    end)
end

-- ---------------------------------------------------------------------------
-- Space
-- ---------------------------------------------------------------------------

--- The point of interest in a cell, or nil. Pure function of the seed.
function pois.spaceAt(systemSeed, cx, cy, cz)
    local h = Rng.hashf(systemSeed, cx, cy, cz, "poi")
    if h > 0.30 then return nil end        -- most cells are empty; space is big
    local rng = Rng.new(systemSeed, cx, cy, cz, "poi")
    local kind = pickKind(rng, pois.SPACE_KINDS)
    return {
        kind = kind.id,
        name = kind.name,
        seed = Rng.hash(systemSeed, cx, cy, cz),
        x = (cx + rng:float()) * CELL,
        y = (cy + rng:float()) * CELL * 0.35,
        z = (cz + rng:float()) * CELL,
        spin = rng:range(0, TAU),
        spinRate = rng:range(-0.15, 0.15),
        scale = rng:range(0.7, 1.5),
        value = floor(rng:range(200, 4200)),
    }
end

--- Every point of interest near a world position.
function pois.near(systemSeed, x, y, z, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local cx0, cy0, cz0 = floor(x / CELL), floor(y / (CELL * 0.35)), floor(z / CELL)
    for dz = -VIEW_CELLS, VIEW_CELLS do
        for dy = -1, 1 do
            for dx = -VIEW_CELLS, VIEW_CELLS do
                local p = pois.spaceAt(systemSeed, cx0 + dx, cy0 + dy, cz0 + dz)
                if p then out[#out + 1] = p end
            end
        end
    end
    return out
end

--- Mesh and draw options for a space point of interest.
function pois.spaceMesh(p)
    if p.kind == "asteroids" then return asteroidClusterMesh(p.seed), nil
    elseif p.kind == "derelict" then return derelictMesh(p.seed), nil
    elseif p.kind == "cargo" then return cargoMesh(), nil
    elseif p.kind == "beacon" then return beaconMesh(), beaconGlowMesh()
    elseif p.kind == "debris" then return debrisMesh(p.seed), nil end
    return nil
end

pois.CELL = CELL

-- ---------------------------------------------------------------------------
-- Surfaces
-- ---------------------------------------------------------------------------

local SURFACE_CELL = 9000

--- The surface point of interest in a tangent-plane cell, or nil.
function pois.surfaceAt(bodySeed, cx, cz)
    local h = Rng.hashf(bodySeed, cx, cz, "spoi")
    if h > 0.22 then return nil end
    local rng = Rng.new(bodySeed, cx, cz, "spoi")
    local kind = pickKind(rng, pois.SURFACE_KINDS)
    return {
        kind = kind.id,
        name = kind.name,
        seed = Rng.hash(bodySeed, cx, cz),
        x = (cx + rng:float()) * SURFACE_CELL,
        z = (cz + rng:float()) * SURFACE_CELL,
        rot = rng:range(0, TAU),
        radius = 60,
    }
end

--- Builds the mesh for a surface point of interest, in local ground space.
function pois.surfaceMesh(p)
    return cached("s" .. p.kind .. (p.seed % 6), function()
        local rng = Rng.new(p.seed, "spoi-mesh")
        local b = MeshBuilder.new()
        local g = MeshBuilder.new()

        if p.kind == "crash" then
            -- a broken hull half buried, with a debris trail
            local def = ships.generate(p.seed, rng:pick({ "trader", "hauler", "shuttle" }))
            b:push()
            b:translate(0, -def.radius * 0.35, 0)
            b:rotateZ(rng:range(0.3, 0.8))
            b:rotateY(rng:range(0, TAU))
            b:append({ n = 0, verts = {} })         -- keep the transform stack honest
            b:pop()
            -- scattered plating rather than the whole ship, so it reads as wreckage
            for _ = 1, rng:int(9, 18) do
                b:push()
                b:translate(rng:range(-40, 40), 0, rng:range(-40, 40))
                b:rotateY(rng:range(0, TAU))
                b:rotateX(rng:range(-0.5, 0.5))
                geometry.box(b, rng:range(2, 9), rng:range(0.3, 1.2), rng:range(2, 12),
                    rng:pick({ C.hullDark, C.steel, C.rust }))
                b:pop()
            end
            b:push():translate(0, 0, 0)
            geometry.frustumBox(b, 16, 9, 9, 5, 7, C.hullDark, C.rust, { 3, 1 })
            b:pop()
            g:push():translate(0, 4, 4.6)
            geometry.box(g, 4, 1.2, 0.3, C.orange)
            g:pop()

        elseif p.kind == "ruins" then
            -- weathered walls: a rectangle of broken pillars
            local w, d = rng:range(26, 50), rng:range(20, 40)
            for i = 0, 11 do
                local a = i / 12 * TAU
                local x, z = cos(a) * w * 0.5, sin(a) * d * 0.5
                if rng:bool(0.75) then
                    b:push():translate(x, 0, z)
                    geometry.cylinder(b, rng:range(0.7, 1.4), rng:range(2, 8), 7,
                        C.rockDry, C.rockGrey, rng:range(0.6, 1.0), true)
                    b:pop()
                end
            end
            b:push():translate(0, 0, 0)
            geometry.extrude(b, geometry.rect(w * 0.6, d * 0.6), 0, 0.8, C.rockGrey, C.rockDry)
            b:pop()
            for _ = 1, rng:int(3, 7) do
                b:push():translate(rng:range(-w * 0.5, w * 0.5), 0, rng:range(-d * 0.5, d * 0.5))
                b:rotateY(rng:range(0, TAU))
                geometry.box(b, rng:range(2, 6), rng:range(0.4, 1.2), rng:range(2, 5), C.rockDry)
                b:pop()
            end

        elseif p.kind == "monolith" then
            local h = rng:range(18, 46)
            b:push()
            b:rotateY(rng:range(0, TAU))
            b:rotateZ(rng:range(-0.12, 0.12))
            geometry.frustumBox(b, 7, 3.5, 5, 2.4, h, C.hullDark, C.black)
            b:pop()
            geometry.cylinder(b, 9, 0.6, 8, C.rockGrey, C.rockDry, 1, true)
            g:push():translate(0, h * 0.6, 1.9)
            geometry.box(g, 2.2, h * 0.3, 0.2, C.plasma)
            g:pop()

        elseif p.kind == "claim" then
            -- an abandoned mining claim: a rig, spoil and a beacon
            local info = buildings.build(b, "mine", rng, {
                glow = g, tier = 1, tech = 3,
                colors = buildings.colorScheme(rng, { wall = C.rust, trim = C.hullDark }),
            })
            p.radius = math.max(p.radius, info.radius or 60)

        else -- arch
            local span = rng:range(30, 70)
            local segs = 9
            for i = 0, segs - 1 do
                local t0, t1 = i / segs * math.pi, (i + 1) / segs * math.pi
                local x0, y0 = cos(t0) * span * 0.5, sin(t0) * span * 0.55
                local x1, y1 = cos(t1) * span * 0.5, sin(t1) * span * 0.55
                geometry.beam(b, x0, y0, 0, x1, y1, 0, rng:range(5, 11), C.rockDry)
            end
        end

        local model = b:build()
        local glow = g:build()
        return { model = model, glowModel = glow }
    end)
end

--- Surface points of interest near a local point.
function pois.surfaceNear(bodySeed, x, z, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local cx0, cz0 = floor(x / SURFACE_CELL), floor(z / SURFACE_CELL)
    for dz = -1, 1 do
        for dx = -1, 1 do
            local p = pois.surfaceAt(bodySeed, cx0 + dx, cz0 + dz)
            if p then out[#out + 1] = p end
        end
    end
    return out
end

pois.SURFACE_CELL = SURFACE_CELL

return pois

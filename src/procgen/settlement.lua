-- Settlement layout.
--
-- A settlement is generated once as two baked meshes -- solid structure and
-- emissive glass/signage -- in a local tangent frame where +X is east, +Z is
-- north and Y is up from the landing plaza.  Baking the whole town into two
-- draw calls is what lets a detailed city sit on a planet surface at a
-- playable frame rate.
--
-- Layout algorithm:
--   1. reserve the landing pads (the player must always be able to set down),
--   2. lay a ring road plus radial spurs,
--   3. scatter buildings by rejection sampling along the roads, biggest
--      first, respecting each other's footprint radius,
--   4. fill the leftover space with utility sheds, lamps, crates and fencing.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")
local palette = require("src.render.palette")
local buildings = require("src.procgen.buildings")
local names = require("src.procgen.names")

local settlement = {}

local cos, sin, pi, sqrt, max, min, floor = math.cos, math.sin, math.pi, math.sqrt, math.max, math.min, math.floor
local TAU = pi * 2
local C = palette.colors

-- ---------------------------------------------------------------------------
-- Ground furniture
-- ---------------------------------------------------------------------------

local function landingPad(b, g, r, rng, colors, index)
    -- apron
    geometry.cylinder(b, r * 1.12, 0.22, 12, palette.shade(C.hullDark, 1.0), palette.shade(C.hullDark, 1.15), 1, true)
    geometry.cylinder(b, r, 0.30, 12, palette.shade(C.steel, 0.7), palette.shade(C.steel, 0.85), 1, true)
    -- hazard chevrons around the rim
    for i = 0, 11 do
        local a = i / 12 * TAU
        b:push():translate(cos(a) * r * 0.88, 0.31, sin(a) * r * 0.88)
        b:rotateY(-a)
        geometry.box(b, r * 0.22, 0.04, r * 0.1, (i % 2 == 0) and C.hazard or C.black)
        b:pop()
    end
    -- centre marking
    b:push():translate(0, 0.32, 0)
    geometry.cylinder(b, r * 0.42, 0.03, 12, C.hazard, C.hazard, 1, true)
    geometry.cylinder(b, r * 0.30, 0.05, 12, palette.shade(C.steel, 0.7), palette.shade(C.steel, 0.7), 1, true)
    b:pop()
    -- approach lights
    for i = 0, 7 do
        local a = i / 8 * TAU
        local x, z = cos(a) * r * 1.2, sin(a) * r * 1.2
        b:push():translate(x, 0, z)
        geometry.cylinder(b, 0.14, 1.1, 5, colors.trim, colors.trim, 1, true)
        b:pop()
        g:push():translate(x, 1.2, z)
        geometry.sphere(g, 0.22, 6, 4, (i % 2 == 0) and C.lamp or C.cyan)
        g:pop()
    end
    -- pad number
    g:push():translate(0, 0.34, -r * 0.6)
    g:rotateX(-pi * 0.5)
    for k = 1, min(index, 6) do
        g:push():translate((k - (min(index, 6) + 1) * 0.5) * 1.3, 0, 0)
        geometry.box(g, 0.5, 0.05, 2.2, C.hazard)
        g:pop()
    end
    g:pop()
    -- service arm
    b:push():translate(r * 1.25, 0, 0)
    geometry.truss(b, 1.2, 7, 3, 0.08, colors.trim)
    b:push():translate(0, 7, 0)
    b:rotateZ(0.5)
    geometry.cylinder(b, 0.3, r * 0.8, 6, colors.accent, colors.accent, 0.6, true)
    b:pop()
    b:pop()
end

local function road(b, x0, z0, x1, z1, width, col)
    local dx, dz = x1 - x0, z1 - z0
    local len = sqrt(dx * dx + dz * dz)
    if len < 0.5 then return end
    local a = math.atan2 and math.atan2(dx, dz) or math.atan(dx / (dz == 0 and 1e-9 or dz))
    b:push()
    b:translate((x0 + x1) * 0.5, 0.06, (z0 + z1) * 0.5)
    b:rotateY(a)
    geometry.slab(b, width, len, 0, col)
    -- centre line
    local dashes = max(1, floor(len / 4))
    for i = 0, dashes - 1 do
        b:push():translate(0, 0.02, -len * 0.5 + len * (i + 0.5) / dashes)
        geometry.slab(b, width * 0.06, 1.6, 0, palette.shade(C.hazard, 0.9))
        b:pop()
    end
    b:pop()
end

local function streetLamp(b, g, x, z, rng, colors)
    local h = rng:range(4.5, 7)
    b:push():translate(x, 0, z)
    geometry.cylinder(b, 0.16, h, 6, colors.trim, colors.trim, 0.75, true)
    b:push():translate(0, h, 0)
    b:rotateY(rng:range(0, TAU))
    geometry.box(b, 1.6, 0.16, 0.4, colors.trim)
    b:pop()
    b:pop()
    g:push():translate(x + 0.7, h - 0.12, z)
    geometry.box(g, 0.9, 0.14, 0.34, C.lamp)
    g:pop()
end

local function crates(b, x, z, rng)
    local n = rng:int(2, 6)
    for i = 1, n do
        local s = rng:range(0.8, 1.8)
        b:push()
        b:translate(x + rng:range(-2.5, 2.5), 0, z + rng:range(-2.5, 2.5))
        b:rotateY(rng:range(0, TAU))
        local col = rng:pick({ C.rust, C.steel, C.darkGreen, C.amber, C.hullDark })
        geometry.boxStanding(b, s, s * rng:range(0.6, 1.1), s * rng:range(0.8, 1.4), col, palette.shade(col, 0.7))
        b:pop()
    end
end

local function fence(b, g, radius, rng, colors)
    local posts = max(16, floor(radius * 0.5))
    for i = 0, posts - 1 do
        local a = i / posts * TAU
        local x, z = cos(a) * radius, sin(a) * radius
        b:push():translate(x, 0, z)
        geometry.box(b, 0.24, 2.6, 0.24, colors.trim)
        b:pop()
        local a2 = (i + 1) / posts * TAU
        local x2, z2 = cos(a2) * radius, sin(a2) * radius
        geometry.beam(b, x, 2.3, z, x2, 2.3, z2, 0.08, colors.trim)
        geometry.beam(b, x, 1.4, z, x2, 1.4, z2, 0.06, colors.trim)
        if i % 6 == 0 then
            g:push():translate(x, 2.9, z)
            geometry.sphere(g, 0.16, 5, 3, C.red)
            g:pop()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local function overlaps(list, x, z, r, slack)
    for i = 1, #list do
        local o = list[i]
        local dx, dz = o.x - x, o.z - z
        if sqrt(dx * dx + dz * dz) < (o.radius + r) * (slack or 1.0) then return true end
    end
    return false
end

--- Generates a settlement.
-- opts: seed, tier, population, economyId, techLevel, factionId, pads,
--       factionColor, player (a colony founded by the player)
function settlement.generate(opts)
    local rng = Rng.new(opts.seed or 1, "settlement-mesh")
    local tier = util.clamp(opts.tier or 2, 1, 5)
    local padCount = util.clamp(opts.pads or 2, 1, 6)

    local colors = buildings.colorScheme(rng, { factionColor = opts.factionColor })
    local solid = MeshBuilder.new()
    local glow = MeshBuilder.new()

    -- Town size grows with tier; the radius has to hold the buildings we want.
    local buildingBudget = ({ 6, 11, 18, 28, 42 })[tier]
    if opts.player then buildingBudget = max(4, floor(buildingBudget * 0.6)) end
    local radius = 42 + buildingBudget * 3.4 + padCount * 8

    local occupied = {}
    local pads = {}
    local placed = {}
    local interiors = {}

    -- ---- ground plate ---------------------------------------------------
    local plateCol = palette.shade(colors.wall, 0.42)
    geometry.cylinder(solid, radius * 1.05, 0.1, 24, plateCol, palette.shade(plateCol, 1.1), 1, true)

    -- ---- landing pads ---------------------------------------------------
    local padR = 22
    for i = 1, padCount do
        local a = (i - 1) / padCount * TAU + rng:range(-0.2, 0.2)
        local dist = (padCount == 1) and 0 or (radius * 0.42)
        local x, z = cos(a) * dist, sin(a) * dist
        solid:push():translate(x, 0.1, z)
        glow:push():translate(x, 0.1, z)
        landingPad(solid, glow, padR, rng, colors, i)
        solid:pop()
        glow:pop()
        local pad = { x = x, z = z, y = 0.32, radius = padR, index = i }
        pads[i] = pad
        occupied[#occupied + 1] = { x = x, z = z, radius = padR * 1.5 }
    end

    -- ---- road network ---------------------------------------------------
    local roadCol = palette.shade(colors.wall, 0.33)
    local ringR = radius * 0.68
    local ringSegs = 20
    for i = 0, ringSegs - 1 do
        local a0, a1 = i / ringSegs * TAU, (i + 1) / ringSegs * TAU
        road(solid, cos(a0) * ringR, sin(a0) * ringR, cos(a1) * ringR, sin(a1) * ringR, 7, roadCol)
    end
    local spurs = rng:int(3, 6)
    for i = 1, spurs do
        local a = (i - 1) / spurs * TAU + rng:range(-0.15, 0.15)
        road(solid, 0, 0, cos(a) * radius * 0.96, sin(a) * radius * 0.96, 6, roadCol)
    end
    for _, pad in ipairs(pads) do
        road(solid, pad.x, pad.z, pad.x * 1.9, pad.z * 1.9, 6, roadCol)
    end

    -- ---- buildings ------------------------------------------------------
    local used = {}
    local wanted = {}
    -- guarantee the services the settlement advertises
    if tier >= 2 then wanted[#wanted + 1] = "tower" end
    if (opts.services and opts.services.market) or tier >= 2 then wanted[#wanted + 1] = "market" end
    if tier >= 3 then wanted[#wanted + 1] = "hab" end
    if tier >= 2 then wanted[#wanted + 1] = "warehouse" end
    if tier >= 3 then wanted[#wanted + 1] = "hangar" end

    local order = {}
    for _, id in ipairs(wanted) do order[#order + 1] = buildings.kinds[id] end
    for _ = #order + 1, buildingBudget do
        order[#order + 1] = buildings.pick(rng, tier, opts.economyId, used)
    end

    for _, kind in ipairs(order) do
        used[kind.id] = true
        -- try to find a free spot, biggest structures first get the best land
        local placedOk = false
        for attempt = 1, 40 do
            local a = rng:range(0, TAU)
            local dist = rng:range(radius * 0.18, radius * 0.94)
            -- bias buildings to sit near the ring road
            if rng:bool(0.55) then dist = ringR + rng:range(-14, 16) end
            local x, z = cos(a) * dist, sin(a) * dist
            local est = (kind.footprint[2] or 20) * 0.8
            if not overlaps(occupied, x, z, est, 1.06) and dist + est < radius * 1.02 then
                local brng = rng:derive(kind.id, attempt, floor(x), floor(z))
                local rot = rng:range(0, TAU)
                -- snap most buildings to face the town centre
                if rng:bool(0.7) then rot = math.atan2 and math.atan2(x, z) + pi or rot end

                solid:push():translate(x, 0.1, z):rotateY(rot)
                glow:push():translate(x, 0.1, z):rotateY(rot)
                local info = buildings.build(solid, kind.id, brng, {
                    glow = glow, tier = tier, tech = opts.techLevel or 6, colors = colors,
                })
                solid:pop()
                glow:pop()

                local entry = nil
                if info.entrance then
                    local ex = info.entrance.x * cos(rot) + info.entrance.z * sin(rot)
                    local ez = -info.entrance.x * sin(rot) + info.entrance.z * cos(rot)
                    entry = { x = x + ex, z = z + ez, y = 0.1 }
                end

                local rec = {
                    x = x, z = z, y = 0.1, rot = rot,
                    radius = info.radius, height = info.height,
                    kind = kind.id, name = info.name,
                    enterable = info.enterable, interior = info.interior,
                    entrance = entry,
                }
                placed[#placed + 1] = rec
                occupied[#occupied + 1] = { x = x, z = z, radius = info.radius }
                if info.enterable and entry then
                    interiors[#interiors + 1] = rec
                end
                placedOk = true
                break
            end
        end
        if not placedOk then
            -- the town is full; stop rather than stacking geometry
            break
        end
    end

    -- ---- street furniture ----------------------------------------------
    for i = 1, floor(radius / 7) do
        local a = rng:range(0, TAU)
        local dist = rng:range(radius * 0.25, radius * 0.95)
        local x, z = cos(a) * dist, sin(a) * dist
        if not overlaps(occupied, x, z, 2.5, 1.0) then
            streetLamp(solid, glow, x, z, rng, colors)
            occupied[#occupied + 1] = { x = x, z = z, radius = 1.6 }
        end
    end
    for i = 1, rng:int(2, 6) do
        local a = rng:range(0, TAU)
        local dist = rng:range(radius * 0.3, radius * 0.9)
        local x, z = cos(a) * dist, sin(a) * dist
        if not overlaps(occupied, x, z, 4, 1.0) then
            crates(solid, x, z, rng)
            occupied[#occupied + 1] = { x = x, z = z, radius = 4 }
        end
    end
    if tier >= 2 then fence(solid, glow, radius * 1.02, rng, colors) end

    local model = solid:build()
    local glowModel = glow:build()

    return {
        seed = opts.seed,
        name = opts.name or names.settlement(opts.seed or 1),
        model = model,
        glowModel = glowModel,
        radius = radius * 1.12,
        buildings = placed,
        pads = pads,
        interiors = interiors,
        colors = colors,
        tier = tier,
        triangles = (model and model.triangles or 0) + (glowModel and glowModel.triangles or 0),
    }
end

--- Cheap far-distance stand-in: the same footprint as coloured blocks, so a
--- town is still visible from orbit without paying for its detail.
function settlement.generateLod(place, detail)
    local b = MeshBuilder.new()
    local col = detail and detail.colors and detail.colors.wall or C.hull
    for _, bl in ipairs(detail.buildings) do
        b:push():translate(bl.x, 0, bl.z)
        geometry.boxStanding(b, bl.radius * 1.2, bl.height, bl.radius * 1.2, col, palette.shade(col, 0.8))
        b:pop()
    end
    for _, p in ipairs(detail.pads) do
        b:push():translate(p.x, 0.2, p.z)
        geometry.cylinder(b, p.radius, 0.2, 8, C.hullDark, C.steel, 1, true)
        b:pop()
    end
    return b:build()
end

--- Height of the walkable floor at a local point (pads sit slightly proud of
--- the plate).  Used by the on-foot controller.
function settlement.floorHeight(detail, x, z)
    for _, p in ipairs(detail.pads) do
        local dx, dz = x - p.x, z - p.z
        if dx * dx + dz * dz < p.radius * p.radius then return 0.42 end
    end
    return 0.1
end

--- Solid cylinder test for the walking player.
function settlement.collide(detail, x, z, radius)
    for _, b in ipairs(detail.buildings) do
        local dx, dz = x - b.x, z - b.z
        local d = sqrt(dx * dx + dz * dz)
        local r = b.radius * 0.72 + radius
        if d < r and d > 1e-6 then
            local push = r - d
            return x + dx / d * push, z + dz / d * push
        end
    end
    return x, z
end

return settlement

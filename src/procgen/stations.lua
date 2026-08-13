-- Orbital stations.
--
-- Four families, all built from the same detail vocabulary as the ground
-- settlements so the two read as one civilisation:
--
--   coriolis  the classic rotating polyhedron with a slot you fly into
--   torus     a habitation ring on spokes around a hub
--   drum      a spinning cylinder with docking arms
--   outpost   a small cluster of modules on a truss, no rotation
--
-- Each returns the mesh plus the approach data the docking code needs: the
-- mouth position and normal, and the interior corridor length.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")
local palette = require("src.render.palette")

local stations = {}

local cos, sin, pi, floor, max = math.cos, math.sin, math.pi, math.floor, math.max
local TAU = pi * 2
local C = palette.colors

local function moduleCluster(b, g, rng, size, colors)
    local n = rng:int(3, 6)
    for i = 1, n do
        local a = (i - 1) / n * TAU
        local r = size * rng:range(0.3, 0.6)
        local x, y, z = cos(a) * r, rng:range(-size * 0.2, size * 0.2), sin(a) * r
        b:push():translate(x, y, z)
        b:rotateY(-a)
        local l = size * rng:range(0.3, 0.55)
        local rr = size * rng:range(0.1, 0.18)
        b:rotateZ(pi * 0.5)
        geometry.cylinder(b, rr, l, 8, colors.hull, colors.trim, 1, true)
        for k = 1, 3 do
            b:push():translate(0, l * k / 4, 0)
            geometry.cylinder(b, rr * 1.1, 0.4, 8, colors.trim, nil, 1, false)
            b:pop()
        end
        b:pop()
        -- window band
        g:push():translate(x, y, z)
        g:rotateY(-a)
        for k = 1, 6 do
            g:push():translate(size * 0.06 * (k - 3.5), 0, size * rng:range(0.1, 0.18) + 0.05)
            g:quad(-0.6, -0.5, 0, 0.6, -0.5, 0, 0.6, 0.5, 0, -0.6, 0.5, 0, C.window)
            g:pop()
        end
        g:pop()
        -- connecting spar to the hub
        geometry.beam(b, 0, 0, 0, x, y, z, size * 0.035, colors.trim)
    end
end

local function solarWings(b, rng, size, colors)
    for _, side in ipairs({ 1, -1 }) do
        local len = size * rng:range(0.7, 1.3)
        b:push():translate(side * size * 0.5, 0, 0)
        geometry.beam(b, 0, 0, 0, side * len * 0.4, 0, 0, size * 0.03, colors.trim)
        b:push():translate(side * len * 0.55, 0, 0)
        for k = -1, 1 do
            b:push():translate(0, 0, k * size * 0.42)
            geometry.box(b, len * 0.5, size * 0.012, size * 0.36, C.darkBlue, C.blue)
            b:pop()
        end
        b:pop()
        b:pop()
    end
end

local function dockingLights(g, r, count, color)
    for i = 0, count - 1 do
        local a = i / count * TAU
        g:push():translate(cos(a) * r, 0, sin(a) * r)
        geometry.sphere(g, r * 0.03 + 0.6, 6, 4, color)
        g:pop()
    end
end

-- ---------------------------------------------------------------------------

local BUILDERS = {}

--- Coriolis: an octagonal wheel spinning about its docking axis (local Z).
BUILDERS.coriolis = function(b, g, rng, size, colors)
    local r = size * 0.5
    local thick = r * 0.52
    local sides = 8
    -- outer shell
    for i = 0, sides - 1 do
        local a0, a1 = i / sides * TAU, (i + 1) / sides * TAU
        local x0, y0 = cos(a0) * r, sin(a0) * r
        local x1, y1 = cos(a1) * r, sin(a1) * r
        local col = (i % 2 == 0) and colors.hull or palette.shade(colors.hull, 0.88)
        b:quad(x0, y0, -thick, x1, y1, -thick, x1, y1, thick, x0, y0, thick, col)
        -- end faces
        b:tri(0, 0, thick, x0, y0, thick, x1, y1, thick, palette.shade(colors.hull, 0.94))
        b:tri(0, 0, -thick, x1, y1, -thick, x0, y0, -thick, palette.shade(colors.hull, 0.8))
        -- panel ribs
        geometry.beam(b, x0, y0, -thick, x0, y0, thick, r * 0.03, colors.trim)
        -- window rows on the outer face
        for k = 1, 5 do
            local t = k / 6
            local px, py = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            g:push():translate(px * 1.005, py * 1.005, 0)
            g:rotateZ(math.atan2 and math.atan2(py, px) or 0)
            g:rotateY(pi * 0.5)
            g:quad(-thick * 0.7, -r * 0.03, 0, thick * 0.7, -r * 0.03, 0,
                   thick * 0.7, r * 0.03, 0, -thick * 0.7, r * 0.03, 0, C.window)
            g:pop()
        end
    end
    -- docking slot in the +Z face
    local slotW, slotH = r * 0.34, r * 0.16
    b:push():translate(0, 0, thick)
    geometry.box(b, slotW * 2.6, slotH * 3.4, r * 0.1, palette.shade(colors.hull, 0.6))
    b:pop()
    b:push():translate(0, 0, thick - r * 0.02)
    geometry.frustumBox(b, slotW * 2, slotH * 2, slotW * 2, slotH * 2, -r * 0.5, C.black, C.black)
    b:pop()
    g:push():translate(0, 0, thick + 0.1)
    for k = -1, 1, 2 do
        g:push():translate(k * slotW * 1.1, 0, 0)
        g:quad(-r * 0.02, -slotH, 0, r * 0.02, -slotH, 0, r * 0.02, slotH, 0, -r * 0.02, slotH, 0, C.green)
        g:pop()
    end
    g:pop()
    -- hazard stripes around the mouth
    for i = 0, 15 do
        local a = i / 16 * TAU
        b:push():translate(cos(a) * slotW * 2.2, sin(a) * slotH * 3.0, thick + 0.05)
        geometry.box(b, r * 0.05, r * 0.05, r * 0.02, (i % 2 == 0) and C.hazard or C.black)
        b:pop()
    end
    dockingLights(g, r * 0.98, 8, C.red)
    return {
        mouth = { x = 0, y = 0, z = thick + r * 0.05 },
        mouthNormal = { x = 0, y = 0, z = 1 },
        corridor = r * 0.55,
        spin = { x = 0, y = 0, z = 1 },
        radius = r * 1.05,
    }
end

--- Torus: habitation ring, hub, spokes and a docking cone on the axis.
BUILDERS.torus = function(b, g, rng, size, colors)
    local r = size * 0.5
    local tube = r * 0.16
    geometry.torus(b, r, tube, 28, 8, colors.hull)
    -- window band around the outside of the ring
    for i = 0, 47 do
        local a = i / 48 * TAU
        g:push():translate(cos(a) * (r + tube * 0.98), 0, sin(a) * (r + tube * 0.98))
        g:rotateY(-a)
        g:quad(0, -tube * 0.28, -tube * 0.5, 0, -tube * 0.28, tube * 0.5,
               0, tube * 0.28, tube * 0.5, 0, tube * 0.28, -tube * 0.5, C.window)
        g:pop()
    end
    -- hub
    b:push()
    geometry.cylinder(b, r * 0.2, tube * 2.4, 12, colors.trim, colors.hull, 1, true)
    b:translate(0, -tube * 1.2, 0)
    geometry.cylinder(b, r * 0.2, tube * 2.4, 12, colors.trim, colors.hull, 1, true)
    b:pop()
    geometry.spokes(b, r * 0.18, r - tube, 0, 6, tube * 0.35, colors.trim)
    -- docking cone along +Y (the spin axis)
    b:push():translate(0, tube * 1.4, 0)
    geometry.lathe(b, { { r * 0.2, 0 }, { r * 0.14, tube * 1.2 }, { r * 0.16, tube * 2.4 } }, 12, colors.hull)
    b:pop()
    b:push():translate(0, tube * 3.8, 0)
    geometry.cylinder(b, r * 0.16, tube * 0.5, 12, C.black, C.black, 1, false)
    b:pop()
    dockingLights(g, r * 0.19, 6, C.green)
    solarWings(b, rng, size * 0.5, colors)
    return {
        mouth = { x = 0, y = tube * 4.3, z = 0 },
        mouthNormal = { x = 0, y = 1, z = 0 },
        corridor = tube * 2.2,
        spin = { x = 0, y = 1, z = 0 },
        radius = r * 1.1,
    }
end

--- Drum: a spinning cylinder with docking arms at one end.
BUILDERS.drum = function(b, g, rng, size, colors)
    local r = size * 0.32
    local len = size * 0.9
    b:push():translate(0, 0, -len * 0.5)
    b:rotateX(-pi * 0.5)
    geometry.cylinder(b, r, len, 14, colors.hull, colors.trim, 1, true)
    b:pop()
    -- ribs and windows
    for k = 1, 6 do
        local z = -len * 0.5 + len * k / 7
        b:push():translate(0, 0, z)
        b:rotateX(-pi * 0.5)
        geometry.cylinder(b, r * 1.04, len * 0.02, 14, colors.trim, nil, 1, false)
        b:pop()
        for i = 0, 11 do
            local a = i / 12 * TAU
            g:push():translate(cos(a) * r * 1.01, sin(a) * r * 1.01, z)
            g:rotateZ(math.atan2 and math.atan2(sin(a), cos(a)) or 0)
            g:rotateY(pi * 0.5)
            g:quad(-len * 0.02, -r * 0.05, 0, len * 0.02, -r * 0.05, 0,
                   len * 0.02, r * 0.05, 0, -len * 0.02, r * 0.05, 0, C.window)
            g:pop()
        end
    end
    -- docking arms
    for i = 1, 3 do
        local a = (i - 1) / 3 * TAU
        b:push():translate(cos(a) * r * 0.7, sin(a) * r * 0.7, len * 0.5)
        geometry.beam(b, 0, 0, 0, 0, 0, len * 0.22, r * 0.09, colors.trim)
        b:push():translate(0, 0, len * 0.22)
        geometry.cylinder(b, r * 0.12, r * 0.16, 8, colors.hull, C.black, 1, true)
        b:pop()
        b:pop()
    end
    -- axial approach cone
    b:push():translate(0, 0, len * 0.5)
    geometry.lathe(b, { { r * 0.4, 0 }, { r * 0.26, len * 0.12 }, { r * 0.28, len * 0.2 } }, 12, colors.hull)
    b:pop()
    dockingLights(g, r * 0.42, 6, C.green)
    solarWings(b, rng, size * 0.6, colors)
    return {
        mouth = { x = 0, y = 0, z = len * 0.72 },
        mouthNormal = { x = 0, y = 0, z = 1 },
        corridor = len * 0.18,
        spin = { x = 0, y = 0, z = 1 },
        radius = max(r, len * 0.5) * 1.1,
    }
end

--- Outpost: a truss with modules, a pad and a control blister.  No spin.
BUILDERS.outpost = function(b, g, rng, size, colors)
    local l = size * 1.2
    b:push():translate(0, 0, -l * 0.5)
    b:rotateX(-pi * 0.5)
    geometry.truss(b, size * 0.28, l, 6, size * 0.02, colors.trim)
    b:pop()
    moduleCluster(b, g, rng, size * 0.7, colors)
    -- landing pad on top
    b:push():translate(0, size * 0.3, 0)
    geometry.cylinder(b, size * 0.34, size * 0.03, 10, colors.trim, palette.shade(colors.trim, 1.2), 1, true)
    for i = 0, 9 do
        local a = i / 10 * TAU
        g:push():translate(cos(a) * size * 0.33, size * 0.34, sin(a) * size * 0.33)
        geometry.sphere(g, size * 0.012, 5, 3, (i % 2 == 0) and C.hazard or C.green)
        g:pop()
    end
    b:pop()
    -- control blister
    b:push():translate(0, size * 0.36, -size * 0.2)
    geometry.dome(b, size * 0.12, size * 0.1, 10, 4, colors.hull)
    b:pop()
    g:push():translate(0, size * 0.40, -size * 0.2)
    geometry.dome(g, size * 0.10, size * 0.07, 10, 3, C.glassLit)
    g:pop()
    solarWings(b, rng, size, colors)
    return {
        mouth = { x = 0, y = size * 0.36, z = 0 },
        mouthNormal = { x = 0, y = 1, z = 0 },
        corridor = 0,
        pad = true,
        radius = size * 0.75,
    }
end

-- ---------------------------------------------------------------------------

--- Builds a station mesh from its descriptor (see procgen.system).
function stations.generate(st)
    local rng = Rng.new(st.seed or 1, "station-mesh")
    local set = palette.hullSets[st.derelict and "pirate" or "civilian"]
    local colors = {
        hull = palette.colors[set[rng:int(1, #set)]],
        trim = palette.colors[set[rng:int(1, #set)]],
    }
    if st.derelict then
        colors.hull = palette.shade(colors.hull, 0.6)
        colors.trim = palette.shade(colors.trim, 0.5)
    end

    local b = MeshBuilder.new()
    local g = MeshBuilder.new()
    local builder = BUILDERS[st.stationKind] or BUILDERS.outpost
    local info = builder(b, g, rng, st.size, colors)

    -- faction / identity stripe
    if not st.derelict then
        local stripe = rng:pick({ C.orange, C.teal, C.red, C.blue, C.amber })
        b:push():translate(0, 0, 0)
        geometry.torus(b, st.size * 0.42, st.size * 0.012, 20, 4, stripe)
        b:pop()
    end

    return {
        model = b:build(),
        glowModel = st.derelict and nil or g:build(),
        radius = (info.radius or st.size * 0.6),
        mouth = info.mouth,
        mouthNormal = info.mouthNormal,
        corridor = info.corridor or 0,
        pad = info.pad or false,
        spin = info.spin,
        colors = colors,
    }
end

--- World position and orientation of a station's docking mouth, given the
--- station's current spin.  Docking checks live in the flight state.
function stations.mouthWorld(st, mesh)
    local spin = st.spin or 0
    local c, s = cos(spin), sin(spin)
    local m = mesh.mouth or { x = 0, y = 0, z = 0 }
    local n = mesh.mouthNormal or { x = 0, y = 0, z = 1 }
    -- stations spin about their local Z (or Y for the torus); rotating about
    -- Z leaves a +Z mouth in place, which is why the classic design works
    local axis = mesh.spin or { x = 0, y = 0, z = 1 }
    local function rot(p)
        if axis.z == 1 then
            return p.x * c - p.y * s, p.x * s + p.y * c, p.z
        elseif axis.y == 1 then
            return p.x * c + p.z * s, p.y, -p.x * s + p.z * c
        end
        return p.x, p.y, p.z
    end
    local mx, my, mz = rot(m)
    local nx, ny, nz = rot(n)
    return st.pos.x + mx, st.pos.y + my, st.pos.z + mz, nx, ny, nz
end

return stations

-- Procedural ships.
--
-- Hulls are lofted: a spine of cross sections from nose to tail, each an
-- n-gon of a given half width and half height, connected by quads.  Lofting
-- gives the chunky, faceted silhouettes of the era for very little code, and
-- because the spine is data we can retune a whole role by editing a table.
--
-- On top of the hull go the parts that make a ship readable at a glance:
-- engine bells, wings, fins, a canopy, weapon hardpoints and greebles.  The
-- same generator returns the gameplay stats, so a visibly bigger ship really
-- does carry more cargo.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")
local palette = require("src.render.palette")
local names = require("src.procgen.names")

local ships = {}

local cos, sin, pi, max, min = math.cos, math.sin, math.pi, math.max, math.min
local TAU = pi * 2

ships.roles = { "shuttle", "fighter", "trader", "hauler", "explorer", "miner", "gunship", "interceptor", "freighter" }

-- role -> hull character.  `spine` entries are {t, halfWidth, halfHeight, yOffset}
-- where t runs 0 (nose) to 1 (tail).
local ROLES = {
    shuttle = {
        name = "Shuttle", palette = "civilian", sides = 6, length = { 14, 20 },
        spine = { { 0, 0.10, 0.10, 0 }, { 0.18, 0.42, 0.34, 0.02 }, { 0.55, 0.55, 0.44, 0 }, { 0.86, 0.48, 0.38, -0.02 }, { 1, 0.30, 0.26, -0.02 } },
        wings = { span = 0.9, sweep = 0.5, thickness = 0.1, count = 1 },
        engines = 2, guns = 1, cargo = { 6, 14 }, hull = { 70, 110 }, agility = 1.0, price = { 18000, 34000 },
    },
    fighter = {
        name = "Fighter", palette = "military", sides = 5, length = { 16, 24 },
        spine = { { 0, 0.06, 0.06, 0 }, { 0.22, 0.36, 0.22, 0 }, { 0.5, 0.5, 0.3, 0 }, { 0.78, 0.42, 0.28, 0 }, { 1, 0.22, 0.18, 0 } },
        wings = { span = 1.9, sweep = 0.75, thickness = 0.06, count = 1, dihedral = -0.12 },
        engines = 2, guns = 2, cargo = { 2, 6 }, hull = { 110, 180 }, agility = 1.55, price = { 52000, 96000 },
    },
    interceptor = {
        name = "Interceptor", palette = "military", sides = 4, length = { 18, 26 },
        spine = { { 0, 0.05, 0.05, 0 }, { 0.3, 0.30, 0.20, 0 }, { 0.62, 0.44, 0.26, 0 }, { 1, 0.18, 0.16, 0 } },
        wings = { span = 2.4, sweep = 0.9, thickness = 0.05, count = 2, dihedral = 0.18 },
        engines = 3, guns = 2, cargo = { 1, 4 }, hull = { 90, 150 }, agility = 1.9, price = { 78000, 140000 },
    },
    trader = {
        name = "Trader", palette = "trader", sides = 6, length = { 24, 34 },
        spine = { { 0, 0.14, 0.14, 0 }, { 0.2, 0.5, 0.42, 0.02 }, { 0.6, 0.66, 0.52, 0 }, { 0.88, 0.6, 0.46, 0 }, { 1, 0.34, 0.3, 0 } },
        wings = { span = 0.7, sweep = 0.35, thickness = 0.14, count = 1 },
        engines = 2, guns = 1, cargo = { 20, 44 }, hull = { 140, 220 }, agility = 0.8, price = { 96000, 180000 },
    },
    hauler = {
        name = "Hauler", palette = "industry", sides = 4, length = { 34, 52 },
        spine = { { 0, 0.2, 0.2, 0 }, { 0.16, 0.6, 0.5, 0 }, { 0.45, 0.72, 0.6, 0 }, { 0.82, 0.7, 0.58, 0 }, { 1, 0.42, 0.4, 0 } },
        wings = { span = 0.4, sweep = 0.2, thickness = 0.2, count = 1 },
        engines = 4, guns = 1, cargo = { 60, 130 }, hull = { 260, 420 }, agility = 0.45, price = { 240000, 480000 },
        containers = true,
    },
    freighter = {
        name = "Freighter", palette = "industry", sides = 6, length = { 60, 96 },
        spine = { { 0, 0.16, 0.18, 0.06 }, { 0.12, 0.42, 0.4, 0.04 }, { 0.3, 0.55, 0.5, 0 }, { 0.72, 0.62, 0.54, 0 }, { 0.92, 0.6, 0.52, 0 }, { 1, 0.34, 0.34, 0 } },
        wings = { span = 0.3, sweep = 0.1, thickness = 0.25, count = 1 },
        engines = 6, guns = 2, cargo = { 180, 420 }, hull = { 620, 1100 }, agility = 0.22, price = { 900000, 2100000 },
        containers = true, truss = true,
    },
    explorer = {
        name = "Explorer", palette = "highTech", sides = 8, length = { 26, 38 },
        spine = { { 0, 0.12, 0.12, 0 }, { 0.22, 0.42, 0.36, 0.03 }, { 0.55, 0.52, 0.42, 0 }, { 0.85, 0.46, 0.36, 0 }, { 1, 0.26, 0.24, 0 } },
        wings = { span = 1.2, sweep = 0.4, thickness = 0.08, count = 1, dihedral = 0.1 },
        engines = 2, guns = 1, cargo = { 12, 26 }, hull = { 150, 240 }, agility = 0.95, price = { 180000, 340000 },
        dish = true, panels = true,
    },
    miner = {
        name = "Miner", palette = "industry", sides = 6, length = { 28, 40 },
        spine = { { 0, 0.24, 0.22, 0 }, { 0.24, 0.58, 0.48, 0 }, { 0.6, 0.68, 0.54, 0 }, { 0.9, 0.56, 0.44, 0 }, { 1, 0.32, 0.3, 0 } },
        wings = { span = 0.6, sweep = 0.25, thickness = 0.16, count = 1 },
        engines = 3, guns = 1, cargo = { 40, 90 }, hull = { 220, 360 }, agility = 0.55, price = { 190000, 360000 },
        mining = true, containers = true,
    },
    gunship = {
        name = "Gunship", palette = "military", sides = 6, length = { 30, 46 },
        spine = { { 0, 0.16, 0.14, 0 }, { 0.2, 0.52, 0.36, 0 }, { 0.5, 0.7, 0.44, 0 }, { 0.84, 0.6, 0.4, 0 }, { 1, 0.3, 0.26, 0 } },
        wings = { span = 1.5, sweep = 0.6, thickness = 0.1, count = 2, dihedral = -0.08 },
        engines = 4, guns = 4, cargo = { 8, 20 }, hull = { 420, 720 }, agility = 0.75, price = { 420000, 860000 },
        turrets = true,
    },
}

ships.roleInfo = ROLES

-- ---------------------------------------------------------------------------
-- Lofting
-- ---------------------------------------------------------------------------

--- Cross section point on an n-gon of the given half extents.
-- The gon is rotated so a flat face sits on top, which reads better than a
-- vertex-up orientation on a hull.
local function sectionPoint(sides, i, hw, hh, yOff)
    local a = (i / sides) * TAU + pi / sides
    return cos(a) * hw, sin(a) * hh + yOff
end

--- Lofts the spine into a closed hull.
local function loftHull(b, spine, sides, length, colorFn)
    local n = #spine
    for s = 1, n - 1 do
        local a, c = spine[s], spine[s + 1]
        local z0 = (a[1] - 0.5) * length
        local z1 = (c[1] - 0.5) * length
        for i = 0, sides - 1 do
            local x0, y0 = sectionPoint(sides, i, a[2], a[3], a[4])
            local x1, y1 = sectionPoint(sides, i + 1, a[2], a[3], a[4])
            local x2, y2 = sectionPoint(sides, i + 1, c[2], c[3], c[4])
            local x3, y3 = sectionPoint(sides, i, c[2], c[3], c[4])
            b:quad(x0, y0, z0, x1, y1, z0, x2, y2, z1, x3, y3, z1, colorFn(s, i))
        end
    end
    -- close the nose and the tail
    local function cap(entry, z, flip)
        local pts = {}
        for i = 0, sides - 1 do
            local idx = flip and (sides - i) or i
            local x, y = sectionPoint(sides, idx, entry[2], entry[3], entry[4])
            pts[#pts + 1] = { x, y, z }
        end
        b:poly(pts, colorFn(0, 0))
    end
    cap(spine[1], (spine[1][1] - 0.5) * length, true)
    cap(spine[n], (spine[n][1] - 0.5) * length, false)
end

--- Value of the spine (half width, half height, y offset) at parameter t.
local function spineAt(spine, t)
    for s = 1, #spine - 1 do
        local a, c = spine[s], spine[s + 1]
        if t >= a[1] and t <= c[1] then
            local f = (t - a[1]) / max(c[1] - a[1], 1e-6)
            return util.lerp(a[2], c[2], f), util.lerp(a[3], c[3], f), util.lerp(a[4], c[4], f)
        end
    end
    local last = spine[#spine]
    return last[2], last[3], last[4]
end

-- ---------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------

local function addWings(b, def, rng, length, colors)
    local w = def.wings
    if not w then return end
    local root = rng:range(0.42, 0.68)
    for pair = 1, (w.count or 1) do
        local t = util.clamp(root + (pair - 1) * 0.18, 0.2, 0.94)
        local hw, hh, yo = spineAt(def.spine, t)
        local z = (t - 0.5) * length
        local span = length * w.span * 0.5 * rng:range(0.85, 1.15) / (pair * 0.8)
        local chord = length * rng:range(0.16, 0.30)
        local sweep = chord * (w.sweep or 0.5) * 2
        local thick = length * (w.thickness or 0.08) * 0.5
        local dihedral = (w.dihedral or 0) * span
        local tipChord = chord * rng:range(0.25, 0.6)

        for _, side in ipairs({ 1, -1 }) do
            local x0 = hw * length * 0.8 * side
            local shape = {
                { x0, z - chord * 0.5 },
                { x0 + span * side, z - chord * 0.5 + sweep },
                { x0 + span * side, z - chord * 0.5 + sweep + tipChord },
                { x0, z + chord * 0.5 },
            }
            if side < 0 then
                shape = { shape[4], shape[3], shape[2], shape[1] }
            end
            b:push()
            b:translate(0, yo * length + dihedral * 0, 0)
            -- a wing is a thin extrusion in Y, then rotated for dihedral
            b:push()
            b:rotateZ(-side * (w.dihedral or 0))
            geometry.extrude(b, shape, -thick, thick, colors.wing, colors.wingTop, true)
            b:pop()
            b:pop()
        end
    end
end

local function addFins(b, def, rng, length, colors)
    local count = rng:int(1, 2)
    for i = 1, count do
        local t = rng:range(0.62, 0.95)
        local hw, hh, yo = spineAt(def.spine, t)
        local z = (t - 0.5) * length
        local h = length * rng:range(0.12, 0.26)
        local chord = length * rng:range(0.12, 0.22)
        local top = rng:bool(0.75)
        local dir = top and 1 or -1
        local base = (hh * length * 0.85 + yo * length) * dir
        local shape = {
            { z - chord * 0.5, base },
            { z + chord * 0.5, base },
            { z + chord * 0.1, base + h * dir },
            { z - chord * 0.2, base + h * dir },
        }
        -- extrude across X (thin fin), built as a polygon in the ZY plane
        local thick = length * 0.02
        for _, side in ipairs({ 1, -1 }) do
            local pts = {}
            for k = 1, #shape do
                pts[k] = { thick * side, shape[k][2], shape[k][1] }
            end
            if side < 0 then
                local rev = {}
                for k = #pts, 1, -1 do rev[#rev + 1] = pts[k] end
                pts = rev
            end
            b:poly(pts, colors.fin)
        end
        for k = 1, #shape do
            local p = shape[k]
            local q = shape[k % #shape + 1]
            b:quad(thick, p[2], p[1], thick, q[2], q[1], -thick, q[2], q[1], -thick, p[2], p[1], colors.fin)
        end
    end
end

local function addEngines(b, def, rng, length, colors, out)
    local count = def.engines or 2
    local hw, hh, yo = spineAt(def.spine, 1.0)
    local z = length * 0.5
    local r = length * util.clamp(0.09 * (3 / max(count, 2)) ^ 0.5, 0.035, 0.13)
    local ring = max(hw, hh) * length * 0.62

    for i = 1, count do
        local x, y
        if count == 1 then
            x, y = 0, yo * length
        elseif count == 2 then
            x, y = ring * (i == 1 and 1 or -1), yo * length
        else
            local a = (i - 1) / count * TAU + pi * 0.5
            x, y = cos(a) * ring, sin(a) * ring * 0.7 + yo * length
        end
        b:push()
        b:translate(x, y, z - length * 0.06)
        b:rotateX(-pi * 0.5)          -- +Y of the cylinder points along +Z
        geometry.cylinder(b, r, length * 0.16, 8, colors.engine, colors.engineCap, 1.25, true)
        b:pop()
        b:push()
        b:translate(x, y, z + length * 0.10)
        b:rotateX(-pi * 0.5)
        geometry.cylinder(b, r * 1.25, length * 0.035, 8, colors.engineGlow, colors.engineGlow, 0.75, true)
        b:pop()
        out.engines[#out.engines + 1] = { x = x, y = y, z = z + length * 0.12, radius = r }
    end
end

local function addCanopy(b, def, rng, length, colors)
    local t = rng:range(0.16, 0.30)
    local hw, hh, yo = spineAt(def.spine, t)
    local z = (t - 0.5) * length
    local w = hw * length * 0.62
    local h = hh * length * 0.4
    local y = (hh * length * 0.72) + yo * length
    local len = length * 0.16
    b:push()
    b:translate(0, y, z)
    geometry.frustumBox(b, w * 2, len, w * 1.1, len * 0.6, h, colors.glass, colors.glass, { 0, -len * 0.1 })
    b:pop()
    return { x = 0, y = y + h * 0.45, z = z - len * 0.1 }
end

local function addHardpoints(b, def, rng, length, colors, out)
    local count = def.guns or 1
    for i = 1, count do
        local t = rng:range(0.3, 0.6)
        local hw, hh, yo = spineAt(def.spine, t)
        local z = (t - 0.5) * length
        local side = (i % 2 == 1) and 1 or -1
        local x = hw * length * 0.75 * side
        local y = yo * length - hh * length * 0.25
        if count == 1 then x = 0; y = yo * length - hh * length * 0.7 end
        b:push()
        b:translate(x, y, z)
        b:rotateX(pi * 0.5)
        geometry.cylinder(b, length * 0.018, length * 0.22, 6, colors.gun, colors.gun, 0.7, true)
        b:pop()
        out.hardpoints[#out.hardpoints + 1] = { x = x, y = y, z = z - length * 0.22 }
    end
end

local function addContainers(b, def, rng, length, colors)
    local rows = rng:int(2, 4)
    local cols = rng:int(1, 2)
    local cw = length * 0.13
    local cl = length * 0.17
    local ch = length * 0.11
    local hw = spineAt(def.spine, 0.55) * length
    for r = 1, rows do
        for c = 1, cols do
            for _, side in ipairs({ 1, -1 }) do
                local x = side * (hw * 0.85 + cw * (c - 0.5))
                local z = (r - (rows + 1) * 0.5) * cl * 1.12
                local y = -length * 0.02
                b:push()
                b:translate(x, y, z)
                local col = rng:bool(0.3) and colors.accent or colors.container
                geometry.box(b, cw * 0.9, ch, cl * 0.94, col, colors.hullDark)
                -- ribs
                for k = -1, 1 do
                    b:push():translate(0, 0, k * cl * 0.3)
                    geometry.box(b, cw * 0.95, ch * 1.02, cl * 0.05, colors.hullDark)
                    b:pop()
                end
                b:pop()
            end
        end
    end
end

local function addGreebles(b, def, rng, length, colors)
    local count = rng:int(6, 16)
    for _ = 1, count do
        local t = rng:range(0.15, 0.95)
        local hw, hh, yo = spineAt(def.spine, t)
        local z = (t - 0.5) * length
        local a = rng:range(0, TAU)
        local x = cos(a) * hw * length * 0.92
        local y = sin(a) * hh * length * 0.92 + yo * length
        local s = length * rng:range(0.012, 0.05)
        b:push()
        b:translate(x, y, z)
        b:rotateY(rng:range(0, TAU))
        local col = rng:bool(0.25) and colors.accent or colors.panel
        if rng:bool(0.7) then
            geometry.box(b, s * rng:range(1, 3), s, s * rng:range(1, 3.5), col)
        else
            geometry.cylinder(b, s * 0.6, s * rng:range(1, 2.4), 6, col, col, 0.9, true)
        end
        b:pop()
    end
    -- panel lines: thin darker strips along the hull
    for _ = 1, rng:int(2, 5) do
        local t = rng:range(0.25, 0.85)
        local hw, hh, yo = spineAt(def.spine, t)
        local z = (t - 0.5) * length
        b:push():translate(0, yo * length, z)
        geometry.box(b, hw * length * 2.02, hh * length * 2.02, length * 0.008, colors.hullDark)
        b:pop()
    end
end

local function addDish(b, def, rng, length, colors)
    local t = rng:range(0.35, 0.6)
    local hw, hh, yo = spineAt(def.spine, t)
    local z = (t - 0.5) * length
    local y = hh * length + yo * length
    local r = length * rng:range(0.09, 0.15)
    b:push()
    b:translate(0, y + r * 0.6, z)
    b:rotateZ(rng:range(-0.4, 0.4))
    geometry.cylinder(b, length * 0.012, r * 0.7, 6, colors.panel, colors.panel, 1, true)
    b:translate(0, r * 0.7, 0)
    geometry.lathe(b, { { r, 0 }, { r * 0.86, r * 0.2 }, { r * 0.5, r * 0.32 }, { 0, r * 0.36 } }, 12, colors.dish, false, false)
    b:pop()
end

local function addSolarPanels(b, def, rng, length, colors)
    local t = rng:range(0.5, 0.8)
    local hw, hh, yo = spineAt(def.spine, t)
    local z = (t - 0.5) * length
    local w = length * rng:range(0.25, 0.45)
    local h = length * rng:range(0.12, 0.2)
    for _, side in ipairs({ 1, -1 }) do
        b:push()
        b:translate(side * hw * length, yo * length, z)
        b:rotateZ(side * 0.2)
        b:translate(side * w * 0.5, 0, 0)
        geometry.box(b, w, length * 0.008, h, colors.panelArray, colors.panelArray)
        b:pop()
    end
end

local function addTurrets(b, def, rng, length, colors, out)
    for i = 1, rng:int(1, 3) do
        local t = rng:range(0.35, 0.8)
        local hw, hh, yo = spineAt(def.spine, t)
        local z = (t - 0.5) * length
        local top = (i % 2 == 1)
        local y = (top and 1 or -1) * hh * length + yo * length
        b:push()
        b:translate(0, y, z)
        if not top then b:rotateX(pi) end
        geometry.cylinder(b, length * 0.05, length * 0.03, 8, colors.panel, colors.panel, 0.85, true)
        b:translate(0, length * 0.03, 0)
        geometry.box(b, length * 0.055, length * 0.04, length * 0.07, colors.accent)
        b:push():translate(0, 0, -length * 0.07)
        b:rotateX(pi * 0.5)
        geometry.cylinder(b, length * 0.012, length * 0.1, 6, colors.gun, colors.gun, 0.8, true)
        b:pop()
        b:pop()
        out.hardpoints[#out.hardpoints + 1] = { x = 0, y = y, z = z - length * 0.1, turret = true }
    end
end

local function addMiningRig(b, def, rng, length, colors)
    local hw, hh, yo = spineAt(def.spine, 0.1)
    local z = -length * 0.44
    for _, side in ipairs({ 1, -1 }) do
        b:push()
        b:translate(side * hw * length * 0.9, yo * length, z)
        b:rotateZ(side * -0.25)
        geometry.cylinder(b, length * 0.03, length * 0.16, 6, colors.accent, colors.panel, 0.55, true)
        b:pop()
    end
    b:push()
    b:translate(0, -hh * length * 0.6, z + length * 0.05)
    geometry.frustumBox(b, length * 0.2, length * 0.16, length * 0.32, length * 0.2, -length * 0.1, colors.panel, colors.hullDark)
    b:pop()
end

local function addLandingGear(b, def, rng, length, colors, out)
    local pts = { { 0.28, 1 }, { 0.28, -1 }, { 0.82, 0 } }
    for _, p in ipairs(pts) do
        local hw, hh, yo = spineAt(def.spine, p[1])
        local z = (p[1] - 0.5) * length
        local x = p[2] * hw * length * 0.55
        local y = yo * length - hh * length * 0.9
        out.gear[#out.gear + 1] = { x = x, y = y - length * 0.09, z = z }
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function buildColors(rng, def)
    local setName = def.palette or "civilian"
    local set = palette.hullSets[setName] or palette.hullSets.civilian
    local c = palette.colors
    local main = c[set[rng:int(1, #set)]]
    local trim = c[set[rng:int(1, #set)]]
    local accent = rng:pick({ c.orange, c.amber, c.red, c.teal, c.blue, c.green, c.white })
    return {
        hull = main,
        hullAlt = palette.shade(main, 0.82),
        hullDark = palette.shade(main, 0.55),
        panel = trim,
        panelArray = palette.shade(c.darkBlue, 1.1),
        accent = accent,
        wing = palette.shade(main, 0.9),
        wingTop = palette.shade(trim, 1.0),
        fin = accent,
        glass = c.glass,
        engine = palette.shade(c.steel, 0.8),
        engineCap = c.hullDark,
        engineGlow = c.engine,
        gun = c.hullDark,
        dish = c.hullBright,
        container = palette.shade(trim, 0.95),
    }
end

--- Generates a ship: mesh, mount points and gameplay stats.
function ships.generate(seed, role, opts)
    opts = opts or {}
    role = role or "shuttle"
    local def = ROLES[role] or ROLES.shuttle
    local rng = Rng.new(seed, "ship", role)
    local colors = buildColors(rng, def)

    local length = rng:range(def.length[1], def.length[2]) * (opts.sizeScale or 1)
    local sides = def.sides or 6

    -- a little per-ship variation of the spine so two Traders are not twins
    local spine = {}
    for i, s in ipairs(def.spine) do
        spine[i] = {
            s[1],
            s[2] * rng:range(0.9, 1.12),
            s[3] * rng:range(0.9, 1.12),
            s[4] + rng:range(-0.015, 0.015),
        }
    end
    local variant = { spine = spine, wings = def.wings, engines = def.engines, guns = def.guns }

    local b = MeshBuilder.new()
    local out = { engines = {}, hardpoints = {}, gear = {} }

    local function hullColor(section, face)
        if face % 5 == 0 then return colors.hullAlt end
        if section == 1 then return colors.hullAlt end
        return colors.hull
    end

    loftHull(b, spine, sides, length, hullColor)
    addWings(b, variant, rng, length, colors)
    addFins(b, variant, rng, length, colors)
    local cockpit = addCanopy(b, variant, rng, length, colors)
    addEngines(b, variant, rng, length, colors, out)
    addHardpoints(b, variant, rng, length, colors, out)
    if def.containers and rng:bool(0.85) then addContainers(b, variant, rng, length, colors) end
    if def.truss then
        b:push():translate(0, 0, length * 0.1)
        b:rotateX(math.pi * 0.5)
        geometry.truss(b, length * 0.22, length * 0.3, 3, length * 0.012, colors.panel)
        b:pop()
    end
    if def.dish then addDish(b, variant, rng, length, colors) end
    if def.panels then addSolarPanels(b, variant, rng, length, colors) end
    if def.turrets then addTurrets(b, variant, rng, length, colors, out) end
    if def.mining then addMiningRig(b, variant, rng, length, colors) end
    addGreebles(b, variant, rng, length, colors)
    addLandingGear(b, variant, rng, length, colors, out)

    local model = b:build()

    -- ---- stats ---------------------------------------------------------
    local sizeFactor = length / ((def.length[1] + def.length[2]) * 0.5)
    local cargo = math.floor(util.lerp(def.cargo[1], def.cargo[2], rng:float()) * sizeFactor)
    local hull = math.floor(util.lerp(def.hull[1], def.hull[2], rng:float()) * sizeFactor)
    local mass = math.floor(hull * 0.9 + cargo * 4 + length * 12)

    local stats = {
        role = role,
        roleName = def.name,
        length = length,
        mass = mass,
        hull = hull,
        maxHull = hull,
        shield = math.floor(hull * rng:range(0.5, 1.1)),
        shieldRecharge = rng:range(2.5, 7) * (def.agility or 1),
        cargo = cargo,
        thrust = (def.agility or 1) * rng:range(0.9, 1.15),
        agility = (def.agility or 1) * rng:range(0.9, 1.15),
        topSpeed = 380 + (def.agility or 1) * rng:range(120, 300),
        fuel = rng:range(14, 34) * (1 + (def.cargo[2] / 100)),
        jumpRange = util.clamp(9 + (def.agility or 1) * 5 - cargo * 0.012 + rng:range(-2, 4), 5, 34),
        hardpoints = #out.hardpoints,
        price = math.floor(util.lerp(def.price[1], def.price[2], rng:float()) * sizeFactor),
        heatCapacity = 100 + length * 4,
    }
    stats.maxShield = stats.shield

    return {
        id = string.format("%s-%d", role, seed % 100000),
        name = names.ship(seed),
        role = role,
        roleName = def.name,
        model = model,
        radius = model and model.radius or length * 0.5,
        length = length,
        stats = stats,
        engines = out.engines,
        hardpoints = out.hardpoints,
        gear = out.gear,
        cockpitOffset = cockpit,
        colors = colors,
        seed = seed,
    }
end

--- The catalogue a shipyard offers, scaled by the local tech level.
function ships.catalogue(seed, techLevel, count)
    local rng = Rng.new(seed, "catalogue")
    local pool = {}
    for _, role in ipairs(ships.roles) do
        local def = ROLES[role]
        local minTech = 1
        if def.price[1] > 500000 then minTech = 8
        elseif def.price[1] > 150000 then minTech = 6
        elseif def.price[1] > 60000 then minTech = 4 end
        if (techLevel or 6) >= minTech then pool[#pool + 1] = role end
    end
    local out = {}
    for i = 1, (count or 5) do
        if #pool == 0 then break end
        local role = pool[rng:int(1, #pool)]
        out[i] = ships.generate(Rng.hash(seed, i, role), role)
    end
    return out
end

return ships

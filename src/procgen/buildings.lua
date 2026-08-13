-- Procedural buildings.
--
-- The brief is "polygonal, but very detailed".  The way to get both is to
-- spend the triangles on *structure* rather than on smoothness: setbacks,
-- plinths, window bands, roof plant, railings, external ducting, gantries and
-- signage.  A tower here is 25 flat-shaded masses and 200 window quads, which
-- reads as an architectural model rather than as a box.
--
-- Every generator writes into two builders:
--   solid  the lit structure
--   glow   windows, signs and lamps, drawn with the emissive channel so a
--          settlement lights up at night
--
-- Local space: origin at the centre of the footprint, +Y up, base at y = 0.
-- Each generator returns { radius, height, entrance, interior } so the
-- settlement layout can space buildings out and place walkable doors.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local geometry = require("src.render.geometry")
local palette = require("src.render.palette")

local buildings = {}

local cos, sin, pi, max, min, floor = math.cos, math.sin, math.pi, math.max, math.min, math.floor
local TAU = pi * 2
local C = palette.colors

-- ---------------------------------------------------------------------------
-- Shared detail helpers
-- ---------------------------------------------------------------------------

--- A quad facing +Z, centred on the origin.  The unit of all surface detail.
local function panel(b, w, h, col)
    b:quad(-w * 0.5, -h * 0.5, 0, w * 0.5, -h * 0.5, 0, w * 0.5, h * 0.5, 0, -w * 0.5, h * 0.5, 0, col)
end

--- Runs `fn(halfSpan, offset)` once per side of a rectangular plan, with the
--- builder already rotated and translated onto that facade.
local function forEachFacade(b, w, d, fn)
    local sides = {
        { rot = 0,        span = w, off = d * 0.5 },
        { rot = pi * 0.5, span = d, off = w * 0.5 },
        { rot = pi,       span = w, off = d * 0.5 },
        { rot = pi * 1.5, span = d, off = w * 0.5 },
    }
    for i, s in ipairs(sides) do
        b:push()
        b:rotateY(s.rot)
        b:translate(0, 0, s.off)
        fn(s.span, i, s.off)
        b:pop()
    end
end

--- Window bands on all four facades between two heights.
local function windowBands(g, w, d, y0, y1, floors, col, opts)
    opts = opts or {}
    local inset = opts.inset or 0.06
    local floorH = (y1 - y0) / max(floors, 1)
    local wh = floorH * (opts.fill or 0.42)
    local rng = opts.rng
    forEachFacade(g, w + inset * 2, d + inset * 2, function(span)
        local cols = max(1, floor(span / (opts.spacing or 2.6)))
        local ww = (span / cols) * (opts.width or 0.55)
        for f = 0, floors - 1 do
            local y = y0 + floorH * (f + 0.5)
            for c = 0, cols - 1 do
                local x = -span * 0.5 + span * (c + 0.5) / cols
                local lit = col
                if rng then
                    if rng:bool(opts.dark or 0.22) then
                        lit = palette.shade(col, 0.16)
                    elseif rng:bool(0.2) then
                        lit = palette.shade(col, 1.25)
                    end
                end
                g:push():translate(x, y, 0)
                panel(g, ww, wh, lit)
                g:pop()
            end
        end
    end)
end

--- A recessed doorway with a frame and a lit sign.  Returns the entrance
--- point in local space plus the outward direction, for the walking player.
local function doorway(b, g, w, d, height, col, signCol, rng)
    local side = rng and rng:int(1, 4) or 1
    local rot = (side - 1) * pi * 0.5
    local off = (side % 2 == 1) and d * 0.5 or w * 0.5
    local dw = min(3.4, (side % 2 == 1 and w or d) * 0.35)
    local dh = min(3.6, height * 0.6)

    b:push()
    b:rotateY(rot)
    b:translate(0, 0, off)
    -- frame
    b:push():translate(0, dh * 0.5, 0.06)
    geometry.box(b, dw + 0.6, dh + 0.5, 0.34, col)
    b:pop()
    -- recess
    b:push():translate(0, dh * 0.5, -0.1)
    geometry.box(b, dw, dh, 0.5, palette.shade(col, 0.45))
    b:pop()
    -- steps
    for i = 1, 3 do
        b:push():translate(0, (i - 1) * 0.16 + 0.08, 0.3 + (3 - i) * 0.32)
        geometry.box(b, dw + 1.0 + (3 - i) * 0.2, 0.16, 0.62, palette.shade(col, 0.8))
        b:pop()
    end
    b:pop()

    if g then
        g:push()
        g:rotateY(rot)
        g:translate(0, dh + 0.7, off + 0.26)
        panel(g, dw * 1.15, 0.5, signCol or C.uiPrimary)
        g:pop()
        -- door light
        g:push()
        g:rotateY(rot)
        g:translate(0, dh * 0.55, off + 0.26)
        panel(g, dw * 0.9, dh * 0.8, palette.shade(signCol or C.glassLit, 0.75))
        g:pop()
    end

    local dirx, dirz = sin(rot), cos(rot)
    return {
        x = dirx * (off + 1.6),
        y = 0,
        z = dirz * (off + 1.6),
        dx = dirx, dz = dirz,
        width = dw,
    }
end

--- Handrail around a roof or a platform.
local function railing(b, w, d, y, col, posts)
    local h = 1.05
    local hw, hd = w * 0.5, d * 0.5
    local corners = { { -hw, -hd }, { hw, -hd }, { hw, hd }, { -hw, hd } }
    for i = 1, 4 do
        local a, c = corners[i], corners[i % 4 + 1]
        geometry.beam(b, a[1], y + h, a[2], c[1], y + h, c[2], 0.09, col)
        geometry.beam(b, a[1], y + h * 0.5, a[2], c[1], y + h * 0.5, c[2], 0.06, col)
        local n = posts or 4
        for k = 0, n do
            local t = k / n
            local px = a[1] + (c[1] - a[1]) * t
            local pz = a[2] + (c[2] - a[2]) * t
            geometry.beam(b, px, y, pz, px, y + h, pz, 0.07, col)
        end
    end
end

--- Rooftop machinery: the single cheapest way to make a block look inhabited.
local function roofPlant(b, g, w, d, y, rng, col, accent)
    local n = rng:int(2, 6)
    for _ = 1, n do
        local sw = rng:range(0.8, min(w, d) * 0.3)
        local sd = rng:range(0.8, min(w, d) * 0.3)
        local sh = rng:range(0.5, 2.2)
        local x = rng:range(-w * 0.5 + sw, w * 0.5 - sw)
        local z = rng:range(-d * 0.5 + sd, d * 0.5 - sd)
        b:push():translate(x, y, z)
        local roll = rng:float()
        if roll < 0.45 then
            geometry.boxStanding(b, sw, sh, sd, col, palette.shade(col, 0.7))
            -- vent grille
            for k = 1, 3 do
                b:push():translate(0, sh * (k / 4), sd * 0.5 + 0.02)
                panel(b, sw * 0.8, sh * 0.12, palette.shade(col, 0.5))
                b:pop()
            end
        elseif roll < 0.7 then
            geometry.cylinder(b, sw * 0.5, sh, 8, col, palette.shade(col, 0.8), 1, true)
        elseif roll < 0.88 then
            geometry.truss(b, sw * 0.8, sh * 2.2, 3, 0.07, col)
        else
            geometry.cylinder(b, 0.09, sh * 3.2, 5, accent, accent, 0.5, true)
            if g then
                g:push():translate(0, sh * 3.2, 0)
                geometry.sphere(g, 0.22, 6, 4, C.red)
                g:pop()
            end
        end
        b:pop()
    end
end

--- Exterior ducting climbing a facade.
local function facadeDucts(b, w, d, height, rng, col)
    for _ = 1, rng:int(1, 3) do
        local side = rng:int(1, 4)
        local rot = (side - 1) * pi * 0.5
        local off = (side % 2 == 1) and d * 0.5 or w * 0.5
        local span = (side % 2 == 1) and w or d
        local x = rng:range(-span * 0.35, span * 0.35)
        local r = rng:range(0.16, 0.34)
        local top = height * rng:range(0.6, 1.0)
        b:push()
        b:rotateY(rot)
        b:translate(x, 0, off + r * 0.7)
        geometry.cylinder(b, r, top, 6, col, col, 1, false)
        for k = 1, floor(top / 3) do
            b:push():translate(0, k * 3, 0)
            geometry.cylinder(b, r * 1.35, 0.24, 6, palette.shade(col, 0.7), palette.shade(col, 0.7), 1, true)
            b:pop()
        end
        b:pop()
    end
end

--- Antenna mast with guy wires and a beacon.
local function antenna(b, g, height, rng, col)
    geometry.truss(b, 0.7, height, max(3, floor(height / 3)), 0.06, col)
    b:push():translate(0, height, 0)
    geometry.cylinder(b, 0.07, height * 0.25, 5, col, col, 0.4, true)
    b:pop()
    if g then
        g:push():translate(0, height * 1.25, 0)
        geometry.sphere(g, 0.3, 6, 4, C.red)
        g:pop()
    end
    for i = 0, 2 do
        local a = i / 3 * TAU + rng:range(0, 1)
        geometry.beam(b, 0, height * 0.75, 0, cos(a) * height * 0.35, 0, sin(a) * height * 0.35, 0.04, col)
    end
end

--- Storage tank with ribs and a walkway.
local function tank(b, r, h, rng, col, accent)
    geometry.cylinder(b, r, h, 12, col, palette.shade(col, 0.8), 1, true)
    geometry.lathe(b, { { r, h }, { r * 0.8, h + r * 0.24 }, { r * 0.45, h + r * 0.36 }, { 0, h + r * 0.4 } }, 12, palette.shade(col, 0.9))
    for k = 1, 3 do
        b:push():translate(0, h * k / 4, 0)
        geometry.cylinder(b, r * 1.04, 0.16, 12, palette.shade(col, 0.65), nil, 1, false)
        b:pop()
    end
    -- ladder
    b:push():translate(r * 1.02, 0, 0)
    for k = 0, floor(h / 0.5) do
        b:push():translate(0, k * 0.5, 0)
        geometry.box(b, 0.36, 0.05, 0.05, accent)
        b:pop()
    end
    geometry.beam(b, 0, 0, -0.16, 0, h, -0.16, 0.05, accent)
    geometry.beam(b, 0, 0, 0.16, 0, h, 0.16, 0.05, accent)
    b:pop()
    -- top walkway
    railing(b, r * 1.6, r * 1.6, h + r * 0.05, accent, 3)
end

--- Pipe run between two points, with elbows.
local function pipeRun(b, x0, y0, z0, x1, y1, z1, r, col)
    local my = max(y0, y1) + r * 3
    geometry.beam(b, x0, y0, z0, x0, my, z0, r * 2, col)
    geometry.beam(b, x0, my, z0, x1, my, z1, r * 2, col)
    geometry.beam(b, x1, my, z1, x1, y1, z1, r * 2, col)
end

-- ---------------------------------------------------------------------------
-- Building kinds
-- ---------------------------------------------------------------------------

local kinds = {}
buildings.kinds = kinds

local function register(id, name, opts)
    local k = { id = id, name = name }
    for key, v in pairs(opts) do k[key] = v end
    kinds[#kinds + 1] = k
    kinds[id] = k
    return k
end

--- Residential / administrative tower: stacked setbacks, window bands,
--- balconies, roof plant.
register("hab", "Habitation Block", {
    weight = 30, minTier = 1, footprint = { 10, 22 }, enterable = true, interior = "lobby",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.6, 1.1)
        local tiers = rng:int(2, 3 + o.tier)
        local col = o.colors.wall
        local trim = o.colors.trim
        local y = 0
        local cw, cd = w, d

        -- plinth
        geometry.boxStanding(b, w * 1.12, 0.6, d * 1.12, palette.shade(col, 0.7), trim)
        y = 0.6

        local total = 0
        for t = 1, tiers do
            local floors = rng:int(2, 5)
            local h = floors * 3.1
            geometry.frustumBox(b, cw, cd, cw * rng:range(0.95, 1.0), cd * rng:range(0.95, 1.0), h,
                (t % 2 == 0) and palette.shade(col, 0.9) or col, trim)
            windowBands(g, cw, cd, y + 1.0, y + h - 0.6, floors, o.colors.window, { rng = rng, spacing = 2.4 })
            -- floor separators
            for f = 1, floors - 1 do
                b:push():translate(0, y + f * 3.1, 0)
                geometry.box(b, cw + 0.14, 0.18, cd + 0.14, trim)
                b:pop()
            end
            -- balconies on one facade
            if rng:bool(0.6) then
                local rot = rng:int(0, 3) * pi * 0.5
                for f = 1, floors - 1 do
                    b:push()
                    b:rotateY(rot)
                    b:translate(0, y + f * 3.1, (rot % pi == 0 and cd or cw) * 0.5 + 0.5)
                    geometry.box(b, cw * 0.55, 0.14, 1.0, trim)
                    railing(b, cw * 0.55, 1.0, 0.07, trim, 3)
                    b:pop()
                end
            end
            b:push():translate(0, y, 0)
            b:pop()
            -- move up and set back
            local prevW, prevD = cw, cd
            y = y + h
            cw = cw * rng:range(0.68, 0.9)
            cd = cd * rng:range(0.68, 0.9)
            -- roof slab of the setback
            b:push():translate(0, y, 0)
            geometry.box(b, prevW + 0.3, 0.3, prevD + 0.3, trim)
            b:pop()
            if t < tiers then
                railing(b, prevW, prevD, y + 0.15, trim, 5)
            end
            total = y
        end

        facadeDucts(b, w, d, total * 0.8, rng, palette.shade(col, 0.65))
        roofPlant(b, g, cw, cd, total, rng, palette.shade(col, 0.8), o.colors.accent)
        railing(b, cw, cd, total + 0.15, trim, 4)
        if rng:bool(0.4) then
            b:push():translate(cw * 0.3, total, cd * 0.3)
            antenna(b, g, rng:range(5, 14), rng, trim)
            b:pop()
        end

        local entrance = doorway(b, g, w, d, 4, trim, o.colors.sign, rng)
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 2, height = total, entrance = entrance }
    end,
})

--- Habitat dome: ribbed geodesic shell with visible interior structures.
register("dome", "Habitat Dome", {
    weight = 18, minTier = 1, footprint = { 12, 26 }, enterable = true, interior = "garden",
    build = function(b, g, rng, o)
        local r = rng:range(o.footprint[1], o.footprint[2]) * 0.5
        local h = r * rng:range(0.7, 1.05)
        local col = o.colors.wall
        local trim = o.colors.trim

        -- ring wall
        geometry.cylinder(b, r, h * 0.22, 16, palette.shade(col, 0.85), trim, 1, false)
        -- glass shell (drawn as facets in the glow layer so it catches light)
        local segs, rings = 16, 5
        geometry.dome(g, r * 0.99, h, segs, rings, palette.shade(o.colors.glass, 1.0))
        -- structural ribs
        for i = 0, segs - 1 do
            local a = i / segs * TAU
            local px, pz = cos(a) * r, sin(a) * r
            local prev = { px, 0, pz }
            for j = 1, rings do
                local t = (j / rings) * (pi * 0.5)
                local rr, yy = cos(t) * r, sin(t) * h
                local nx, ny, nz = cos(a) * rr, yy, sin(a) * rr
                geometry.beam(b, prev[1], prev[2] + h * 0.22, prev[3], nx, ny + h * 0.22, nz, 0.22, trim)
                prev = { nx, ny, nz }
            end
        end
        for j = 1, rings - 1 do
            local t = (j / rings) * (pi * 0.5)
            local rr, yy = cos(t) * r, sin(t) * h + h * 0.22
            local segs2 = 16
            for i = 0, segs2 - 1 do
                local a0, a1 = i / segs2 * TAU, (i + 1) / segs2 * TAU
                geometry.beam(b, cos(a0) * rr, yy, sin(a0) * rr, cos(a1) * rr, yy, sin(a1) * rr, 0.16, trim)
            end
        end
        -- interior: a few planters and a mast, visible through the glass
        for _ = 1, rng:int(3, 7) do
            local a = rng:range(0, TAU)
            local rr = rng:range(0, r * 0.7)
            b:push():translate(cos(a) * rr, h * 0.22, sin(a) * rr)
            geometry.cylinder(b, rng:range(0.6, 1.6), rng:range(0.4, 1.2), 8, C.moss, C.darkGreen, 1, true)
            b:pop()
        end
        b:push():translate(0, h * 0.22, 0)
        geometry.cylinder(b, 0.5, h * 0.75, 8, trim, trim, 0.4, true)
        b:pop()

        local entrance = doorway(b, g, r * 2, r * 2, 3.2, trim, o.colors.sign, rng)
        return { radius = r + 2, height = h + h * 0.22, entrance = entrance }
    end,
})

--- Factory hall: sawtooth roof, chimneys, external ducts, loading bays.
register("factory", "Manufactory", {
    weight = 22, minTier = 2, footprint = { 18, 34 }, enterable = true, interior = "workshop",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.6, 1.0)
        local h = rng:range(7, 12)
        local col = o.colors.wall
        local trim = o.colors.trim

        geometry.boxStanding(b, w, h, d, col, palette.shade(col, 0.8))
        -- sawtooth roof with glazing facing one way
        local teeth = rng:int(3, 6)
        local tw = w / teeth
        for i = 0, teeth - 1 do
            local x = -w * 0.5 + tw * (i + 0.5)
            b:push():translate(x, h, 0)
            b:tri(-tw * 0.5, 0, -d * 0.5, tw * 0.5, 0, -d * 0.5, -tw * 0.5, tw * 0.55, -d * 0.5, palette.shade(col, 0.9))
            b:tri(-tw * 0.5, 0, d * 0.5, -tw * 0.5, tw * 0.55, d * 0.5, tw * 0.5, 0, d * 0.5, palette.shade(col, 0.9))
            b:quad(-tw * 0.5, tw * 0.55, -d * 0.5, tw * 0.5, 0, -d * 0.5, tw * 0.5, 0, d * 0.5, -tw * 0.5, tw * 0.55, d * 0.5, palette.shade(col, 0.75))
            b:pop()
            g:push():translate(x - tw * 0.5 + 0.06, h + tw * 0.28, 0)
            b:push():translate(0, 0, 0):pop()
            g:rotateY(pi * 0.5)
            panel(g, d * 0.94, tw * 0.5, o.colors.window)
            g:pop()
        end
        -- chimneys
        for i = 1, rng:int(1, 3) do
            local x = rng:range(-w * 0.35, w * 0.35)
            local z = rng:range(-d * 0.35, d * 0.35)
            local ch = rng:range(8, 22)
            b:push():translate(x, h, z)
            geometry.cylinder(b, rng:range(0.7, 1.4), ch, 8, palette.shade(col, 0.7), trim, 0.9, false)
            b:push():translate(0, ch, 0)
            geometry.cylinder(b, 1.1, 0.8, 8, trim, palette.shade(trim, 0.6), 1.15, true)
            b:pop()
            b:pop()
        end
        -- loading bays
        forEachFacade(b, w, d, function(span, i)
            if i ~= 1 then return end
            local bays = max(1, floor(span / 7))
            for k = 0, bays - 1 do
                local x = -span * 0.5 + span * (k + 0.5) / bays
                b:push():translate(x, 2.1, 0.15)
                geometry.box(b, 4.2, 4.2, 0.4, palette.shade(col, 0.5))
                b:pop()
                b:push():translate(x, 4.4, 1.0)
                geometry.box(b, 5.0, 0.3, 2.0, trim)
                b:pop()
            end
        end)
        facadeDucts(b, w, d, h, rng, trim)
        -- external conveyor
        if rng:bool(0.6) then
            b:push():translate(w * 0.5, h * 0.55, 0)
            b:rotateZ(-0.22)
            geometry.truss(b, 1.6, 12, 4, 0.09, trim)
            b:pop()
        end
        windowBands(g, w, d, h * 0.55, h * 0.85, 1, o.colors.window, { rng = rng, spacing = 3.4, fill = 0.5 })
        roofPlant(b, g, w * 0.6, d * 0.6, h, rng, palette.shade(col, 0.8), o.colors.accent)

        local entrance = doorway(b, g, w, d, 4, trim, o.colors.sign, rng)
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 2, height = h + 8, entrance = entrance }
    end,
})

--- Refinery: tank farm, fractionating columns, flare stack, pipe bridges.
register("refinery", "Refinery", {
    weight = 16, minTier = 2, footprint = { 20, 38 }, enterable = false,
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.7, 1.0)
        local col = o.colors.wall
        local trim = o.colors.trim
        local accent = o.colors.accent

        geometry.slab(b, w, d, 0.12, palette.shade(col, 0.55))
        local anchors = {}
        local tanks = rng:int(2, 4)
        for i = 1, tanks do
            local a = (i - 1) / tanks * TAU + rng:range(-0.3, 0.3)
            local rr = min(w, d) * 0.3
            local x, z = cos(a) * rr, sin(a) * rr
            local tr = rng:range(2.4, 4.2)
            local th = rng:range(5, 11)
            b:push():translate(x, 0.12, z)
            tank(b, tr, th, rng, palette.shade(col, 1.0), accent)
            b:pop()
            anchors[#anchors + 1] = { x, th * 0.6, z }
        end
        -- fractionating columns
        for i = 1, rng:int(1, 3) do
            local x = rng:range(-w * 0.3, w * 0.3)
            local z = rng:range(-d * 0.3, d * 0.3)
            local ch = rng:range(14, 26)
            b:push():translate(x, 0.12, z)
            geometry.cylinder(b, rng:range(1.0, 1.8), ch, 10, trim, palette.shade(trim, 0.7), 0.9, true)
            for k = 1, floor(ch / 4) do
                b:push():translate(0, k * 4, 0)
                geometry.cylinder(b, 2.0, 0.28, 10, palette.shade(trim, 0.6), nil, 1, false)
                b:pop()
            end
            b:pop()
            anchors[#anchors + 1] = { x, ch * 0.5, z }
        end
        -- flare stack
        local fx, fz = w * 0.42, d * 0.42
        b:push():translate(fx, 0.12, fz)
        geometry.truss(b, 1.4, 26, 8, 0.08, trim)
        b:pop()
        g:push():translate(fx, 27.5, fz)
        geometry.cone(g, 0.9, 2.6, 6, C.orange, C.orange)
        g:pop()
        -- pipe bridges between anchors
        for i = 1, #anchors - 1 do
            local a, c = anchors[i], anchors[i + 1]
            pipeRun(b, a[1], a[2], a[3], c[1], c[2], c[3], 0.18, accent)
        end
        -- control shed
        b:push():translate(-w * 0.36, 0.12, -d * 0.36)
        geometry.boxStanding(b, 6, 3.4, 4.5, col, trim)
        b:pop()
        g:push():translate(-w * 0.36, 2.0, -d * 0.36 + 2.3)
        panel(g, 4.2, 1.0, o.colors.window)
        g:pop()

        return { radius = math.sqrt(w * w + d * d) * 0.5 + 3, height = 28 }
    end,
})

--- Warehouse with a container yard and dock canopies.
register("warehouse", "Warehouse", {
    weight = 20, minTier = 1, footprint = { 16, 30 }, enterable = true, interior = "storage",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.5, 0.85)
        local h = rng:range(5, 8)
        local col = o.colors.wall
        local trim = o.colors.trim

        geometry.boxStanding(b, w, h, d, col, palette.shade(col, 0.85))
        -- barrel roof
        b:push():translate(0, h, 0)
        local profile = {}
        local segs = 7
        for i = 0, segs do
            local t = i / segs * pi
            profile[#profile + 1] = { cos(t) * w * 0.5, sin(t) * h * 0.34 }
        end
        for i = 1, segs do
            local a, c = profile[i], profile[i + 1]
            b:quad(a[1], a[2], -d * 0.5, c[1], c[2], -d * 0.5, c[1], c[2], d * 0.5, a[1], a[2], d * 0.5,
                (i % 2 == 0) and palette.shade(col, 0.9) or palette.shade(col, 0.78))
        end
        local endPts = {}
        for i = 1, #profile do endPts[i] = { profile[i][1], profile[i][2], d * 0.5 } end
        b:poly(endPts, trim)
        local endPts2 = {}
        for i = #profile, 1, -1 do endPts2[#endPts2 + 1] = { profile[i][1], profile[i][2], -d * 0.5 } end
        b:poly(endPts2, trim)
        b:pop()

        -- ribs
        for k = 1, 4 do
            local z = -d * 0.5 + d * k / 5
            b:push():translate(0, h, z)
            for i = 1, segs do
                local a, c = profile[i], profile[i + 1]
                geometry.beam(b, a[1], a[2], 0, c[1], c[2], 0, 0.16, trim)
            end
            b:pop()
        end

        -- dock doors and canopy
        forEachFacade(b, w, d, function(span, i)
            if i ~= 1 then return end
            local bays = max(2, floor(span / 6))
            for k = 0, bays - 1 do
                local x = -span * 0.5 + span * (k + 0.5) / bays
                b:push():translate(x, 2.0, 0.12)
                geometry.box(b, 3.6, 4.0, 0.3, palette.shade(col, 0.5))
                for r = 1, 5 do
                    b:push():translate(0, -2.0 + r * 0.66, 0.2)
                    geometry.box(b, 3.6, 0.12, 0.2, palette.shade(col, 0.65))
                    b:pop()
                end
                b:pop()
            end
            b:push():translate(0, 4.6, 1.4)
            geometry.box(b, span * 0.94, 0.24, 2.8, trim)
            b:pop()
            geometry.beam(b, -span * 0.42, 0, 2.6, -span * 0.42, 4.5, 2.6, 0.2, trim)
            geometry.beam(b, span * 0.42, 0, 2.6, span * 0.42, 4.5, 2.6, 0.2, trim)
        end)

        -- container stacks alongside
        local cx = w * 0.5 + 4
        for i = 1, rng:int(2, 5) do
            local stack = rng:int(1, 3)
            for s = 1, stack do
                b:push():translate(cx, (s - 1) * 2.6, -d * 0.4 + (i - 1) * 6.4)
                local cc = rng:pick({ C.rust, C.blue, C.darkGreen, C.amber, C.steel })
                geometry.boxStanding(b, 2.5, 2.5, 6.0, cc, palette.shade(cc, 0.7))
                for k = -1, 1 do
                    b:push():translate(0, 1.25, k * 2.0)
                    geometry.box(b, 2.56, 2.52, 0.14, palette.shade(cc, 0.6))
                    b:pop()
                end
                b:pop()
            end
        end

        windowBands(g, w, d, h * 0.6, h * 0.85, 1, o.colors.window, { rng = rng, spacing = 4, fill = 0.4 })
        local entrance = doorway(b, g, w, d, 3.6, trim, o.colors.sign, rng)
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 6, height = h * 1.4 }, entrance
    end,
})

--- Control tower: the settlement's landmark.
register("tower", "Control Tower", {
    weight = 8, minTier = 2, footprint = { 8, 12 }, unique = true, enterable = true, interior = "control",
    build = function(b, g, rng, o)
        local r = rng:range(o.footprint[1], o.footprint[2]) * 0.5
        local h = rng:range(22, 46)
        local col = o.colors.wall
        local trim = o.colors.trim

        geometry.cylinder(b, r * 1.5, 1.2, 12, palette.shade(col, 0.7), trim, 1, true)
        geometry.cylinder(b, r * 0.55, h, 10, col, trim, 0.82, false)
        -- stair helix around the shaft
        local steps = floor(h / 0.9)
        for i = 0, steps do
            local a = i * 0.42
            local rr = r * 0.62
            b:push():translate(cos(a) * rr, i * 0.9, sin(a) * rr)
            b:rotateY(-a)
            geometry.box(b, 1.3, 0.12, 0.55, trim)
            b:pop()
        end
        -- observation deck
        b:push():translate(0, h, 0)
        geometry.cylinder(b, r * 1.7, 1.1, 12, trim, palette.shade(trim, 0.8), 1.15, true)
        b:translate(0, 1.1, 0)
        geometry.lathe(g, { { r * 1.95, 0 }, { r * 2.0, 1.6 }, { r * 1.7, 3.0 } }, 12, o.colors.glass)
        geometry.lathe(b, { { r * 1.72, 3.0 }, { r * 1.9, 3.3 }, { r * 1.5, 4.1 }, { 0, 4.5 } }, 12, palette.shade(col, 0.9))
        for i = 0, 11 do
            local a = i / 12 * TAU
            geometry.beam(b, cos(a) * r * 1.95, 0, sin(a) * r * 1.95, cos(a) * r * 1.72, 3.0, sin(a) * r * 1.72, 0.14, trim)
        end
        b:pop()
        b:push():translate(0, h + 5.6, 0)
        antenna(b, g, rng:range(8, 16), rng, trim)
        b:pop()
        -- radar dish
        b:push():translate(r * 1.4, h + 4.6, 0)
        b:rotateZ(-0.6)
        geometry.lathe(b, { { 2.2, 0 }, { 1.9, 0.5 }, { 1.1, 0.8 }, { 0, 0.9 } }, 10, C.hullBright)
        b:pop()

        local entrance = doorway(b, g, r * 3, r * 3, 3.2, trim, o.colors.sign, rng)
        return { radius = r * 2.2 + 2, height = h + 12, entrance = entrance }
    end,
})

--- Hangar: arched shed with a split door and a windsock mast.
register("hangar", "Hangar", {
    weight = 12, minTier = 1, footprint = { 20, 34 }, enterable = true, interior = "hangar",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.7, 1.1)
        local h = rng:range(9, 14)
        local col = o.colors.wall
        local trim = o.colors.trim

        local segs = 9
        local profile = {}
        for i = 0, segs do
            local t = i / segs * pi
            profile[#profile + 1] = { cos(t) * w * 0.5, sin(t) * h }
        end
        for i = 1, segs do
            local a, c = profile[i], profile[i + 1]
            b:quad(a[1], a[2], -d * 0.5, c[1], c[2], -d * 0.5, c[1], c[2], d * 0.5, a[1], a[2], d * 0.5,
                (i % 3 == 0) and trim or col)
        end
        -- back wall
        local back = {}
        for i = #profile, 1, -1 do back[#back + 1] = { profile[i][1], profile[i][2], -d * 0.5 } end
        b:poly(back, palette.shade(col, 0.85))
        -- front frame with a gap for the doors
        for i = 1, segs do
            local a, c = profile[i], profile[i + 1]
            geometry.beam(b, a[1], a[2], d * 0.5, c[1], c[2], d * 0.5, 0.4, trim)
        end
        -- sliding doors, partly open
        local open = rng:range(0.15, 0.55)
        for _, side in ipairs({ 1, -1 }) do
            b:push():translate(side * (w * 0.25 + w * 0.25 * open), 0, d * 0.5 - 0.3)
            geometry.boxStanding(b, w * 0.5 - 0.4, h * 0.82, 0.5, palette.shade(col, 0.75), trim)
            for k = 1, 5 do
                b:push():translate(0, h * 0.82 * k / 6, 0.3)
                geometry.box(b, w * 0.5 - 0.4, 0.16, 0.2, trim)
                b:pop()
            end
            b:pop()
        end
        -- interior lights
        g:push():translate(0, h * 0.9, 0)
        for k = -1, 1 do
            g:push():translate(k * w * 0.25, 0, 0)
            panel(g, w * 0.2, d * 0.7, C.lamp)
            g:pop()
        end
        g:pop()
        -- mast
        b:push():translate(w * 0.5 + 2.5, 0, d * 0.4)
        antenna(b, g, rng:range(6, 11), rng, trim)
        b:pop()

        local entrance = { x = 0, y = 0, z = d * 0.5 + 2.0, dx = 0, dz = 1, width = 4 }
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 2, height = h, entrance = entrance }
    end,
})

--- Market hall: open colonnade with awnings and stalls.
register("market", "Market Hall", {
    weight = 14, minTier = 2, footprint = { 16, 28 }, enterable = true, interior = "market",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.6, 0.9)
        local h = rng:range(5.5, 8)
        local col = o.colors.wall
        local trim = o.colors.trim

        geometry.slab(b, w * 1.1, d * 1.1, 0.2, palette.shade(col, 0.6))
        -- colonnade
        local cols = max(3, floor(w / 4))
        for i = 0, cols do
            local x = -w * 0.5 + w * i / cols
            for _, z in ipairs({ -d * 0.5, d * 0.5 }) do
                b:push():translate(x, 0.2, z)
                geometry.cylinder(b, 0.42, h, 8, col, trim, 0.92, true)
                b:push():translate(0, h, 0)
                geometry.cylinder(b, 0.62, 0.4, 8, trim, trim, 1, true)
                b:pop()
                b:pop()
            end
        end
        -- roof
        b:push():translate(0, h + 0.4, 0)
        geometry.box(b, w * 1.1, 0.5, d * 1.15, trim, palette.shade(trim, 1.1))
        b:translate(0, 0.5, 0)
        local rp = { { w * 0.55, 0 }, { w * 0.36, 1.6 }, { 0, 2.4 } }
        for i = 1, #rp - 1 do
            local a, c = rp[i], rp[i + 1]
            b:quad(-a[1], a[2], -d * 0.58, a[1], a[2], -d * 0.58, c[1], c[2], -d * 0.58, -c[1], c[2], -d * 0.58, palette.shade(col, 0.9))
            b:quad(-c[1], c[2], d * 0.58, c[1], c[2], d * 0.58, a[1], a[2], d * 0.58, -a[1], a[2], d * 0.58, palette.shade(col, 0.9))
            b:quad(a[1], a[2], -d * 0.58, a[1], a[2], d * 0.58, c[1], c[2], d * 0.58, c[1], c[2], -d * 0.58, palette.shade(col, 0.82))
            b:quad(-a[1], a[2], d * 0.58, -a[1], a[2], -d * 0.58, -c[1], c[2], -d * 0.58, -c[1], c[2], d * 0.58, palette.shade(col, 0.82))
        end
        b:pop()
        -- stalls
        for i = 1, rng:int(4, 9) do
            local x = rng:range(-w * 0.4, w * 0.4)
            local z = rng:range(-d * 0.35, d * 0.35)
            b:push():translate(x, 0.2, z)
            b:rotateY(rng:range(0, TAU))
            geometry.boxStanding(b, 2.2, 1.0, 1.4, palette.shade(col, 0.8), trim)
            local awn = rng:pick({ C.red, C.orange, C.teal, C.green, C.amber })
            b:push():translate(0, 2.3, 0)
            b:rotateX(0.25)
            geometry.box(b, 2.6, 0.1, 1.9, awn)
            b:pop()
            geometry.beam(b, -1.1, 1.0, -0.8, -1.1, 2.3, -0.8, 0.08, trim)
            geometry.beam(b, 1.1, 1.0, -0.8, 1.1, 2.3, -0.8, 0.08, trim)
            b:pop()
        end
        g:push():translate(0, h + 1.2, d * 0.58 + 0.05)
        panel(g, w * 0.5, 1.1, o.colors.sign)
        g:pop()

        local entrance = { x = 0, y = 0, z = d * 0.5 + 2.5, dx = 0, dz = 1, width = 5 }
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 2, height = h + 3, entrance = entrance }
    end,
})

--- Fusion plant: containment dome, cooling towers, switchyard.
register("power", "Power Plant", {
    weight = 10, minTier = 2, footprint = { 18, 30 }, enterable = false,
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local col = o.colors.wall
        local trim = o.colors.trim
        geometry.slab(b, w * 1.2, w * 1.0, 0.14, palette.shade(col, 0.55))

        local r = w * 0.22
        geometry.cylinder(b, r, r * 0.9, 14, palette.shade(col, 0.9), trim, 1, false)
        b:push():translate(0, r * 0.9, 0)
        geometry.dome(b, r, r * 0.8, 14, 5, palette.shade(col, 1.05))
        b:pop()
        for i = 0, 5 do
            local a = i / 6 * TAU
            geometry.beam(b, cos(a) * r, 0, sin(a) * r, cos(a) * r * 0.2, r * 1.7, sin(a) * r * 0.2, 0.22, trim)
        end
        -- cooling towers: hyperboloid lathes
        for i = 1, rng:int(1, 3) do
            local a = (i - 1) / 3 * TAU + 0.6
            local x, z = cos(a) * w * 0.42, sin(a) * w * 0.42
            local th = rng:range(12, 20)
            local tr = th * 0.24
            b:push():translate(x, 0.14, z)
            geometry.lathe(b, {
                { tr, 0 }, { tr * 0.74, th * 0.35 }, { tr * 0.62, th * 0.6 },
                { tr * 0.68, th * 0.85 }, { tr * 0.78, th },
            }, 14, palette.shade(col, 0.95))
            geometry.lathe(b, { { tr * 0.78, th }, { tr * 0.72, th + 0.4 } }, 14, trim)
            b:pop()
        end
        -- switchyard
        for i = 1, rng:int(3, 6) do
            local x = rng:range(-w * 0.5, w * 0.5)
            local z = rng:range(-w * 0.48, -w * 0.3)
            b:push():translate(x, 0.14, z)
            geometry.truss(b, 1.2, rng:range(4, 8), 3, 0.07, trim)
            b:pop()
        end
        g:push():translate(0, r * 1.75, 0)
        geometry.sphere(g, r * 0.16, 8, 5, C.cyan)
        g:pop()
        return { radius = w * 0.66, height = 22 }
    end,
})

--- Mine head: headframe, conveyor, spoil heap, ore bins.
register("mine", "Mine Head", {
    weight = 16, minTier = 1, footprint = { 16, 28 }, enterable = true, interior = "workshop",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local col = o.colors.wall
        local trim = o.colors.trim
        local accent = o.colors.accent

        -- shaft collar
        geometry.cylinder(b, 3.2, 1.0, 10, palette.shade(col, 0.7), C.black, 0.9, true)
        -- headframe
        local hh = rng:range(14, 24)
        geometry.truss(b, 5.5, hh, 6, 0.16, trim)
        b:push():translate(0, hh, 0)
        geometry.box(b, 6.4, 1.2, 3.0, trim)
        b:pop()
        -- sheave wheels
        for _, side in ipairs({ -1, 1 }) do
            b:push():translate(side * 1.6, hh + 1.4, 0)
            b:rotateX(pi * 0.5)
            geometry.cylinder(b, 1.9, 0.4, 12, accent, palette.shade(accent, 0.6), 1, true)
            b:pop()
        end
        -- back-leg brace
        geometry.beam(b, 0, hh, 0, 0, 0, w * 0.42, 0.5, trim)
        geometry.beam(b, -2, hh * 0.6, 0, 0, 0, w * 0.42, 0.32, trim)
        geometry.beam(b, 2, hh * 0.6, 0, 0, 0, w * 0.42, 0.32, trim)
        -- ore bin + conveyor
        b:push():translate(-w * 0.36, 0, -w * 0.2)
        geometry.frustumBox(b, 8, 6, 5, 4, 7, palette.shade(col, 0.9), trim)
        b:push():translate(0, 7, 0)
        geometry.box(b, 8.4, 0.4, 6.4, trim)
        b:pop()
        b:pop()
        b:push():translate(-w * 0.18, 3.5, -w * 0.1)
        b:rotateY(0.5)
        b:rotateZ(0.34)
        geometry.truss(b, 1.5, 14, 5, 0.09, trim)
        b:pop()
        -- spoil heap
        b:push():translate(w * 0.4, 0, w * 0.3)
        geometry.cone(b, rng:range(6, 10), rng:range(3, 6), 9, C.rockDry, C.ash)
        b:pop()
        -- winder house
        b:push():translate(w * 0.28, 0, -w * 0.3)
        geometry.boxStanding(b, 7, 4.2, 5, col, trim)
        b:pop()
        g:push():translate(w * 0.28, 2.2, -w * 0.3 + 2.6)
        panel(g, 5, 1.2, o.colors.window)
        g:pop()
        g:push():translate(0, hh + 2.6, 0)
        geometry.sphere(g, 0.3, 6, 4, C.red)
        g:pop()

        local entrance = { x = w * 0.28, y = 0, z = -w * 0.3 + 3.4, dx = 0, dz = 1, width = 3 }
        return { radius = w * 0.62, height = hh + 3, entrance = entrance }
    end,
})

--- Garrison: bunker, walls, turret cupolas.
register("garrison", "Garrison", {
    weight = 9, minTier = 2, footprint = { 16, 26 }, enterable = true, interior = "barracks",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.7, 1.0)
        local h = rng:range(4.5, 7)
        local col = palette.shade(o.colors.wall, 0.85)
        local trim = o.colors.trim

        geometry.frustumBox(b, w, d, w * 0.86, d * 0.86, h, col, palette.shade(col, 0.9))
        -- glacis
        geometry.frustumBox(b, w * 1.25, d * 1.25, w * 1.02, d * 1.02, 1.6, palette.shade(col, 0.7))
        -- firing slits
        forEachFacade(g, w * 0.93, d * 0.93, function(span)
            local n = max(2, floor(span / 5))
            for k = 0, n - 1 do
                g:push():translate(-span * 0.5 + span * (k + 0.5) / n, h * 0.62, 0)
                panel(g, span / n * 0.5, 0.4, palette.shade(C.uiDanger, 0.5))
                g:pop()
            end
        end)
        -- corner turrets
        for i = 1, 4 do
            local a = (i - 0.5) / 4 * TAU
            local x, z = cos(a) * w * 0.42, sin(a) * d * 0.42
            b:push():translate(x, h, z)
            geometry.cylinder(b, 1.7, 1.2, 8, trim, palette.shade(trim, 0.8), 0.85, true)
            b:translate(0, 1.2, 0)
            geometry.dome(b, 1.5, 1.0, 8, 3, col)
            b:push():translate(0, 0.5, 0)
            b:rotateY(rng:range(0, TAU))
            b:rotateX(pi * 0.5)
            geometry.cylinder(b, 0.16, 3.4, 6, C.hullDark, C.hullDark, 0.8, true)
            b:pop()
            b:pop()
        end
        -- perimeter posts
        for i = 0, 11 do
            local a = i / 12 * TAU
            b:push():translate(cos(a) * w * 0.72, 0, sin(a) * d * 0.72)
            geometry.box(b, 0.5, 2.4, 0.5, trim)
            b:pop()
        end
        -- flag mast
        b:push():translate(-w * 0.3, h, d * 0.3)
        geometry.cylinder(b, 0.12, 8, 5, trim, trim, 1, true)
        b:pop()
        g:push():translate(-w * 0.3 + 1.2, h + 6.6, d * 0.3)
        panel(g, 2.4, 1.4, o.colors.factionColor or C.red)
        g:pop()

        local entrance = doorway(b, g, w, d, 3.4, trim, C.uiDanger, rng)
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 3, height = h + 4, entrance = entrance }
    end,
})

--- Research campus: clean slabs, dish array, cooling fins.
register("lab", "Research Campus", {
    weight = 10, minTier = 3, footprint = { 14, 26 }, enterable = true, interior = "lab",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.6, 0.9)
        local col = C.hullBright
        local trim = o.colors.trim
        local h = rng:range(8, 16)

        geometry.boxStanding(b, w, 0.8, d, palette.shade(col, 0.7), trim)
        b:push():translate(0, 0.8, 0)
        geometry.frustumBox(b, w * 0.9, d * 0.9, w * 0.9, d * 0.9, h, col, trim)
        b:pop()
        -- glazed band
        windowBands(g, w * 0.9, d * 0.9, 1.4, h, max(2, floor(h / 3.4)), o.colors.glass,
            { rng = rng, spacing = 1.8, width = 0.85, fill = 0.6, dark = 0.05 })
        -- cantilevered wing
        b:push():translate(w * 0.45, h * 0.45, 0)
        geometry.box(b, w * 0.5, 3.2, d * 0.5, palette.shade(col, 0.92), trim)
        b:pop()
        geometry.beam(b, w * 0.62, h * 0.45 - 1.6, 0, w * 0.62, 0, 0, 0.5, trim)
        -- dish array on the roof
        for i = 1, rng:int(2, 4) do
            local x = rng:range(-w * 0.35, w * 0.35)
            local z = rng:range(-d * 0.35, d * 0.35)
            b:push():translate(x, h + 0.8, z)
            geometry.cylinder(b, 0.2, 1.2, 6, trim, trim, 1, true)
            b:translate(0, 1.2, 0)
            b:rotateZ(rng:range(-0.7, 0.7))
            b:rotateX(rng:range(-0.4, 0.4))
            local dr = rng:range(1.4, 2.8)
            geometry.lathe(b, { { dr, 0 }, { dr * 0.85, dr * 0.22 }, { dr * 0.5, dr * 0.34 }, { 0, dr * 0.38 } }, 12, C.white)
            b:pop()
        end
        -- cooling fins standing against the west wall
        for i = 1, 6 do
            b:push():translate(-w * 0.5 - 0.35 - i * 0.34, 0.8, 0)
            geometry.boxStanding(b, 0.3, h * 0.7, d * 0.8 - i * 0.1, palette.shade(trim, 0.9))
            b:pop()
        end
        g:push():translate(0, h + 0.4, d * 0.46)
        panel(g, w * 0.4, 0.8, C.cyan)
        g:pop()

        local entrance = doorway(b, g, w, d, 3.6, trim, C.cyan, rng)
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 3, height = h + 5, entrance = entrance }
    end,
})

--- Greenhouse / agridome row.
register("farm", "Agri Domes", {
    weight = 14, minTier = 1, footprint = { 18, 32 }, enterable = true, interior = "garden",
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.5, 0.8)
        local trim = o.colors.trim
        local rows = rng:int(2, 4)
        for i = 1, rows do
            local z = (i - (rows + 1) * 0.5) * (d / rows) * 1.1
            local len = w * rng:range(0.7, 0.95)
            local r = (d / rows) * 0.34
            b:push():translate(0, 0, z)
            -- barrel vault
            local segs = 7
            for s = 1, segs do
                local t0, t1 = (s - 1) / segs * pi, s / segs * pi
                local x0, y0 = cos(t0) * r, sin(t0) * r
                local x1, y1 = cos(t1) * r, sin(t1) * r
                g:quad(x0, y0, -len * 0.5, x1, y1, -len * 0.5, x1, y1, len * 0.5, x0, y0, len * 0.5,
                    palette.shade(o.colors.glass, 0.9 + s * 0.02))
            end
            for s = 0, segs do
                local t = s / segs * pi
                geometry.beam(b, cos(t) * r, sin(t) * r, -len * 0.5, cos(t) * r, sin(t) * r, len * 0.5, 0.08, trim)
            end
            for k = 0, 4 do
                local zz = -len * 0.5 + len * k / 4
                for s = 1, segs do
                    local t0, t1 = (s - 1) / segs * pi, s / segs * pi
                    geometry.beam(b, cos(t0) * r, sin(t0) * r, zz, cos(t1) * r, sin(t1) * r, zz, 0.1, trim)
                end
            end
            -- crop beds inside
            for k = -1, 1 do
                b:push():translate(k * r * 0.45, 0.15, 0)
                geometry.box(b, r * 0.32, 0.3, len * 0.92, rng:pick({ C.moss, C.grass, C.darkGreen }))
                b:pop()
            end
            b:pop()
        end
        -- water tower
        b:push():translate(w * 0.5 + 3, 0, 0)
        geometry.truss(b, 2.6, 7, 3, 0.1, trim)
        b:push():translate(0, 7, 0)
        geometry.lathe(b, { { 0, 0 }, { 2.4, 1.2 }, { 2.4, 4.2 }, { 1.6, 5.0 }, { 0, 5.2 } }, 10, palette.shade(o.colors.wall, 0.95))
        b:pop()
        b:pop()

        local entrance = { x = 0, y = 0, z = d * 0.6 + 2, dx = 0, dz = 1, width = 3 }
        return { radius = math.sqrt(w * w + d * d) * 0.6 + 4, height = 12, entrance = entrance }
    end,
})

--- Monument: every settlement deserves one landmark you can navigate by.
register("monument", "Monument", {
    weight = 5, minTier = 2, footprint = { 6, 12 }, unique = true, enterable = false,
    build = function(b, g, rng, o)
        local r = rng:range(o.footprint[1], o.footprint[2]) * 0.5
        local trim = o.colors.trim
        local h = rng:range(12, 26)
        geometry.cylinder(b, r * 1.6, 0.7, 8, palette.shade(o.colors.wall, 0.7), trim, 1, true)
        b:push():translate(0, 0.7, 0)
        local style = rng:int(1, 3)
        if style == 1 then
            -- twisted obelisk
            local steps = 10
            for i = 0, steps - 1 do
                local y0, y1 = h * i / steps, h * (i + 1) / steps
                local s0 = r * (1 - i / steps * 0.7)
                local s1 = r * (1 - (i + 1) / steps * 0.7)
                b:push():translate(0, y0, 0)
                b:rotateY(i * 0.16)
                geometry.frustumBox(b, s0 * 2, s0 * 2, s1 * 2, s1 * 2, y1 - y0, o.colors.accent, trim)
                b:pop()
            end
        elseif style == 2 then
            -- ring on a pylon
            geometry.cylinder(b, r * 0.3, h * 0.7, 8, trim, trim, 0.8, true)
            b:push():translate(0, h * 0.7 + r, 0)
            b:rotateX(pi * 0.5)
            geometry.torus(b, r * 1.5, r * 0.22, 18, 6, o.colors.accent)
            b:pop()
        else
            -- three leaning slabs
            for i = 1, 3 do
                local a = i / 3 * TAU
                b:push():translate(cos(a) * r * 0.5, 0, sin(a) * r * 0.5)
                b:rotateY(-a)
                b:rotateX(0.12)
                geometry.frustumBox(b, r * 0.7, r * 0.35, r * 0.3, r * 0.2, h, o.colors.accent, trim)
                b:pop()
            end
        end
        b:pop()
        g:push():translate(0, h * 0.5, 0)
        geometry.sphere(g, r * 0.22, 8, 5, C.cyan)
        g:pop()
        return { radius = r * 2, height = h }
    end,
})

--- Small utility shed -- fills gaps and adds density cheaply.
register("shed", "Utility Shed", {
    weight = 26, minTier = 1, footprint = { 5, 10 }, enterable = false,
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local d = w * rng:range(0.6, 1.0)
        local h = rng:range(2.6, 4.4)
        local col = o.colors.wall
        local trim = o.colors.trim
        geometry.boxStanding(b, w * 1.1, 0.28, d * 1.1, palette.shade(col, 0.6), trim)
        b:push():translate(0, 0.28, 0)
        geometry.boxStanding(b, w, h, d, col, trim)
        b:pop()
        -- pitched roof
        b:push():translate(0, h, 0)
        b:tri(-w * 0.5, 0, -d * 0.5, w * 0.5, 0, -d * 0.5, 0, w * 0.22, -d * 0.5, trim)
        b:tri(-w * 0.5, 0, d * 0.5, 0, w * 0.22, d * 0.5, w * 0.5, 0, d * 0.5, trim)
        b:quad(-w * 0.52, 0, -d * 0.52, 0, w * 0.22, -d * 0.52, 0, w * 0.22, d * 0.52, -w * 0.52, 0, d * 0.52, palette.shade(col, 0.9))
        b:quad(0, w * 0.22, -d * 0.52, w * 0.52, 0, -d * 0.52, w * 0.52, 0, d * 0.52, 0, w * 0.22, d * 0.52, palette.shade(col, 0.82))
        b:pop()
        if rng:bool(0.5) then
            b:push():translate(w * 0.3, h + w * 0.1, 0)
            geometry.cylinder(b, 0.22, 2.2, 6, trim, trim, 0.9, true)
            b:pop()
        end
        -- door and a service panel, so even the smallest shed has a face
        b:push():translate(-w * 0.22, 0.28 + h * 0.35, d * 0.5 + 0.06)
        geometry.box(b, w * 0.26, h * 0.7, 0.14, palette.shade(col, 0.55))
        b:pop()
        b:push():translate(w * 0.28, 0.28 + h * 0.5, d * 0.5 + 0.08)
        geometry.box(b, w * 0.2, h * 0.25, 0.16, trim)
        b:pop()
        -- external conduit
        geometry.beam(b, -w * 0.5 - 0.12, 0, d * 0.3, -w * 0.5 - 0.12, h, d * 0.3, 0.16, trim)
        g:push():translate(w * 0.28, 0.28 + h * 0.5, d * 0.5 + 0.17)
        panel(g, w * 0.14, h * 0.16, o.colors.window)
        g:pop()
        return { radius = math.sqrt(w * w + d * d) * 0.5 + 1, height = h + w * 0.22 }
    end,
})

--- Fuel depot: spherical tanks on cradles.
register("depot", "Fuel Depot", {
    weight = 12, minTier = 1, footprint = { 12, 22 }, enterable = false,
    build = function(b, g, rng, o)
        local w = rng:range(o.footprint[1], o.footprint[2])
        local trim = o.colors.trim
        local accent = o.colors.accent
        geometry.slab(b, w, w * 0.8, 0.12, palette.shade(o.colors.wall, 0.55))
        local n = rng:int(2, 4)
        for i = 1, n do
            local x = (i - (n + 1) * 0.5) * (w / n)
            local r = rng:range(2.2, 3.6)
            b:push():translate(x, 0.12, 0)
            for k = 0, 5 do
                local a = k / 6 * TAU
                geometry.beam(b, cos(a) * r * 0.8, 0, sin(a) * r * 0.8, cos(a) * r * 0.4, r * 0.9, sin(a) * r * 0.4, 0.2, trim)
            end
            b:translate(0, r * 1.5, 0)
            geometry.sphere(b, r, 12, 8, palette.shade(C.hullBright, 0.95))
            b:pop()
            if i > 1 then
                local px = (i - 1 - (n + 1) * 0.5) * (w / n)
                pipeRun(b, px, 1.0, 0, x, 1.0, 0, 0.16, accent)
            end
        end
        b:push():translate(0, 0.12, -w * 0.42)
        geometry.boxStanding(b, 4, 2.6, 3, o.colors.wall, trim)
        b:pop()
        g:push():translate(0, 1.4, -w * 0.42 + 1.55)
        panel(g, 2.6, 0.9, C.hazard)
        g:pop()
        return { radius = w * 0.62, height = 10 }
    end,
})

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Palette for one settlement, so all its buildings look like one place.
function buildings.colorScheme(rng, opts)
    opts = opts or {}
    local walls = { C.hullLight, C.hull, C.sand, C.rockDry, C.hullBright, C.steel, C.titanium }
    local trims = { C.hullDark, C.steel, C.rust, C.hull, C.black, C.copper }
    local accents = { C.orange, C.amber, C.red, C.teal, C.cyan, C.green, C.blue, C.magenta }
    local wall = opts.wall or rng:pick(walls)
    return {
        wall = wall,
        trim = opts.trim or rng:pick(trims),
        accent = opts.accent or rng:pick(accents),
        window = opts.window or (rng:bool(0.6) and C.window or C.windowCold),
        glass = C.glass,
        sign = opts.sign or rng:pick({ C.cyan, C.amber, C.magenta, C.uiPrimary }),
        factionColor = opts.factionColor,
    }
end

--- Builds one building of `kindId` into the builders.
-- `opts` may carry: glow (second builder), tier, tech, colors, footprint.
function buildings.build(b, kindId, rng, opts)
    local kind = kinds[kindId]
    if not kind then error("unknown building kind: " .. tostring(kindId), 2) end
    opts = opts or {}
    local o = {
        tier = opts.tier or 2,
        tech = opts.tech or 6,
        colors = opts.colors or buildings.colorScheme(rng, opts),
        footprint = opts.footprint or kind.footprint,
    }
    local glow = opts.glow or b
    local info, extra = kind.build(b, glow, rng, o)
    info = info or {}
    info.kind = kindId
    info.name = kind.name
    info.enterable = kind.enterable or false
    info.interior = kind.interior
    info.entrance = info.entrance or extra
    info.radius = info.radius or 8
    info.height = info.height or 6
    return info
end

--- Picks a kind appropriate for a settlement of this tier and economy.
function buildings.pick(rng, tier, economyId, used)
    local pool = {}
    for _, k in ipairs(kinds) do
        if (k.minTier or 1) <= tier and not (k.unique and used and used[k.id]) then
            local wgt = k.weight
            -- economies bias what gets built
            if economyId == "extraction" and (k.id == "mine" or k.id == "warehouse") then wgt = wgt * 3 end
            if economyId == "refinery" and (k.id == "refinery" or k.id == "depot") then wgt = wgt * 3.2 end
            if economyId == "industrial" and (k.id == "factory" or k.id == "warehouse") then wgt = wgt * 2.8 end
            if economyId == "agricultural" and (k.id == "farm" or k.id == "warehouse") then wgt = wgt * 3.4 end
            if economyId == "hightech" and (k.id == "lab" or k.id == "power") then wgt = wgt * 3.0 end
            if economyId == "military" and (k.id == "garrison" or k.id == "hangar") then wgt = wgt * 3.2 end
            if economyId == "service" and (k.id == "hab" or k.id == "market") then wgt = wgt * 2.6 end
            if economyId == "tourism" and (k.id == "dome" or k.id == "market" or k.id == "monument") then wgt = wgt * 2.6 end
            if economyId == "colony" and (k.id == "dome" or k.id == "shed" or k.id == "depot") then wgt = wgt * 2.4 end
            pool[#pool + 1] = { k = k, weight = wgt }
        end
    end
    if #pool == 0 then return kinds.shed end
    local total = 0
    for _, e in ipairs(pool) do total = total + e.weight end
    local r = rng:float() * total
    for _, e in ipairs(pool) do
        r = r - e.weight
        if r <= 0 then return e.k end
    end
    return pool[#pool].k
end

return buildings

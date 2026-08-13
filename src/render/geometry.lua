-- Parametric primitives emitted into a MeshBuilder.
--
-- Conventions: +Y is up, primitives are centred on the origin in X/Z, and
-- "standing" primitives (towers, cylinders, cones) have their base at y = 0 so
-- generators can place them on a footprint without thinking about offsets.

local geometry = {}

local cos, sin, pi, sqrt, min, max = math.cos, math.sin, math.pi, math.sqrt, math.min, math.max
local TAU = pi * 2

--- Colour resolution: primitives accept either a colour table or a function
--- `(faceIndex, u, v) -> colour`, which is how panel variation is produced.
local function resolve(col, i, u, v)
    if type(col) == "function" then return col(i, u, v) end
    return col
end

-- ---------------------------------------------------------------------------
-- Boxes
-- ---------------------------------------------------------------------------

--- Axis aligned box centred on the origin.
function geometry.box(b, sx, sy, sz, col, topCol)
    local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    local c = function(i) return resolve(col, i) end
    -- +Z, -Z, +X, -X, +Y, -Y
    b:quad(-hx, -hy, hz, hx, -hy, hz, hx, hy, hz, -hx, hy, hz, c(1))
    b:quad(hx, -hy, -hz, -hx, -hy, -hz, -hx, hy, -hz, hx, hy, -hz, c(2))
    b:quad(hx, -hy, hz, hx, -hy, -hz, hx, hy, -hz, hx, hy, hz, c(3))
    b:quad(-hx, -hy, -hz, -hx, -hy, hz, -hx, hy, hz, -hx, hy, -hz, c(4))
    b:quad(-hx, hy, hz, hx, hy, hz, hx, hy, -hz, -hx, hy, -hz, topCol and resolve(topCol, 5) or c(5))
    b:quad(-hx, -hy, -hz, hx, -hy, -hz, hx, -hy, hz, -hx, -hy, hz, c(6))
    return b
end

--- Box standing on the ground plane (base at y = 0).
function geometry.boxStanding(b, sx, sy, sz, col, topCol)
    b:push():translate(0, sy * 0.5, 0)
    geometry.box(b, sx, sy, sz, col, topCol)
    b:pop()
    return b
end

--- A tapered box (truncated pyramid): the classic low-poly tower block.
function geometry.frustumBox(b, bw, bd, tw, td, h, col, topCol, shear)
    local bx, bz = bw * 0.5, bd * 0.5
    local tx, tz = tw * 0.5, td * 0.5
    local ox, oz = 0, 0
    if shear then ox, oz = shear[1] or 0, shear[2] or 0 end
    local p = {
        { -bx, 0, bz }, { bx, 0, bz }, { bx, 0, -bz }, { -bx, 0, -bz },
        { -tx + ox, h, tz + oz }, { tx + ox, h, tz + oz }, { tx + ox, h, -tz + oz }, { -tx + ox, h, -tz + oz },
    }
    local sides = { { 1, 2, 6, 5 }, { 2, 3, 7, 6 }, { 3, 4, 8, 7 }, { 4, 1, 5, 8 } }
    for i = 1, 4 do
        local q = sides[i]
        local a, bb, c, d = p[q[1]], p[q[2]], p[q[3]], p[q[4]]
        b:quad(a[1], a[2], a[3], bb[1], bb[2], bb[3], c[1], c[2], c[3], d[1], d[2], d[3], resolve(col, i))
    end
    local t = topCol and resolve(topCol, 5) or resolve(col, 5)
    b:quad(p[5][1], p[5][2], p[5][3], p[6][1], p[6][2], p[6][3],
           p[7][1], p[7][2], p[7][3], p[8][1], p[8][2], p[8][3], t)
    b:quad(p[4][1], p[4][2], p[4][3], p[3][1], p[3][2], p[3][3],
           p[2][1], p[2][2], p[2][3], p[1][1], p[1][2], p[1][3], resolve(col, 6))
    return b
end

-- ---------------------------------------------------------------------------
-- Bodies of revolution
-- ---------------------------------------------------------------------------

--- N-sided prism / cylinder standing on the ground plane.
-- `taper` scales the top radius (0 gives a cone, 1 a cylinder).
function geometry.cylinder(b, radius, height, segments, col, capCol, taper, capped)
    segments = max(3, segments or 12)
    taper = taper or 1
    capped = capped ~= false
    local topR = radius * taper
    local cc = capCol or col
    for i = 0, segments - 1 do
        local a0 = i / segments * TAU
        local a1 = (i + 1) / segments * TAU
        local c0, s0 = cos(a0), sin(a0)
        local c1, s1 = cos(a1), sin(a1)
        local sideCol = resolve(col, i + 1, i / segments, 0)
        if topR > 1e-6 then
            b:quad(c0 * radius, 0, s0 * radius,
                   c1 * radius, 0, s1 * radius,
                   c1 * topR, height, s1 * topR,
                   c0 * topR, height, s0 * topR, sideCol)
        else
            b:tri(c0 * radius, 0, s0 * radius,
                  c1 * radius, 0, s1 * radius,
                  0, height, 0, sideCol)
        end
        if capped then
            b:tri(0, 0, 0, c1 * radius, 0, s1 * radius, c0 * radius, 0, s0 * radius, resolve(cc, i + 1))
            if topR > 1e-6 then
                b:tri(0, height, 0, c0 * topR, height, s0 * topR, c1 * topR, height, s1 * topR, resolve(cc, i + 1))
            end
        end
    end
    return b
end

function geometry.cone(b, radius, height, segments, col, capCol)
    return geometry.cylinder(b, radius, height, segments, col, capCol, 0, true)
end

--- Surface of revolution from a profile of {radius, y} pairs.
--- The workhorse behind domes, reactor vessels, silos and antenna masts.
function geometry.lathe(b, profile, segments, col, closeBottom, closeTop)
    segments = max(3, segments or 12)
    for i = 0, segments - 1 do
        local a0 = i / segments * TAU
        local a1 = (i + 1) / segments * TAU
        local c0, s0, c1, s1 = cos(a0), sin(a0), cos(a1), sin(a1)
        for j = 1, #profile - 1 do
            local r0, y0 = profile[j][1], profile[j][2]
            local r1, y1 = profile[j + 1][1], profile[j + 1][2]
            local fc = resolve(col, j, i / segments, j / #profile)
            if r0 < 1e-6 and r1 < 1e-6 then
                -- degenerate segment, nothing to emit
            elseif r0 < 1e-6 then
                b:tri(0, y0, 0, c0 * r1, y1, s0 * r1, c1 * r1, y1, s1 * r1, fc)
            elseif r1 < 1e-6 then
                b:tri(c0 * r0, y0, s0 * r0, c1 * r0, y0, s1 * r0, 0, y1, 0, fc)
            else
                b:quad(c0 * r0, y0, s0 * r0,
                       c1 * r0, y0, s1 * r0,
                       c1 * r1, y1, s1 * r1,
                       c0 * r1, y1, s0 * r1, fc)
            end
        end
        if closeBottom then
            local r, y = profile[1][1], profile[1][2]
            if r > 1e-6 then
                b:tri(0, y, 0, c1 * r, y, s1 * r, c0 * r, y, s0 * r, resolve(col, 0))
            end
        end
        if closeTop then
            local r, y = profile[#profile][1], profile[#profile][2]
            if r > 1e-6 then
                b:tri(0, y, 0, c0 * r, y, s0 * r, c1 * r, y, s1 * r, resolve(col, 0))
            end
        end
    end
    return b
end

--- UV sphere, flat shaded.  `colFn(u, v, y)` may vary the colour per facet,
--- which is how planets get climate bands without any texture.
function geometry.sphere(b, radius, segments, rings, col)
    segments = max(4, segments or 16)
    rings = max(2, rings or 10)
    for j = 0, rings - 1 do
        local t0 = j / rings
        local t1 = (j + 1) / rings
        local p0, p1 = t0 * pi, t1 * pi
        local y0, y1 = cos(p0) * radius, cos(p1) * radius
        local r0, r1 = sin(p0) * radius, sin(p1) * radius
        for i = 0, segments - 1 do
            local a0 = i / segments * TAU
            local a1 = (i + 1) / segments * TAU
            local c0, s0, c1, s1 = cos(a0), sin(a0), cos(a1), sin(a1)
            local fc = resolve(col, j * segments + i, (i + 0.5) / segments, 1 - (t0 + t1) * 0.5)
            if j == 0 then
                b:tri(0, y0, 0, c0 * r1, y1, s0 * r1, c1 * r1, y1, s1 * r1, fc)
            elseif j == rings - 1 then
                b:tri(c0 * r0, y0, s0 * r0, c1 * r0, y0, s1 * r0, 0, y1, 0, fc)
            else
                b:quad(c0 * r0, y0, s0 * r0,
                       c1 * r0, y0, s1 * r0,
                       c1 * r1, y1, s1 * r1,
                       c0 * r1, y1, s0 * r1, fc)
            end
        end
    end
    return b
end

--- Hemisphere sitting on the ground plane -- habitat domes, radomes, cupolas.
function geometry.dome(b, radius, height, segments, rings, col)
    segments = max(4, segments or 14)
    rings = max(1, rings or 5)
    height = height or radius
    local profile = {}
    for j = 0, rings do
        local a = (j / rings) * (pi * 0.5)
        profile[#profile + 1] = { cos(a) * radius, sin(a) * height }
    end
    return geometry.lathe(b, profile, segments, col, false, false)
end

-- ---------------------------------------------------------------------------
-- Footprints and slabs
-- ---------------------------------------------------------------------------

--- Extrudes a closed 2D polygon (array of {x, z}, counter clockwise) upwards.
function geometry.extrude(b, poly, y0, y1, col, topCol, bottom)
    local n = #poly
    if n < 3 then return b end
    for i = 1, n do
        local p = poly[i]
        local q = poly[i % n + 1]
        b:quad(p[1], y0, p[2], q[1], y0, q[2], q[1], y1, q[2], p[1], y1, p[2], resolve(col, i))
    end
    local top = {}
    for i = 1, n do top[i] = { poly[i][1], y1, poly[i][2] } end
    b:poly(top, topCol and resolve(topCol, 0) or resolve(col, 0))
    if bottom then
        local bot = {}
        for i = 1, n do bot[i] = { poly[n - i + 1][1], y0, poly[n - i + 1][2] } end
        b:poly(bot, resolve(col, 0))
    end
    return b
end

--- Regular n-gon footprint of a given radius, optionally rotated.
function geometry.ngon(n, radius, rot)
    rot = rot or 0
    local poly = {}
    for i = 0, n - 1 do
        local a = rot + i / n * TAU
        poly[i + 1] = { cos(a) * radius, sin(a) * radius }
    end
    return poly
end

--- Rectangular footprint.
function geometry.rect(w, d)
    local hw, hd = w * 0.5, d * 0.5
    return { { -hw, -hd }, { hw, -hd }, { hw, hd }, { -hw, hd } }
end

--- A flat quad on the ground plane (landing pads, plazas, road segments).
function geometry.slab(b, w, d, y, col)
    local hw, hd = w * 0.5, d * 0.5
    y = y or 0
    b:quad(-hw, y, hd, hw, y, hd, hw, y, -hd, -hw, y, -hd, resolve(col, 1))
    return b
end

-- ---------------------------------------------------------------------------
-- Structural detail
-- ---------------------------------------------------------------------------

--- A beam between two points with a square cross section.  Trusses, pipes,
--- gantries and antenna guys are all built from these.
function geometry.beam(b, x0, y0, z0, x1, y1, z1, thickness, col)
    local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return b end
    b:push()
    b:translate(x0, y0, z0)
    b:alignY(dx, dy, dz)
    b:translate(0, len * 0.5, 0)
    geometry.box(b, thickness, len, thickness, col)
    b:pop()
    return b
end

--- Open truss tower: four legs plus cross bracing.  Cheap, very "engineering
--- diagram", and instantly reads as infrastructure.
function geometry.truss(b, width, height, bays, thickness, col)
    local h = width * 0.5
    local legs = { { -h, -h }, { h, -h }, { h, h }, { -h, h } }
    for i = 1, 4 do
        local l = legs[i]
        geometry.beam(b, l[1], 0, l[2], l[1], height, l[2], thickness, col)
    end
    local step = height / max(1, bays)
    for j = 0, bays do
        local y = j * step
        for i = 1, 4 do
            local a, c = legs[i], legs[i % 4 + 1]
            geometry.beam(b, a[1], y, a[2], c[1], y, c[2], thickness * 0.7, col)
            if j < bays then
                geometry.beam(b, a[1], y, a[2], c[1], y + step, c[2], thickness * 0.55, col)
            end
        end
    end
    return b
end

--- A ring of struts joining an inner and an outer radius (station spokes).
function geometry.spokes(b, innerR, outerR, y, count, thickness, col)
    for i = 0, count - 1 do
        local a = i / count * TAU
        local c, s = cos(a), sin(a)
        geometry.beam(b, c * innerR, y, s * innerR, c * outerR, y, s * outerR, thickness, col)
    end
    return b
end

--- Torus, used for rotating habitat rings.
function geometry.torus(b, majorR, minorR, majorSeg, minorSeg, col)
    majorSeg = max(6, majorSeg or 24)
    minorSeg = max(3, minorSeg or 8)
    for i = 0, majorSeg - 1 do
        local a0, a1 = i / majorSeg * TAU, (i + 1) / majorSeg * TAU
        for j = 0, minorSeg - 1 do
            local b0, b1 = j / minorSeg * TAU, (j + 1) / minorSeg * TAU
            local function pt(a, bb)
                local r = majorR + minorR * cos(bb)
                return cos(a) * r, minorR * sin(bb), sin(a) * r
            end
            local x1, y1, z1 = pt(a0, b0)
            local x2, y2, z2 = pt(a1, b0)
            local x3, y3, z3 = pt(a1, b1)
            local x4, y4, z4 = pt(a0, b1)
            b:quad(x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4, resolve(col, i * minorSeg + j))
        end
    end
    return b
end

--- Irregular rock, built by displacing a sphere with a deterministic hash.
--- Used for asteroids and for surface boulders.
function geometry.rock(b, radius, segments, rings, rng, roughness, col)
    segments = max(5, segments or 10)
    rings = max(3, rings or 7)
    roughness = roughness or 0.35
    local disp = {}
    for j = 0, rings do
        disp[j] = {}
        for i = 0, segments do
            local ii = i % segments
            disp[j][i] = 1 + rng:range(-roughness, roughness)
            if i == segments then disp[j][i] = disp[j][ii] end
        end
    end
    for j = 0, rings - 1 do
        local p0, p1 = (j / rings) * pi, ((j + 1) / rings) * pi
        for i = 0, segments - 1 do
            local a0, a1 = i / segments * TAU, (i + 1) / segments * TAU
            local function pt(a, p, d)
                local r = radius * d
                return cos(a) * sin(p) * r, cos(p) * r, sin(a) * sin(p) * r
            end
            local x1, y1, z1 = pt(a0, p0, disp[j][i])
            local x2, y2, z2 = pt(a1, p0, disp[j][i + 1])
            local x3, y3, z3 = pt(a1, p1, disp[j + 1][i + 1])
            local x4, y4, z4 = pt(a0, p1, disp[j + 1][i])
            local fc = resolve(col, j * segments + i)
            if j == 0 then
                b:tri(0, y1 > 0 and y1 or radius, 0, x3, y3, z3, x4, y4, z4, fc)
            elseif j == rings - 1 then
                b:tri(x1, y1, z1, x2, y2, z2, 0, -radius, 0, fc)
            else
                b:quad(x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4, fc)
            end
        end
    end
    return b
end

return geometry

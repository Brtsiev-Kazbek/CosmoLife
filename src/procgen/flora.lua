-- Ground cover.
--
-- The surface used to carry two shapes: a conifer and a boulder, chosen by
-- whether the planet class was one of three "living" ones. Every world with
-- plants had the same plant, every world without had the same rock, and
-- twenty-six of them were scattered over a 900 m chunk -- one object per
-- thirty thousand square metres, which is an empty field with a decoration in
-- it rather than a landscape.
--
-- Each biome now names the kinds it grows and how densely (see procgen.biome),
-- and this module knows how to build one of each. They are all a handful of
-- primitives: the flat-shaded look does not want detail, it wants silhouette,
-- and a spire, a mushroom and a pine read as different things at fifty metres
-- because their outlines differ, not because of anything on their surface.
--
-- Everything here appends into a mesh builder that the caller has already
-- translated and rotated, so a chunk's whole ground cover is one draw call.

local palette = require("src.render.palette")
local geometry = require("src.render.geometry")

local flora = {}

local C = palette.colors
local pi = math.pi

-- Each builder: (b, rng, scale) -> nothing, drawing about `scale` metres tall
-- around the origin.
flora.KINDS = {}

--- A rounded boulder, the one thing every world has.
flora.KINDS.boulder = function(b, rng, scale)
    local r = rng:range(1.1, 4.2) * scale
    local col = rng:pick({ C.rockGrey, C.rockDry, C.slate, C.ash })
    geometry.rock(b, r, 7, 5, rng, 0.34, col)
end

--- A needle of rock standing on end: mesas, lava fields, badlands.
flora.KINDS.spire = function(b, rng, scale)
    local h = rng:range(6, 22) * scale
    local col = rng:pick({ C.rockGrey, C.rockRed, C.rockDry })
    geometry.cylinder(b, h * 0.16, h, 5, col, palette.shade(col, 0.7), rng:range(0.15, 0.4), true)
end

--- Conifer: a bare trunk and two stacked cones.
flora.KINDS.conifer = function(b, rng, scale)
    local h = rng:range(5, 15) * scale
    geometry.cylinder(b, h * 0.05, h * 0.42, 5, C.rockDry, nil, 0.7, true)
    b:push():translate(0, h * 0.34, 0)
    geometry.cone(b, h * 0.22, h * 0.44, 6, C.forest, C.darkGreen)
    b:pop()
    b:push():translate(0, h * 0.62, 0)
    geometry.cone(b, h * 0.15, h * 0.38, 6, C.forest, C.darkGreen)
    b:pop()
end

--- Broadleaf: a trunk under a squat sphere, wider than it is tall.
flora.KINDS.broadleaf = function(b, rng, scale)
    local h = rng:range(5, 13) * scale
    geometry.cylinder(b, h * 0.07, h * 0.5, 5, C.rockDry, nil, 0.8, true)
    b:push():translate(0, h * 0.62, 0)
    local col = rng:bool(0.25) and C.moss or C.forest
    geometry.sphere(b, h * 0.36, 7, 5, col)
    b:pop()
end

--- A dead trunk with a couple of broken limbs.
flora.KINDS.snag = function(b, rng, scale)
    local h = rng:range(4, 11) * scale
    geometry.cylinder(b, h * 0.07, h, 5, C.rockDry, palette.shade(C.rockDry, 0.7), 0.45, true)
    for _ = 1, rng:int(1, 3) do
        b:push():translate(0, h * rng:range(0.4, 0.85), 0)
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(0.6, 1.2))
        geometry.cylinder(b, h * 0.035, h * rng:range(0.2, 0.4), 4, C.rockDry, nil, 0.4, true)
        b:pop()
    end
end

--- A tuft of grass: three or four blades, cheap and used in quantity.
flora.KINDS.tuft = function(b, rng, scale)
    local h = rng:range(0.5, 1.6) * scale
    local col = rng:bool(0.3) and C.moss or C.grass
    for _ = 1, rng:int(3, 5) do
        b:push()
        b:translate(rng:range(-0.5, 0.5), 0, rng:range(-0.5, 0.5))
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(-0.35, 0.35))
        geometry.cylinder(b, h * 0.09, h, 3, col, palette.shade(col, 0.75), 0.1, false)
        b:pop()
    end
end

--- Reeds: taller, thinner, straighter -- wetlands and bogs.
flora.KINDS.reed = function(b, rng, scale)
    local h = rng:range(1.4, 3.2) * scale
    local col = rng:bool(0.4) and C.darkGreen or C.moss
    for _ = 1, rng:int(4, 8) do
        b:push()
        b:translate(rng:range(-0.8, 0.8), 0, rng:range(-0.8, 0.8))
        b:rotateZ(rng:range(-0.22, 0.22))
        geometry.cylinder(b, h * 0.045, h * rng:range(0.7, 1.2), 3, col, nil, 0.25, false)
        b:pop()
    end
end

--- A giant fungus: stalk and cap. The silhouette is the whole point.
flora.KINDS.fungus = function(b, rng, scale)
    local h = rng:range(3, 9) * scale
    local cap = rng:pick({ C.plum, C.magenta, C.coral, C.purple })
    geometry.cylinder(b, h * 0.09, h * 0.7, 6, C.hullLight, nil, 1.3, true)
    b:push():translate(0, h * 0.66, 0)
    geometry.cone(b, h * 0.42, h * 0.34, 8, cap, palette.shade(cap, 0.65))
    b:pop()
end

--- A shard of ice standing out of the ground.
flora.KINDS.iceSpire = function(b, rng, scale)
    local h = rng:range(3, 12) * scale
    b:rotateZ(rng:range(-0.2, 0.2))
    geometry.cone(b, h * 0.22, h, 5, C.rockIce, C.snow)
end

--- A crystal cluster: several prisms out of one point.
flora.KINDS.crystal = function(b, rng, scale)
    local n = rng:int(2, 5)
    local col = rng:pick({ C.indigo, C.teal, C.plasma, C.glassLit })
    for _ = 1, n do
        local h = rng:range(2, 8) * scale
        b:push()
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(-0.5, 0.5))
        geometry.cone(b, h * 0.16, h, 5, col, palette.shade(col, 1.3))
        b:pop()
    end
end

--- A columnar cactus: a trunk and one or two arms.
flora.KINDS.cactus = function(b, rng, scale)
    local h = rng:range(2.5, 6) * scale
    geometry.cylinder(b, h * 0.13, h, 6, C.darkGreen, palette.shade(C.darkGreen, 0.75), 0.85, true)
    for _ = 1, rng:int(0, 2) do
        b:push():translate(0, h * rng:range(0.35, 0.6), 0)
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(0.9, 1.3))
        geometry.cylinder(b, h * 0.09, h * 0.3, 5, C.darkGreen, nil, 0.9, true)
        b:pop()
    end
end

--- Builds one object of `kind`, or nothing if the kind is unknown.
function flora.build(kind, b, rng, scale)
    local fn = flora.KINDS[kind]
    if not fn then return false end
    fn(b, rng, scale or 1)
    return true
end

return flora

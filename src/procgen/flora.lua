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

-- Every colour goes through here.
--
-- A forest of identical greens is exactly as flat as a plain of identical
-- browns: the eye reads repetition as texture, not as trees. `hue` shifts the
-- balance between the channels a little, so one pine is yellower and its
-- neighbour bluer, and `tone` varies the brightness -- which together is the
-- difference between a stand of trees and a stamped pattern.
local function vary(rng, col, amount)
    amount = amount or 1
    local tone = 1 + rng:range(-0.16, 0.16) * amount
    local hue = rng:range(-0.07, 0.07) * amount
    return {
        math.min(col[1] * (tone + hue), 1),
        math.min(col[2] * tone, 1),
        math.min(col[3] * (tone - hue), 1),
        col[4] or 1,
    }
end

flora.vary = vary

-- Each builder: (b, rng, scale) -> footprint radius in metres.
--
-- Two conventions matter, and both were being broken.
--
-- Everything stands *on* the origin: y = 0 is the ground, not the middle of
-- the object. `geometry.cylinder` and `cone` already build that way, but
-- `geometry.rock` is a sphere centred on the origin, so every boulder was
-- planted exactly half underground -- a four metre rock showing two metres of
-- itself, which is what "half of them are in the ground" was.
--
-- And each returns the radius of its own base, because an upright object on a
-- slope has to be pushed into the hill by the drop across its own footprint or
-- one side of it hangs in the air.
flora.KINDS = {}

--- A rounded boulder, the one thing every world has.
flora.KINDS.boulder = function(b, rng, scale)
    local r = rng:range(1.1, 4.2) * scale
    local col = vary(rng, rng:pick({ C.rockGrey, C.rockDry, C.slate, C.ash }))
    -- lifted so it sits *in* the ground rather than halfway through it: a
    -- boulder should look bedded, showing most of itself
    b:push():translate(0, r * rng:range(0.45, 0.72), 0)
    -- a lighter facet here and there, as though the rock were bedded
    geometry.rock(b, r, 7, 5, rng, 0.34, function(i)
        return (i % 5 == 0) and palette.shade(col, 1.22) or col
    end)
    b:pop()
    return r
end

--- A needle of rock standing on end: mesas, lava fields, badlands.
flora.KINDS.spire = function(b, rng, scale)
    local h = rng:range(6, 22) * scale
    local col = vary(rng, rng:pick({ C.rockGrey, C.rockRed, C.rockDry }))
    geometry.cylinder(b, h * 0.16, h, 5, col, palette.shade(col, 0.7), rng:range(0.15, 0.4), true)
    return h * 0.16
end

--- Conifer: a bare trunk and two stacked cones.
flora.KINDS.conifer = function(b, rng, scale)
    local h = rng:range(5, 15) * scale
    local bark = vary(rng, C.rockDry, 0.8)
    -- a stand of conifers runs from near-black spruce to olive
    local needle = vary(rng, rng:bool(0.25) and C.darkGreen or C.forest, 1.4)
    geometry.cylinder(b, h * 0.05, h * 0.42, 5, bark, nil, 0.7, true)
    b:push():translate(0, h * 0.34, 0)
    geometry.cone(b, h * 0.22, h * 0.44, 6, needle, palette.shade(needle, 0.7))
    b:pop()
    b:push():translate(0, h * 0.62, 0)
    geometry.cone(b, h * 0.15, h * 0.38, 6, palette.shade(needle, 1.12), palette.shade(needle, 0.8))
    b:pop()
    return h * 0.22
end

--- Broadleaf: a trunk under a squat sphere, wider than it is tall.
flora.KINDS.broadleaf = function(b, rng, scale)
    local h = rng:range(5, 13) * scale
    geometry.cylinder(b, h * 0.07, h * 0.5, 5, vary(rng, C.rockDry, 0.8), nil, 0.8, true)
    b:push():translate(0, h * 0.62, 0)
    -- one in eight is turning: autumn colour in a green canopy
    local leaf = rng:bool(0.12) and rng:pick({ C.ochre, C.amber, C.coral })
        or (rng:bool(0.3) and C.moss or C.forest)
    leaf = vary(rng, leaf, 1.3)
    geometry.sphere(b, h * 0.36, 7, 5, leaf)
    b:pop()
    return h * 0.36
end

--- A dead trunk with a couple of broken limbs.
flora.KINDS.snag = function(b, rng, scale)
    local h = rng:range(4, 11) * scale
    local wood = vary(rng, rng:bool(0.4) and C.slate or C.rockDry, 1.1)
    geometry.cylinder(b, h * 0.07, h, 5, wood, palette.shade(wood, 0.7), 0.45, true)
    for _ = 1, rng:int(1, 3) do
        b:push():translate(0, h * rng:range(0.4, 0.85), 0)
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(0.6, 1.2))
        geometry.cylinder(b, h * 0.035, h * rng:range(0.2, 0.4), 4, C.rockDry, nil, 0.4, true)
        b:pop()
    end
    return h * 0.1
end

--- A tuft of grass: three or four blades, cheap and used in quantity.
flora.KINDS.tuft = function(b, rng, scale)
    local h = rng:range(0.5, 1.6) * scale
    local col = vary(rng, rng:bool(0.3) and C.moss or C.grass, 1.5)
    for _ = 1, rng:int(3, 5) do
        b:push()
        b:translate(rng:range(-0.5, 0.5), 0, rng:range(-0.5, 0.5))
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(-0.35, 0.35))
        geometry.cylinder(b, h * 0.09, h, 3, col, palette.shade(col, 0.75), 0.1, false)
        b:pop()
    end
    return 0.7
end

--- Reeds: taller, thinner, straighter -- wetlands and bogs.
flora.KINDS.reed = function(b, rng, scale)
    local h = rng:range(1.4, 3.2) * scale
    local col = vary(rng, rng:bool(0.4) and C.darkGreen or C.moss, 1.4)
    for _ = 1, rng:int(4, 8) do
        b:push()
        b:translate(rng:range(-0.8, 0.8), 0, rng:range(-0.8, 0.8))
        b:rotateZ(rng:range(-0.22, 0.22))
        geometry.cylinder(b, h * 0.045, h * rng:range(0.7, 1.2), 3, col, nil, 0.25, false)
        b:pop()
    end
    return 1.0
end

--- A giant fungus: stalk and cap. The silhouette is the whole point.
flora.KINDS.fungus = function(b, rng, scale)
    local h = rng:range(3, 9) * scale
    local cap = vary(rng, rng:pick({ C.plum, C.magenta, C.coral, C.purple }), 1.5)
    geometry.cylinder(b, h * 0.09, h * 0.7, 6, vary(rng, C.hullLight, 0.7), nil, 1.3, true)
    b:push():translate(0, h * 0.66, 0)
    geometry.cone(b, h * 0.42, h * 0.34, 8, cap, palette.shade(cap, 0.65))
    b:pop()
    return h * 0.42
end

--- A shard of ice standing out of the ground.
flora.KINDS.iceSpire = function(b, rng, scale)
    local h = rng:range(3, 12) * scale
    b:rotateZ(rng:range(-0.2, 0.2))
    local ice = vary(rng, C.rockIce, 0.6)
    geometry.cone(b, h * 0.22, h, 5, ice, palette.shade(ice, 1.15))
    return h * 0.22
end

--- A crystal cluster: several prisms out of one point.
flora.KINDS.crystal = function(b, rng, scale)
    local n = rng:int(2, 5)
    local col = rng:pick({ C.indigo, C.teal, C.plasma, C.glassLit })
    local foot = 0
    for _ = 1, n do
        -- each prism in the cluster is its own shade
        local shard = vary(rng, col, 1.6)
        local h = rng:range(2, 8) * scale
        b:push()
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(-0.5, 0.5))
        geometry.cone(b, h * 0.16, h, 5, shard, palette.shade(shard, 1.3))
        b:pop()
        foot = math.max(foot, h * 0.4)
    end
    return foot
end

--- A columnar cactus: a trunk and one or two arms.
flora.KINDS.cactus = function(b, rng, scale)
    local h = rng:range(2.5, 6) * scale
    local flesh = vary(rng, C.darkGreen, 1.2)
    geometry.cylinder(b, h * 0.13, h, 6, flesh, palette.shade(flesh, 0.75), 0.85, true)
    for _ = 1, rng:int(0, 2) do
        b:push():translate(0, h * rng:range(0.35, 0.6), 0)
        b:rotateY(rng:range(0, pi * 2))
        b:rotateZ(rng:range(0.9, 1.3))
        geometry.cylinder(b, h * 0.09, h * 0.3, 5, flesh, nil, 0.9, true)
        b:pop()
    end
    return h * 0.13
end

-- Nominal base radius per kind, in metres at scale 1.
--
-- Used to decide how far to sink an object into a slope *before* it is built:
-- the exact footprint is only known afterwards, and rebuilding to correct it
-- would consume the rng and produce a different object.
flora.FOOTPRINT = {
    boulder = 2.6, spire = 2.2, conifer = 2.2, broadleaf = 3.2, snag = 0.8,
    tuft = 0.7, reed = 1.0, fungus = 2.4, iceSpire = 1.6, crystal = 2.2,
    cactus = 0.7,
}

--- Builds one object of `kind`.
-- Returns the radius of its base, or nil if the kind is unknown.
function flora.build(kind, b, rng, scale)
    local fn = flora.KINDS[kind]
    if not fn then return nil end
    return fn(b, rng, scale or 1) or 1
end

return flora

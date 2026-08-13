-- Building interiors.
--
-- When the player walks through a door we do not load a level: we generate a
-- room from the building's seed, in the same flat-shaded style, with a handful
-- of interactive terminals standing in it.  Rooms are small on purpose --
-- they exist to make a settlement feel like a place with insides, and to host
-- the market / mission / shipyard screens in world space rather than in a menu
-- that appears from nowhere.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")
local palette = require("src.render.palette")

local interior = {}

local cos, sin, pi, floor, max = math.cos, math.sin, math.pi, math.floor, math.max
local TAU = pi * 2
local C = palette.colors

-- What each interior offers.  The state machine turns these into screens.
local KINDS = {
    lobby    = { name = "Residential Lobby", services = { "missions", "rumours" }, size = { 16, 12, 4.2 } },
    market   = { name = "Market Hall",       services = { "market", "blackMarket" }, size = { 22, 16, 6.0 } },
    workshop = { name = "Workshop Floor",    services = { "outfitting", "repair" }, size = { 20, 14, 6.5 } },
    storage  = { name = "Bonded Warehouse",  services = { "market", "missions" }, size = { 24, 16, 7.0 } },
    control  = { name = "Control Room",      services = { "missions", "navdata" }, size = { 14, 12, 4.0 } },
    hangar   = { name = "Hangar Floor",      services = { "shipyard", "repair", "refuel" }, size = { 28, 20, 9.0 } },
    garden   = { name = "Hydroponics",       services = { "market", "rumours" }, size = { 20, 14, 5.5 } },
    barracks = { name = "Garrison Post",     services = { "missions", "outfitting" }, size = { 16, 12, 4.0 } },
    lab      = { name = "Research Wing",     services = { "outfitting", "navdata", "missions" }, size = { 18, 14, 5.0 } },
    office   = { name = "Colony Office",     services = { "colony", "missions" }, size = { 14, 11, 4.0 } },
}

interior.kinds = KINDS

-- ---------------------------------------------------------------------------
-- Props
-- ---------------------------------------------------------------------------

local function terminal(b, g, colors, label)
    -- pedestal
    geometry.frustumBox(b, 1.5, 0.9, 1.2, 0.7, 1.05, colors.trim, palette.shade(colors.trim, 1.15))
    -- angled screen
    b:push():translate(0, 1.05, -0.1)
    b:rotateX(-0.42)
    geometry.box(b, 1.3, 0.9, 0.12, palette.shade(colors.trim, 0.7))
    b:pop()
    g:push():translate(0, 1.1, 0.06)
    g:rotateX(-0.42)
    g:translate(0, 0, 0.08)
    g:quad(-0.55, -0.35, 0, 0.55, -0.35, 0, 0.55, 0.35, 0, -0.55, 0.35, 0, label or C.uiPrimary)
    g:pop()
    -- keyboard shelf
    b:push():translate(0, 1.0, 0.42)
    geometry.box(b, 1.1, 0.08, 0.5, palette.shade(colors.trim, 0.85))
    b:pop()
end

local function crate(b, rng, colors)
    local s = rng:range(0.6, 1.3)
    geometry.boxStanding(b, s, s * rng:range(0.7, 1.2), s * rng:range(0.8, 1.3),
        rng:pick({ C.rust, C.steel, C.darkGreen, C.amber }), colors.trim)
end

local function bench(b, colors, w)
    geometry.boxStanding(b, w or 2.4, 0.08, 0.7, palette.shade(colors.trim, 1.1))
    for _, s in ipairs({ -1, 1 }) do
        geometry.beam(b, s * ((w or 2.4) * 0.4), 0, 0, s * ((w or 2.4) * 0.4), 0.75, 0, 0.09, colors.trim)
    end
    geometry.boxStanding(b, w or 2.4, 0.1, 0.75, palette.shade(colors.wall, 1.05))
end

local function pillar(b, g, h, colors)
    geometry.cylinder(b, 0.34, h, 8, colors.wall, colors.trim, 1, true)
    for k = 1, 2 do
        b:push():translate(0, h * k / 3, 0)
        geometry.cylinder(b, 0.42, 0.14, 8, colors.trim, nil, 1, false)
        b:pop()
    end
    g:push():translate(0, h * 0.62, 0.36)
    g:quad(-0.12, -0.5, 0, 0.12, -0.5, 0, 0.12, 0.5, 0, -0.12, 0.5, 0, C.cyan)
    g:pop()
end

-- ---------------------------------------------------------------------------
-- Room shell
-- ---------------------------------------------------------------------------

local function shell(b, g, w, d, h, colors, rng)
    local hw, hd = w * 0.5, d * 0.5

    -- floor with a plate pattern
    local tiles = 6
    for i = 0, tiles - 1 do
        for j = 0, tiles - 1 do
            local x = -hw + w * (i + 0.5) / tiles
            local z = -hd + d * (j + 0.5) / tiles
            local shade = ((i + j) % 2 == 0) and 0.9 or 1.02
            b:push():translate(x, 0, z)
            geometry.slab(b, w / tiles - 0.06, d / tiles - 0.06, 0, palette.shade(colors.floor, shade))
            b:pop()
        end
    end

    -- walls (inward facing quads; two sided lighting handles the winding)
    local walls = {
        { 0, hd, 0, w }, { 0, -hd, pi, w }, { hw, 0, -pi * 0.5, d }, { -hw, 0, pi * 0.5, d },
    }
    for i, wl in ipairs(walls) do
        b:push()
        b:translate(wl[1], 0, wl[2])
        b:rotateY(wl[3])
        geometry.slab(b, wl[4], 0.2, 0, colors.wall)
        b:push():translate(0, h * 0.5, 0)
        b:rotateX(pi * 0.5)
        geometry.slab(b, wl[4], h, 0, palette.shade(colors.wall, 0.92 + i * 0.02))
        b:pop()
        -- skirting and a rail
        b:push():translate(0, 0.16, 0.06)
        geometry.box(b, wl[4], 0.32, 0.12, colors.trim)
        b:pop()
        b:push():translate(0, h * 0.62, 0.06)
        geometry.box(b, wl[4], 0.1, 0.1, colors.trim)
        b:pop()
        b:pop()
    end

    -- ceiling with light strips
    b:push():translate(0, h, 0)
    geometry.slab(b, w, d, 0, palette.shade(colors.wall, 0.6))
    b:pop()
    local strips = max(2, floor(w / 4))
    for i = 0, strips - 1 do
        local x = -hw + w * (i + 0.5) / strips
        g:push():translate(x, h - 0.12, 0)
        geometry.slab(g, 0.7, d * 0.86, 0, C.lamp)
        g:pop()
        b:push():translate(x, h - 0.06, 0)
        geometry.box(b, 0.9, 0.12, d * 0.9, colors.trim)
        b:pop()
    end

    -- exit door on the -Z wall, marked so it is findable
    b:push():translate(0, 0, -hd + 0.12)
    geometry.box(b, 2.4, 2.6, 0.2, palette.shade(colors.trim, 0.7))
    b:pop()
    g:push():translate(0, 2.9, -hd + 0.2)
    g:rotateY(pi)
    g:quad(-1.1, -0.22, 0, 1.1, -0.22, 0, 1.1, 0.22, 0, -1.1, 0.22, 0, C.uiDanger)
    g:pop()
end

-- ---------------------------------------------------------------------------
-- Per-kind dressing
-- ---------------------------------------------------------------------------

local DRESS = {}

DRESS.market = function(b, g, w, d, h, colors, rng)
    local stalls = rng:int(4, 8)
    for i = 1, stalls do
        local a = (i - 1) / stalls * TAU
        local x = cos(a) * w * 0.3
        local z = sin(a) * d * 0.3
        b:push():translate(x, 0, z)
        b:rotateY(-a)
        geometry.boxStanding(b, 2.6, 1.1, 1.2, palette.shade(colors.wall, 0.95), colors.trim)
        b:push():translate(0, 1.1, -0.5)
        for k = 1, 3 do
            b:push():translate((k - 2) * 0.8, 0, 0)
            crate(b, rng, colors)
            b:pop()
        end
        b:pop()
        local awn = rng:pick({ C.red, C.teal, C.amber, C.green })
        b:push():translate(0, 2.6, 0.4)
        b:rotateX(0.3)
        geometry.box(b, 3.0, 0.08, 1.6, awn)
        b:pop()
        b:pop()
    end
    for i = 1, 2 do
        local x = (i == 1 and -1 or 1) * w * 0.34
        b:push():translate(x, 0, d * 0.36)
        pillar(b, g, h, colors)
        b:pop()
    end
end

DRESS.workshop = function(b, g, w, d, h, colors, rng)
    for i = 1, rng:int(3, 6) do
        b:push():translate(rng:range(-w * 0.36, w * 0.36), 0, rng:range(-d * 0.3, d * 0.34))
        b:rotateY(rng:range(0, TAU))
        bench(b, colors, rng:range(2, 3.4))
        b:pop()
    end
    -- overhead crane rail
    b:push():translate(0, h - 0.7, 0)
    geometry.box(b, w * 0.9, 0.25, 0.4, colors.trim)
    b:pop()
    b:push():translate(rng:range(-w * 0.3, w * 0.3), h - 1.6, 0)
    geometry.box(b, 1.4, 0.9, 1.2, C.hazard)
    geometry.beam(b, 0, 0, 0, 0, -h * 0.4, 0, 0.08, colors.trim)
    b:pop()
    for i = 1, rng:int(3, 7) do
        b:push():translate(rng:range(-w * 0.42, w * 0.42), 0, rng:range(-d * 0.42, d * 0.42))
        crate(b, rng, colors)
        b:pop()
    end
end

DRESS.storage = function(b, g, w, d, h, colors, rng)
    local rows = 3
    for r = 1, rows do
        local x = -w * 0.32 + (r - 1) * (w * 0.32)
        for level = 0, 2 do
            b:push():translate(x, level * (h / 3.2), 0)
            geometry.box(b, 2.6, 0.14, d * 0.7, colors.trim)
            b:pop()
            for k = 1, 4 do
                if rng:bool(0.7) then
                    b:push():translate(x + rng:range(-0.8, 0.8), level * (h / 3.2) + 0.07,
                        -d * 0.3 + (k - 1) * (d * 0.2))
                    crate(b, rng, colors)
                    b:pop()
                end
            end
        end
        geometry.beam(b, x - 1.3, 0, -d * 0.35, x - 1.3, h * 0.9, -d * 0.35, 0.14, colors.trim)
        geometry.beam(b, x + 1.3, 0, -d * 0.35, x + 1.3, h * 0.9, -d * 0.35, 0.14, colors.trim)
        geometry.beam(b, x - 1.3, 0, d * 0.35, x - 1.3, h * 0.9, d * 0.35, 0.14, colors.trim)
        geometry.beam(b, x + 1.3, 0, d * 0.35, x + 1.3, h * 0.9, d * 0.35, 0.14, colors.trim)
    end
end

DRESS.hangar = function(b, g, w, d, h, colors, rng)
    -- gantries along the walls
    for _, side in ipairs({ -1, 1 }) do
        b:push():translate(side * w * 0.4, 2.6, 0)
        geometry.box(b, 2.0, 0.2, d * 0.8, colors.trim)
        for k = -2, 2 do
            b:push():translate(0, -1.3, k * (d * 0.16))
            geometry.box(b, 0.2, 2.6, 0.2, colors.trim)
            b:pop()
        end
        b:pop()
    end
    -- fuel bowser and tool carts
    b:push():translate(-w * 0.2, 0, -d * 0.2)
    geometry.boxStanding(b, 2.2, 1.4, 1.4, C.hazard, colors.trim)
    b:push():translate(0, 1.4, 0)
    geometry.cylinder(b, 0.6, 1.2, 8, C.steel, C.hullDark, 1, true)
    b:pop()
    b:pop()
    for i = 1, 4 do
        b:push():translate(rng:range(-w * 0.4, w * 0.4), 0, rng:range(-d * 0.4, d * 0.4))
        crate(b, rng, colors)
        b:pop()
    end
    -- floor guidance markings
    g:push():translate(0, 0.03, 0)
    geometry.slab(g, 1.0, d * 0.8, 0, C.hazard)
    g:pop()
end

DRESS.garden = function(b, g, w, d, h, colors, rng)
    local rows = rng:int(3, 5)
    for r = 1, rows do
        local z = -d * 0.34 + (r - 1) * (d * 0.68 / max(rows - 1, 1))
        b:push():translate(0, 0, z)
        geometry.boxStanding(b, w * 0.72, 0.7, 1.1, colors.trim, palette.shade(colors.trim, 1.2))
        b:push():translate(0, 0.7, 0)
        geometry.box(b, w * 0.7, 0.2, 1.0, C.moss)
        b:pop()
        for k = 1, 7 do
            b:push():translate(-w * 0.32 + (k - 1) * (w * 0.64 / 6), 0.9, 0)
            geometry.cone(b, 0.24, rng:range(0.5, 1.1), 6, C.grass, C.forest)
            b:pop()
        end
        b:pop()
        g:push():translate(0, h - 0.35, z)
        geometry.slab(g, w * 0.7, 0.35, 0, C.magenta)
        g:pop()
    end
end

DRESS.control = function(b, g, w, d, h, colors, rng)
    -- console arc facing the window wall
    for i = -2, 2 do
        local a = i * 0.3
        b:push():translate(sin(a) * w * 0.3, 0, d * 0.28 - cos(a) * 2.0)
        b:rotateY(a + pi)
        terminal(b, g, colors, C.uiPrimary)
        b:pop()
    end
    -- window band
    g:push():translate(0, h * 0.6, d * 0.5 - 0.14)
    g:quad(-w * 0.44, -0.7, 0, w * 0.44, -0.7, 0, w * 0.44, 0.7, 0, -w * 0.44, 0.7, 0, C.glassLit)
    g:pop()
    b:push():translate(0, h * 0.6, d * 0.5 - 0.2)
    for k = -2, 2 do
        b:push():translate(k * w * 0.2, 0, 0)
        geometry.box(b, 0.12, 1.5, 0.12, colors.trim)
        b:pop()
    end
    b:pop()
end

DRESS.barracks = function(b, g, w, d, h, colors, rng)
    for i = 1, 6 do
        local side = (i % 2 == 0) and 1 or -1
        local z = -d * 0.3 + floor((i - 1) / 2) * (d * 0.3)
        b:push():translate(side * w * 0.33, 0, z)
        geometry.boxStanding(b, 1.0, 0.5, 2.0, colors.trim)
        b:push():translate(0, 0.5, 0)
        geometry.box(b, 1.0, 0.22, 2.0, C.darkGreen)
        b:pop()
        b:push():translate(0, 1.6, -0.9)
        geometry.box(b, 1.0, 2.0, 0.2, palette.shade(colors.wall, 0.8))
        b:pop()
        b:pop()
    end
    b:push():translate(0, 0, -d * 0.32)
    geometry.boxStanding(b, w * 0.4, 1.0, 1.0, colors.trim)
    b:pop()
end

DRESS.lab = function(b, g, w, d, h, colors, rng)
    for i = 1, rng:int(3, 5) do
        b:push():translate(rng:range(-w * 0.34, w * 0.34), 0, rng:range(-d * 0.3, d * 0.3))
        b:rotateY(rng:range(0, TAU))
        bench(b, colors, 2.6)
        b:push():translate(0, 0.85, 0)
        geometry.cylinder(b, 0.3, 0.9, 8, C.glass, C.glassLit, 1, true)
        b:pop()
        b:pop()
    end
    -- containment column
    b:push():translate(0, 0, d * 0.3)
    geometry.cylinder(b, 1.0, h * 0.9, 10, C.glass, colors.trim, 1, false)
    b:pop()
    g:push():translate(0, h * 0.45, d * 0.3)
    geometry.sphere(g, 0.7, 8, 6, C.plasma)
    g:pop()
end

DRESS.lobby = function(b, g, w, d, h, colors, rng)
    b:push():translate(0, 0, d * 0.3)
    geometry.frustumBox(b, 5.0, 1.4, 4.6, 1.2, 1.1, colors.trim, palette.shade(colors.trim, 1.2))
    b:pop()
    for i = 1, 3 do
        b:push():translate(-w * 0.28 + (i - 1) * (w * 0.28), 0, -d * 0.22)
        b:rotateY(rng:range(-0.4, 0.4))
        bench(b, colors, 2.2)
        b:pop()
    end
    for i = 1, 2 do
        b:push():translate((i == 1 and -1 or 1) * w * 0.32, 0, d * 0.05)
        geometry.cylinder(b, 0.7, 0.6, 8, colors.trim, C.moss, 1, true)
        b:push():translate(0, 0.6, 0)
        geometry.cone(b, 0.6, 1.6, 7, C.forest, C.darkGreen)
        b:pop()
        b:pop()
    end
end

DRESS.office = function(b, g, w, d, h, colors, rng)
    b:push():translate(0, 0, d * 0.28)
    geometry.boxStanding(b, 4.0, 1.0, 1.6, colors.trim, palette.shade(colors.trim, 1.15))
    b:pop()
    -- a planning table with a lit hologram of the colony
    b:push():translate(0, 0, -d * 0.1)
    geometry.cylinder(b, 1.8, 0.9, 10, colors.trim, palette.shade(colors.trim, 1.1), 1, true)
    b:pop()
    g:push():translate(0, 1.1, -d * 0.1)
    geometry.cylinder(g, 1.4, 0.06, 12, C.cyan, C.cyan, 1, true)
    for i = 1, 6 do
        local a = i / 6 * TAU
        g:push():translate(cos(a) * 0.8, 0.06, sin(a) * 0.8)
        geometry.boxStanding(g, 0.18, rng:range(0.2, 0.7), 0.18, C.uiPrimary)
        g:pop()
    end
    g:pop()
end

-- ---------------------------------------------------------------------------

--- Builds an interior room.
-- Returns { model, glowModel, size, terminals, spawn, exit, name, services }
function interior.generate(kindId, seed, opts)
    opts = opts or {}
    local kind = KINDS[kindId] or KINDS.lobby
    local rng = Rng.new(seed or 1, "interior", kindId)

    local w = kind.size[1] * rng:range(0.9, 1.15)
    local d = kind.size[2] * rng:range(0.9, 1.15)
    local h = kind.size[3] * rng:range(0.95, 1.15)

    local colors = {
        wall = opts.wall or palette.shade(rng:pick({ C.hull, C.hullLight, C.steel, C.sand }), 0.9),
        trim = opts.trim or rng:pick({ C.hullDark, C.steel, C.copper, C.rust }),
        floor = opts.floor or palette.shade(rng:pick({ C.hullDark, C.steel, C.ash }), 0.9),
    }

    local b = MeshBuilder.new()
    local g = MeshBuilder.new()

    shell(b, g, w, d, h, colors, rng)
    local dress = DRESS[kindId]
    if dress then dress(b, g, w, d, h, colors, rng) end

    -- service terminals along the +Z wall, one per service
    local terminals = {}
    local services = kind.services
    local n = #services
    for i, svc in ipairs(services) do
        local x = (n == 1) and 0 or (-w * 0.3 + (i - 1) * (w * 0.6 / (n - 1)))
        local z = -d * 0.34
        b:push():translate(x, 0, z)
        local tint = ({
            market = C.amber, blackMarket = C.magenta, missions = C.uiPrimary,
            shipyard = C.cyan, outfitting = C.teal, repair = C.orange,
            refuel = C.green, rumours = C.white, navdata = C.blue, colony = C.uiPrimary,
        })[svc] or C.uiPrimary
        terminal(b, g, colors, tint)
        b:pop()
        terminals[#terminals + 1] = { x = x, y = 0, z = z, service = svc, radius = 1.6 }
    end

    return {
        kind = kindId,
        name = kind.name,
        model = b:build(),
        glowModel = g:build(),
        width = w, depth = d, height = h,
        terminals = terminals,
        services = services,
        spawn = { x = 0, y = 0, z = -d * 0.5 + 2.2 },
        exit = { x = 0, y = 0, z = -d * 0.5 + 1.0, radius = 1.8 },
        colors = colors,
    }
end

--- Keeps the walking player inside the room and out of the props.
function interior.collide(room, x, z, radius)
    local hw = room.width * 0.5 - radius - 0.3
    local hd = room.depth * 0.5 - radius - 0.3
    x = util.clamp(x, -hw, hw)
    z = util.clamp(z, -hd, hd)
    for _, t in ipairs(room.terminals) do
        local dx, dz = x - t.x, z - t.z
        local d = math.sqrt(dx * dx + dz * dz)
        local r = 1.0 + radius
        if d < r and d > 1e-6 then
            x = t.x + dx / d * r
            z = t.z + dz / d * r
        end
    end
    return x, z
end

return interior

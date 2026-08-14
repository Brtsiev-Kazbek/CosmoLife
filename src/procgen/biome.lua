-- Biomes.
--
-- A planet used to be exactly one thing. `body.terrain` picked one of seven
-- recipes, that recipe picked one seven-stop colour ramp, and the colour of
-- any point on the world was a function of its height, its slope and its
-- latitude -- so a "terran" world was the same beach, the same grass and the
-- same forest from pole to pole, and landing twice on the same class of planet
-- showed you the same picture twice.
--
-- What makes a real world varied is that height is not the only axis. This
-- module adds the other two, the ones a Whittaker diagram is drawn on:
--
--   temperature   falls with latitude and with altitude, and is offset for
--                 the whole body by how much light its star actually delivers
--   humidity      a field of its own, pushed up near water and pulled down in
--                 the lee of mountain ranges
--
-- plus a third, rarer axis -- how *strange* the world is -- which is what
-- occasionally produces a glowing fungal basin instead of another pine forest.
--
-- Every biome then owns not just its colours but its ground cover, its
-- weather, and a relief modifier that changes the shape of the land: dunes
-- march across deserts, mesas terrace dry uplands, glaciers grind flat valleys
-- into the cold. Two neighbouring valleys on the same planet can now look
-- nothing alike, which is the whole point.
--
-- Costs are kept honest. The climate is two noise lookups; the height field
-- underneath a chunk is about seventeen per sample, so classifying every quad
-- adds single-digit percent, and the relief modifier is only evaluated for the
-- biomes that declare one.

local noise = require("src.lib.noise")
local util = require("src.lib.util")
local palette = require("src.render.palette")

local biome = {}

local abs, max, min, sqrt, floor = math.abs, math.max, math.min, math.sqrt, math.floor
local C = palette.colors

-- ---------------------------------------------------------------------------
-- The biome table
-- ---------------------------------------------------------------------------

-- Each entry:
--   temp, humid   its centre on the climate diagram, 0..1
--   strange       0 for ordinary biomes; >0 marks an exotic one, which is only
--                 reachable where the strangeness field is high
--   classes       planet classes it can occur on (nil = any with the right
--                 climate); this is what stops jungles appearing on ice worlds
--   low/mid/high  colours from the biome's lowest ground to its highest
--   rock          what steep ground shows instead
--   relief        optional shape modifier, see RELIEF below
--   scatter       ground cover: kinds and how densely
--   weather       what the sky does here
local function B(t) return t end

biome.LIST = {
    -- ---- water and shore -------------------------------------------------
    B{ id = "shore", name = "Shore", temp = 0.55, humid = 0.95,
       low = C.sand, mid = C.sand, high = C.rockDry, rock = C.rockGrey,
       shore = true,
       scatter = { { kind = "boulder", density = 0.25, scale = 0.6 } },
       weather = { fog = 0.3 } },

    -- ---- hot -------------------------------------------------------------
    B{ id = "dunes", name = "Dune Sea", temp = 0.92, humid = 0.05,
       classes = { desert = true, barren = true, terran = true },
       low = C.sand, mid = C.sand, high = C.rockDry, rock = C.rockDry,
       relief = "dunes",
       scatter = { { kind = "boulder", density = 0.12, scale = 0.7 } },
       weather = { dust = 0.9 } },

    B{ id = "hardpan", name = "Stone Desert", temp = 0.85, humid = 0.18,
       classes = { desert = true, barren = true, terran = true, toxic = true },
       low = C.rockDry, mid = C.rockRed, high = C.rockGrey, rock = C.rockGrey,
       relief = "mesa",
       scatter = { { kind = "boulder", density = 0.5 },
                   { kind = "spire", density = 0.12 } },
       weather = { dust = 0.5 } },

    B{ id = "savanna", name = "Savanna", temp = 0.78, humid = 0.42,
       classes = { terran = true, ocean = true, toxic = true },
       low = C.sand, mid = C.grass, high = C.rockDry, rock = C.rockDry,
       scatter = { { kind = "tuft", density = 1.4 },
                   { kind = "broadleaf", density = 0.18, scale = 1.2 },
                   { kind = "boulder", density = 0.2 } },
       weather = { dust = 0.25 } },

    B{ id = "jungle", name = "Rainforest", temp = 0.86, humid = 0.9,
       classes = { terran = true, ocean = true },
       low = C.darkGreen, mid = C.forest, high = C.moss, rock = C.rockDry,
       scatter = { { kind = "broadleaf", density = 2.6, scale = 1.35 },
                   { kind = "tuft", density = 1.6 },
                   { kind = "boulder", density = 0.15 } },
       weather = { rain = 0.85, fog = 0.4 } },

    B{ id = "wetland", name = "Wetland", temp = 0.62, humid = 0.98,
       classes = { terran = true, ocean = true, toxic = true },
       low = C.moss, mid = C.darkGreen, high = C.grass, rock = C.rockGrey,
       relief = "basin",
       scatter = { { kind = "reed", density = 2.2 },
                   { kind = "broadleaf", density = 0.5, scale = 0.9 } },
       weather = { fog = 0.8, rain = 0.5 } },

    -- ---- temperate -------------------------------------------------------
    B{ id = "prairie", name = "Prairie", temp = 0.6, humid = 0.42,
       classes = { terran = true, ocean = true, toxic = true },
       low = C.grass, mid = C.grass, high = C.moss, rock = C.rockDry,
       scatter = { { kind = "tuft", density = 2.0 },
                   { kind = "conifer", density = 0.1 } },
       weather = {} },

    B{ id = "woodland", name = "Woodland", temp = 0.58, humid = 0.68,
       classes = { terran = true, ocean = true },
       low = C.grass, mid = C.forest, high = C.moss, rock = C.rockGrey,
       scatter = { { kind = "broadleaf", density = 1.5 },
                   { kind = "conifer", density = 0.6 },
                   { kind = "tuft", density = 0.9 },
                   { kind = "boulder", density = 0.2 } },
       weather = { rain = 0.4, fog = 0.25 } },

    B{ id = "steppe", name = "Steppe", temp = 0.5, humid = 0.22,
       classes = { terran = true, desert = true, barren = true, toxic = true },
       low = C.rockDry, mid = C.moss, high = C.rockGrey, rock = C.rockGrey,
       scatter = { { kind = "tuft", density = 0.8 },
                   { kind = "boulder", density = 0.4 } },
       weather = { dust = 0.4 } },

    -- ---- cold ------------------------------------------------------------
    B{ id = "taiga", name = "Taiga", temp = 0.32, humid = 0.6,
       classes = { terran = true, ocean = true, ice = true },
       low = C.forest, mid = C.darkGreen, high = C.rockGrey, rock = C.rockGrey,
       scatter = { { kind = "conifer", density = 2.2, scale = 1.15 },
                   { kind = "snag", density = 0.3 },
                   { kind = "boulder", density = 0.3 } },
       weather = { snow = 0.4, fog = 0.3 } },

    B{ id = "tundra", name = "Tundra", temp = 0.22, humid = 0.35,
       classes = { terran = true, ice = true, barren = true, toxic = true },
       low = C.moss, mid = C.rockGrey, high = C.rockIce, rock = C.rockGrey,
       scatter = { { kind = "tuft", density = 0.7, scale = 0.7 },
                   { kind = "boulder", density = 0.5 } },
       weather = { snow = 0.5 } },

    B{ id = "glacier", name = "Glacier", temp = 0.06, humid = 0.5,
       classes = { terran = true, ice = true, ocean = true, barren = true },
       low = C.rockIce, mid = C.snow, high = C.snow, rock = C.rockIce,
       relief = "glacier",
       scatter = { { kind = "iceSpire", density = 0.5, scale = 1.2 } },
       weather = { snow = 0.9, fog = 0.4 } },

    B{ id = "iceField", name = "Ice Field", temp = 0.12, humid = 0.1,
       classes = { ice = true, barren = true, terran = true },
       low = C.rockIce, mid = C.rockIce, high = C.snow, rock = C.hullDark,
       scatter = { { kind = "iceSpire", density = 0.9 },
                   { kind = "boulder", density = 0.2 } },
       weather = { snow = 0.6, dust = 0.2 } },

    -- ---- altitude and rock -----------------------------------------------
    B{ id = "alpine", name = "Alpine", temp = 0.28, humid = 0.45,
       low = C.rockGrey, mid = C.rockGrey, high = C.snow, rock = C.rockGrey,
       relief = "crags",
       scatter = { { kind = "conifer", density = 0.4, scale = 0.8 },
                   { kind = "boulder", density = 0.9 } },
       weather = { snow = 0.5 } },

    B{ id = "badlands", name = "Badlands", temp = 0.68, humid = 0.12,
       classes = { desert = true, barren = true, volcanic = true, terran = true },
       low = C.rockRed, mid = C.rust, high = C.rockDry, rock = C.rockRed,
       relief = "mesa",
       scatter = { { kind = "spire", density = 0.5 },
                   { kind = "boulder", density = 0.6 } },
       weather = { dust = 0.7 } },

    B{ id = "regolith", name = "Regolith", temp = 0.45, humid = 0.02,
       classes = { barren = true, ice = true, desert = true, volcanic = true },
       low = C.rockGrey, mid = C.ash, high = C.hullDark, rock = C.hullDark,
       scatter = { { kind = "boulder", density = 0.7, scale = 0.9 } },
       weather = { dust = 0.3 } },

    -- ---- volcanic --------------------------------------------------------
    B{ id = "ashPlain", name = "Ash Plain", temp = 0.72, humid = 0.08,
       classes = { volcanic = true, barren = true },
       low = C.ash, mid = C.ash, high = C.rockGrey, rock = C.hullDark,
       scatter = { { kind = "boulder", density = 0.4, scale = 1.1 },
                   { kind = "spire", density = 0.2 } },
       weather = { dust = 0.85 } },

    B{ id = "lavaField", name = "Lava Field", temp = 0.97, humid = 0.02,
       classes = { volcanic = true },
       low = C.lava, mid = C.ash, high = C.rockGrey, rock = C.ash,
       relief = "fissures", emissiveLow = 0.7,
       scatter = { { kind = "spire", density = 0.35, scale = 1.2 } },
       weather = { dust = 0.6 } },

    -- ---- toxic -----------------------------------------------------------
    B{ id = "mire", name = "Toxic Mire", temp = 0.6, humid = 0.85,
       classes = { toxic = true },
       low = C.moss, mid = C.moss, high = C.darkGreen, rock = C.ash,
       relief = "basin",
       scatter = { { kind = "reed", density = 1.6 },
                   { kind = "fungus", density = 0.9, scale = 1.1 } },
       weather = { fog = 0.9, rain = 0.4 } },

    -- ---- exotic: only where the strangeness field is high -----------------
    B{ id = "fungal", name = "Fungal Forest", temp = 0.6, humid = 0.8, strange = 0.75,
       classes = { terran = true, toxic = true, ocean = true },
       low = C.plum, mid = C.purple, high = C.moss, rock = C.rockGrey,
       scatter = { { kind = "fungus", density = 2.4, scale = 1.6 },
                   { kind = "tuft", density = 0.8 } },
       weather = { fog = 0.6 }, glow = { kind = "fungus", strength = 0.5 } },

    B{ id = "crystal", name = "Crystal Waste", temp = 0.4, humid = 0.1, strange = 0.8,
       classes = { barren = true, ice = true, desert = true, volcanic = true },
       low = C.slate, mid = C.indigo, high = C.rockIce, rock = C.slate,
       relief = "crags",
       scatter = { { kind = "crystal", density = 1.3, scale = 1.3 },
                   { kind = "boulder", density = 0.3 } },
       weather = {}, glow = { kind = "crystal", strength = 0.7 } },

    B{ id = "glowMire", name = "Luminous Bog", temp = 0.7, humid = 0.95, strange = 0.85,
       classes = { toxic = true, terran = true, ocean = true },
       low = C.teal, mid = C.seafoam, high = C.darkGreen, rock = C.slate,
       relief = "basin",
       scatter = { { kind = "reed", density = 2.0 },
                   { kind = "fungus", density = 1.2, scale = 1.2 } },
       weather = { fog = 0.9 }, glow = { kind = "reed", strength = 0.8 } },
}

biome.byId = {}
for i, b in ipairs(biome.LIST) do
    b.index = i
    b.strange = b.strange or 0
    b.scatter = b.scatter or {}
    b.weather = b.weather or {}
    biome.byId[b.id] = b
end

-- ---------------------------------------------------------------------------
-- Relief modifiers
-- ---------------------------------------------------------------------------

-- Each takes the height in metres and the sample position, and returns a new
-- height. These are what make one valley look unlike the next: the colour
-- change alone reads as a paint job, not as a different place.
--
-- They are applied with a weight, so a biome boundary is a gradual change of
-- landform rather than a cliff.
local RELIEF = {
    -- wind-driven ridges, sharp on the lee side
    dunes = function(f, m, x, z, w)
        local a = f.duneAngle
        local u = (x * math.cos(a) + z * math.sin(a)) / f.duneWavelength
        local v = (-x * math.sin(a) + z * math.cos(a)) / (f.duneWavelength * 7)
        local wander = noise.perlin2(f.seed + 3301, v, u * 0.08) * 0.6
        local phase = (u + wander) % 1
        -- long windward slope, short steep slip face
        local h = phase < 0.72 and (phase / 0.72) or (1 - (phase - 0.72) / 0.28)
        return m + (h - 0.5) * f.duneHeight * w
    end,

    -- flat-topped steps: quantising height is the whole trick
    mesa = function(f, m, x, z, w)
        local step = f.mesaStep
        local q = floor(m / step) * step
        -- keep a little of the original so the terraces are not perfectly flat
        return m + (q - m) * 0.85 * w
    end,

    -- ice grinds valleys into troughs and rounds off the tops
    glacier = function(f, m, x, z, w)
        local sea = f:seaHeight()
        local base = (sea > -math.huge) and sea or 0
        local above = m - base
        if above <= 0 then return m end
        -- compress the relief and flatten the floor
        local u = above / (f.amplitude + 1)
        local smoothed = base + f.amplitude * (u ^ 1.6) * 0.85
        return m + (smoothed - m) * w
    end,

    -- exaggerate what is already steep
    crags = function(f, m, x, z, w)
        local n = noise.perlin2(f.seed + 5501, x / 900, z / 900)
        local ridged = (1 - abs(n)) ^ 3
        return m + ridged * f.amplitude * 0.22 * w
    end,

    -- shallow bowls that hold water and fog
    basin = function(f, m, x, z, w)
        local n = noise.perlin2(f.seed + 6601, x / 2600, z / 2600)
        return m - (n * 0.5 + 0.5) * f.amplitude * 0.16 * w
    end,

    -- cracked crust: narrow, deep, straight-ish splits
    fissures = function(f, m, x, z, w)
        local n = noise.perlin2(f.seed + 7701, x / 1400, z / 1400)
        local crack = 1 - util.clamp(abs(n) / 0.06, 0, 1)
        return m - crack * crack * f.amplitude * 0.30 * w
    end,
}

biome.RELIEF = RELIEF

-- ---------------------------------------------------------------------------
-- Climate
-- ---------------------------------------------------------------------------

-- The climate is sampled on a lattice and interpolated, not evaluated per
-- point.
--
-- Evaluating it directly would cost seven noise lookups on top of the
-- seventeen a height sample already costs -- a forty percent tax on the single
-- most expensive operation in the game, paid at every vertex of every chunk.
-- But climate varies over kilometres while terrain varies over metres, so the
-- field only has to be *known* at kilometre spacing: corners are computed once
-- and cached, and everything in between is bilinear. A 900 m chunk touches
-- about nine corners instead of six hundred samples, and because the result is
-- interpolated rather than quantised there are no visible cells.
local Climate = {}
Climate.__index = Climate

local CACHE_LIMIT = 20000

--- Sets up the climate for one body.
--
-- `field` is the terrain field; the body's own properties decide how hot the
-- whole world runs, so an inner rock is a desert everywhere and an outer one
-- is frozen everywhere, with the interesting worlds in between.
function biome.climate(field, body)
    local self = setmetatable({}, Climate)
    self.field = field
    self.seed = field.seed
    self.radius = field.radius
    self.cache = {}
    self.cacheCount = 0
    -- Lattice spacing, in radians of arc: about 4 km on the ground.
    --
    -- Biomes span tens of kilometres, so this is far finer than it needs to
    -- be for the field itself; what it has to beat is the *sampling* step. A
    -- chunk at the coarsest detail level is 20 km across with 24 quads to a
    -- side, so its samples are ~870 m apart -- at 1.2 km spacing almost every
    -- sample would land on a fresh corner and the cache would never amortise,
    -- which is exactly what the descent benchmark showed. At 4 km a coarse
    -- chunk reuses each corner about twenty times.
    self.step = 4000 / field.radius

    -- Base temperature for the whole body. `terrain` is a coarse label that
    -- already encodes most of this, so it is the strongest term; atmosphere
    -- evens out the poles.
    local BY_CLASS = {
        volcanic = 0.88, desert = 0.78, toxic = 0.62, terran = 0.55,
        ocean = 0.56, barren = 0.42, ice = 0.16,
    }
    self.baseTemp = BY_CLASS[field.kind] or 0.5
    self.atmosphere = util.clamp(body and body.atmosphere or 0, 0, 2)
    -- a thick atmosphere carries heat to the poles; a bare rock does not
    self.latitudeSwing = util.lerp(0.62, 0.28, util.clamp(self.atmosphere, 0, 1))
    -- metres of altitude per unit of temperature (a lapse rate)
    self.lapse = 4200 + field.amplitude * 1.6

    self.climateScale = field.radius / 260000
    self.humidScale = field.radius / 190000
    self.strangeScale = field.radius / 420000

    -- how much of the world is allowed to be strange at all
    self.strangeness = util.clamp(0.30 + (field.seed % 97) / 97 * 0.45, 0, 1)

    self.allowed = biome.allowedFor(field.kind)
    return self
end

--- The biomes that can occur on a planet class, always at least one.
function biome.allowedFor(kind)
    local out = {}
    for _, b in ipairs(biome.LIST) do
        if not b.classes or b.classes[kind] then out[#out + 1] = b end
    end
    if #out == 0 then out[#out + 1] = biome.byId.regolith end
    return out
end

--- Temperature, humidity and strangeness at one lattice corner.
--
-- This is the only place noise is evaluated; everything else interpolates.
function Climate:corner(i, j)
    local key = i * 1048573 + j
    local hit = self.cache[key]
    if hit then return hit[1], hit[2], hit[3] end

    local lat = j * self.step
    local lon = i * self.step
    local cl = math.cos(lat)
    local dx, dy, dz = cl * math.cos(lon), math.sin(lat), cl * math.sin(lon)

    local f = self.climateScale
    local temp = self.baseTemp + (1 - abs(dy)) * self.latitudeSwing - self.latitudeSwing * 0.5
    temp = temp + noise.fbm3(self.seed + 9101, dx * f, dy * f, dz * f, 3, 2.0, 0.5) * 0.16

    local hf = self.humidScale
    local humid = noise.fbm3(self.seed + 9203, dx * hf, dy * hf, dz * hf, 3, 2.1, 0.5) * 0.5 + 0.5
    -- cold air holds less water, and a world with no air holds none at all
    humid = humid * util.clamp(0.25 + self.atmosphere * 0.9, 0, 1)
    if self.field.seaLevel <= 0 then humid = humid * 0.35 end

    local sf = self.strangeScale
    local n = noise.perlin3(self.seed + 9307, dx * sf, dy * sf, dz * sf) * 0.5 + 0.5
    local strange = util.clamp((n - (1 - self.strangeness)) / max(self.strangeness, 0.01), 0, 1)

    temp, humid = util.clamp(temp, 0, 1), util.clamp(humid, 0, 1)
    if self.cacheCount >= CACHE_LIMIT then
        self.cache, self.cacheCount = {}, 0
    end
    self.cache[key] = { temp, humid, strange }
    self.cacheCount = self.cacheCount + 1
    return temp, humid, strange
end

--- Bilinear climate at a latitude and longitude, in radians.
function Climate:base(lat, lon)
    local gi, gj = lon / self.step, lat / self.step
    local i0, j0 = floor(gi), floor(gj)
    local fi, fj = gi - i0, gj - j0

    local t00, h00, s00 = self:corner(i0, j0)
    local t10, h10, s10 = self:corner(i0 + 1, j0)
    local t01, h01, s01 = self:corner(i0, j0 + 1)
    local t11, h11, s11 = self:corner(i0 + 1, j0 + 1)

    local a = 1 - fi
    local t0, h0, s0 = t00 * a + t10 * fi, h00 * a + h10 * fi, s00 * a + s10 * fi
    local t1, h1, s1 = t01 * a + t11 * fi, h01 * a + h11 * fi, s01 * a + s11 * fi
    local b = 1 - fj
    return t0 * b + t1 * fj, h0 * b + h1 * fj, s0 * b + s1 * fj
end

--- Nearest and runner-up biome for a point on the climate diagram.
--
-- The Whittaker construction: cheap, stable, and it degrades gracefully when a
-- planet class only allows a handful of biomes. No noise, only arithmetic over
-- the ten or so biomes the class permits, so this is safe to call per quad.
function Climate:pick(temp, humid, strange)
    local best, bestD, second, secondD = nil, math.huge, nil, math.huge
    local list = self.allowed
    for i = 1, #list do
        local b = list[i]
        -- an exotic biome is simply far away unless the world is strange here
        local sd = b.strange - strange
        if sd < 0 then sd = 0 end
        local dt, dh = temp - b.temp, humid - b.humid
        local d = dt * dt + dh * dh + sd * sd * 4
        if d < bestD then
            second, secondD = best, bestD
            best, bestD = b, d
        elseif d < secondD then
            second, secondD = b, d
        end
    end
    return best or biome.byId.regolith, bestD, second, secondD
end

--- The biome at a latitude/longitude and a height in metres.
function Climate:at(lat, lon, metres)
    local temp, humid, strange = self:base(lat, lon)
    -- altitude cools
    local sea = self.field:seaHeight()
    local above = metres - ((sea > -math.huge) and sea or 0)
    temp = util.clamp(temp - max(above, 0) / self.lapse, 0, 1)
    local best = self:pick(temp, humid, strange)
    return best, temp, humid, strange
end

--- Applies the biome's relief modifier to a height.
--
-- Called from the height field, which must stay a pure function of position,
-- so this deliberately uses only the *base* climate: bringing altitude in
-- would make the height depend on itself.
--
-- `u, v` are equirectangular metres, which is what the landform patterns are
-- drawn in -- the same construction the crater grid uses.
function Climate:relief(lat, lon, u, v, metres)
    local temp, humid, strange = self:base(lat, lon)
    local best, bestD, second, secondD = self:pick(temp, humid, strange)
    if not best or not best.relief then return metres end
    local fn = RELIEF[best.relief]
    if not fn then return metres end
    -- blend out towards the boundary with the runner-up, so landforms fade
    -- into each other instead of ending at a line
    local w = 1
    if second then
        w = util.clamp((sqrt(secondD) - sqrt(bestD)) / 0.10, 0, 1)
    end
    if w <= 0 then return metres end
    return fn(self.field, metres, u, v, w)
end

biome.Climate = Climate

return biome

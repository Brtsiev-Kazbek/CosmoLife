-- Planet surfaces.
--
-- The seamless part of "seamlessly land on a planet" is handled here.  From
-- orbit a body is a sphere mesh; below `config.scale.surfaceHandover` the
-- flight state starts streaming terrain chunks from this module, positioned in
-- a tangent frame under the ship.  Because the chunks are placed on the real
-- sphere (their vertices are pushed out to planetRadius + height) the two
-- representations agree at the horizon and the swap is invisible.
--
-- The height field itself is a pure function of (body seed, surface position),
-- so chunks can be built, thrown away and rebuilt without any state, and a
-- settlement placed at a latitude/longitude always sits on the same hill.

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local noise = require("src.lib.noise")
local config = require("src.config")
local MeshBuilder = require("src.render.mesh")
local palette = require("src.render.palette")
local biomeMod = require("src.procgen.biome")

local terrain = {}

local floor, sqrt, max, min, abs = math.floor, math.sqrt, math.max, math.min, math.abs

-- Terrain "recipes" per planet class: amplitude in metres and the mix of
-- noise layers that gives each class its silhouette.
local PROFILES = {
    terran   = { amp = 2200, ridge = 0.55, warp = 900, sea = 0.42, detail = 90,  crater = 0.0, rivers = 1.0 },
    ocean    = { amp = 1400, ridge = 0.35, warp = 700, sea = 0.68, detail = 60,  crater = 0.0, rivers = 0.8 },
    desert   = { amp = 1700, ridge = 0.45, warp = 1400, sea = 0.0, detail = 120, crater = 0.15 },
    ice      = { amp = 1900, ridge = 0.50, warp = 800, sea = 0.26, detail = 80,  crater = 0.2, rivers = 0.3 },
    volcanic = { amp = 2600, ridge = 0.72, warp = 600, sea = 0.08, detail = 140, crater = 0.35 },
    barren   = { amp = 1500, ridge = 0.40, warp = 500, sea = 0.0,  detail = 70,  crater = 0.75 },
    toxic    = { amp = 1800, ridge = 0.48, warp = 1100, sea = 0.30, detail = 100, crater = 0.1, rivers = 0.6 },
}

local Field = class("TerrainField")
terrain.Field = Field

--- Height field for one body.  Cheap to construct; cache it per body.
function Field:init(body)
    self.body = body
    self.seed = body.seed or 1
    local kind = body.terrain or "barren"
    local p = PROFILES[kind] or PROFILES.barren
    self.profile = p
    self.kind = kind
    self.radius = body.radius or 3e6

    local rng = Rng.new(self.seed, "terrain")
    -- feature scale: metres per unit of noise space
    self.continentScale = rng:range(320000, 900000)
    self.mountainScale = rng:range(38000, 90000)
    self.detailScale = rng:range(2600, 6200)
    -- Relief reaches roughly 2.7x this before the sea-level clamp, so a
    -- fraction of the profile amplitude gives a few kilometres of mountain --
    -- dramatic from orbit, still flyable at low level.
    self.amplitude = p.amp * rng:range(0.34, 0.62)
    self.seaLevel = p.sea
    self.craterAmount = p.crater
    self.craterScale = rng:range(4000, 12000)
    self.riverAmount = p.rivers or 0
    self.riverScale = rng:range(90000, 220000)
    self.riverWidth = rng:range(0.018, 0.045)
    self.riverDepth = self.amplitude * rng:range(0.20, 0.42)

    local ramp = palette.terrainSets[kind] or palette.terrainSets.barren
    self.ramp = {}
    for i, name in ipairs(ramp) do self.ramp[i] = palette.colors[name] end

    -- Landform parameters the biome relief modifiers work in. They belong to
    -- the body rather than to a biome, so two deserts on the same planet share
    -- a wind direction and a dune size, the way they would on a real one.
    self.duneAngle = rng:range(0, math.pi)
    self.duneWavelength = rng:range(180, 420)
    self.duneHeight = rng:range(14, 42)
    self.mesaStep = self.amplitude * rng:range(0.06, 0.14)

    -- The cast this whole world is painted in.
    --
    -- Scaling the channels was not enough, and could not have been: a grey has
    -- no hue to rotate, and the drab classes -- barren, ice, volcanic -- are
    -- built almost entirely out of greys, so multiplying them left them grey.
    -- Chroma has to be *added*.
    --
    -- Each body gets a saturated accent hue, normalised so its mean is one,
    -- and ground colour is mixed towards that hue at its own lightness. A grey
    -- slope becomes a teal or a violet or a rust one of exactly the same
    -- brightness; a colour that already has a hue is pulled part of the way
    -- towards the world's. Worlds are told apart at a glance, and no biome
    -- loses its position relative to the others on the same planet.
    local hue = rng:range(0, math.pi * 2)
    local function accentAt(a)
        -- three phases 120 degrees apart: the cheapest full-hue sweep there is
        local r = 0.5 + 0.5 * math.cos(a)
        local g = 0.5 + 0.5 * math.cos(a - 2.0944)
        local b = 0.5 + 0.5 * math.cos(a + 2.0944)
        local mean = (r + g + b) / 3
        return { r / mean, g / mean, b / mean }
    end
    self.accent = accentAt(hue)
    -- How far the world is pushed towards its accent. Airless rock and ice
    -- take the most, because they have the least colour of their own and are
    -- the worlds that were reading as grey; living worlds take the least,
    -- because green ground already means something.
    local BY_CLASS = {
        barren = 0.72, ice = 0.62, volcanic = 0.60, desert = 0.50,
        toxic = 0.46, ocean = 0.34, terran = 0.30,
    }
    self.accentStrength = (BY_CLASS[kind] or 0.5) * rng:range(0.8, 1.15)
    -- and a saturation lift on top, so what colour there is is not timid
    self.saturate = rng:range(1.25, 1.75)
    -- kept for anything still reading the old field name
    self.worldTint = self.accent

    self.climate = biomeMod.climate(self, body)

    -- cached chunks, keyed by "cx,cz,step"
    self.chunks = {}
    self.chunkOrder = {}
    self.chunkLimit = 220
    self.originLat, self.originLon = 0, 0
end

--- The patch origin: terrain queries are given in metres east/north of this
--- latitude and longitude.  Set on entering a surface, so the same ground is
--- produced no matter which patch the player is standing in.
function Field:setOrigin(lat, lon)
    self.originLat = lat or 0
    self.originLon = lon or 0
    self.chunks, self.chunkOrder = {}, {}
end

--- Terrain height in metres above the reference sphere, for a *direction* on
--- the unit sphere in body-fixed coordinates.
--
-- Everything -- the orbital sphere mesh, the ground under the ship and the
-- site a settlement was placed on -- goes through this one function, which is
-- why the view from orbit and the view from the cockpit agree.
function Field:heightDir(dx, dy, dz)
    local s = self.seed
    local R = self.radius
    local f = R / self.continentScale

    -- domain warp keeps continents from looking like plain fBm blobs
    local warp = self.profile.warp / self.continentScale
    local wx = noise.perlin3(s + 71, dx * f * 0.7, dy * f * 0.7, dz * f * 0.7) * warp
    local wy = noise.perlin3(s + 89, dx * f * 0.7 + 4.1, dy * f * 0.7, dz * f * 0.7) * warp
    local wz = noise.perlin3(s + 97, dx * f * 0.7, dy * f * 0.7 - 3.3, dz * f * 0.7) * warp

    local continent = noise.fbm3(s, dx * f + wx, dy * f + wy, dz * f + wz, 4, 2.0, 0.5)
    local h = continent * 0.5 + 0.5

    -- mountains: ridged noise masked by the continent field
    local mf = R / self.mountainScale
    local ridge = 1 - abs(noise.fbm3(s + 313, dx * mf, dy * mf, dz * mf, 4, 2.1, 0.5))
    ridge = ridge * ridge
    local mask = util.smoothstep(0.42, 0.78, h)
    h = h + ridge * mask * self.profile.ridge

    -- fine detail
    local df = R / self.detailScale
    h = h + noise.fbm3(s + 577, dx * df, dy * df, dz * df, 3, 2.2, 0.45) * 0.06

    local metres = (h - 0.5) * self.amplitude * 2

    -- Landforms from the biome: dunes, mesa terraces, glacial troughs, lava
    -- fissures. Worked out in equirectangular metres, the same construction
    -- the crater grid uses, so a dune field is the same dune field whether it
    -- is seen from orbit or walked across.
    local lat, lon, u, v
    if self.climate or self.craterAmount > 0.01 then
        lat = math.asin(util.clamp(dy, -1, 1))
        lon = (math.atan2 or math.atan)(dz, dx)
        u = lon * R * math.cos(lat)
        v = lat * R
    end
    if self.climate then
        metres = self.climate:relief(lat, lon, u, v, metres)
    end

    -- craters carved on airless worlds, laid out in an equirectangular grid
    if self.craterAmount > 0.01 then
        local cu = u / self.craterScale
        local cv = v / self.craterScale
        local w = noise.worley2(s + 811, cu, cv)
        if w < 0.42 then
            local t = w / 0.42
            local bowl = (t * t - 1) * self.craterScale * 0.09 * self.craterAmount
            local rim = math.exp(-((t - 0.95) ^ 2) * 40) * self.craterScale * 0.05 * self.craterAmount
            metres = metres + bowl + rim
        end
    end

    -- Rivers.
    --
    -- A cheap, convincing trick: take a second noise field, and where its
    -- value passes close to zero carve a narrow valley.  The zero set of a
    -- smooth field is a set of winding curves, which is exactly what a river
    -- network looks like from above -- and because the carve is scaled by
    -- height above the sea, rivers run in the lowlands and fade out on peaks.
    if self.riverAmount > 0.01 and self.seaLevel > 0 then
        local rf = R / self.riverScale
        local v = noise.fbm3(s + 2131, dx * rf, dy * rf, dz * rf, 3, 2.0, 0.5)
        local channel = 1 - util.clamp(abs(v) / self.riverWidth, 0, 1)
        if channel > 0 then
            local sea = self:seaHeight()
            -- only above the water line, and less as the land rises
            local above = metres - sea
            if above > 0 then
                local fade = util.clamp(1 - above / (self.amplitude * 1.1), 0, 1)
                local depth = channel * channel * self.riverDepth * fade
                metres = math.max(sea + 1, metres - depth)
            end
        end
    end

    -- sea level: a real flat plane, not a squashed slope, so oceans read as
    -- water rather than as low ground
    if self.seaLevel > 0 then
        local sea = self:seaHeight()
        if metres < sea then metres = sea end
    end
    return metres
end

--- Converts a tangent plane offset (metres east, metres north of the patch
--- origin) into a body-fixed unit direction.
function Field:directionAt(x, z)
    local lat0 = self.originLat or 0
    local lon0 = self.originLon or 0
    local R = self.radius
    local lat = lat0 + z / R
    local lon = lon0 + x / (R * math.max(math.cos(lat0), 0.02))
    local cl = math.cos(lat)
    return cl * math.cos(lon), math.sin(lat), cl * math.sin(lon)
end

--- Terrain height at a point in the local tangent plane.
function Field:height(x, z)
    local dx, dy, dz = self:directionAt(x, z)
    local metres = self:heightDir(dx, dy, dz)
    if self.seaLevel > 0 and metres <= self:seaHeight() + 0.5 then
        -- A mathematically flat sea gives every facet the same normal and the
        -- same colour, and reads as a sheet of glossy plastic. A swell of a
        -- few tens of centimetres breaks the normals up without making the
        -- water un-landable.
        local swell = noise.perlin2(self.seed + 4441, x / 260, z / 260) * 0.55
                    + noise.perlin2(self.seed + 4451, x / 61, z / 61) * 0.22
        return metres + swell
    end
    return metres + noise.perlin2(self.seed + 1009, x / 140, z / 140) * self.profile.detail * 0.12
end

--- True where the surface is standing water (sea or river).
function Field:isWater(h)
    if self.seaLevel <= 0 then return false end
    return h <= self:seaHeight() + self.amplitude * 0.025
end

function Field:seaHeight()
    if self.seaLevel <= 0 then return -math.huge end
    return (self.seaLevel - 0.5) * self.amplitude * 2
end

--- Surface normal by central differences.
function Field:normal(x, z, eps)
    eps = eps or 12
    local hl = self:height(x - eps, z)
    local hr = self:height(x + eps, z)
    local hd = self:height(x, z - eps)
    local hu = self:height(x, z + eps)
    local nx = hl - hr
    local nz = hd - hu
    local ny = 2 * eps
    local len = sqrt(nx * nx + ny * ny + nz * nz)
    return nx / len, ny / len, nz / len
end

--- Slope in radians, used to decide where a ship can safely land.
function Field:slope(x, z)
    local _, ny = self:normal(x, z)
    return math.acos(util.clamp(ny, -1, 1))
end

--- Water colour, shared by the ground and by the orbital sphere.
function Field:waterColor(h)
    local ramp = self.ramp
    local sea = self:seaHeight()
    local depth = util.clamp((sea - h) / (self.amplitude * 0.4), 0, 1)
    local col = palette.mix(ramp[2] or ramp[1], ramp[1], depth)
    -- a little variation across facets so a calm sea is not one flat tone
    local k = 0.94 + ((h - sea) * 0.9 % 0.12)
    return { col[1] * k, col[2] * k, col[3] * k * 1.03, col[4] or 1 }
end

-- A cheap deterministic value in 0..1 for a patch of ground, with no noise
-- stack behind it: three multiplies and a modulo. Used for per-facet
-- variation, where the *only* requirement is that neighbours differ and that
-- the answer is the same every time the chunk is rebuilt.
local function facetHash(seed, x, z)
    local ix = floor(x * 0.22) % 8192
    local iz = floor(z * 0.22) % 8192
    local n = (ix * 3719 + iz * 6421 + seed % 65536 * 131) % 65521
    n = (n * 1103515 + 12345) % 65521
    return n / 65521
end

--- The colour a biome gives to ground at height `h`.
--
-- Each biome carries three stops rather than sharing one seven-stop ramp for
-- the whole planet, which is what used to make every terran world the same
-- beach-grass-forest gradient from pole to pole.
--
-- The three stops alone are still not enough on the ground. They are spread
-- over the planet's whole relief -- kilometres -- while a chunk spans tens of
-- metres, so every facet in sight resolved to within a percent of the same
-- colour and the ground read as a single flat wash of paint. Two things break
-- that up, and neither costs a noise stack: a mid-frequency field that moves
-- the mix between the stops over tens of metres, so there are patches of
-- lighter and darker soil, and a per-facet hash worth a few percent of
-- brightness, which is what stops adjacent triangles from being identical.
--
-- `x, z` are optional: the orbital sphere passes none, because at that scale
-- the variation is smaller than a pixel and would only be noise.
function Field:biomeColor(b, h, x, z)
    local sea = self:seaHeight()
    local base = (sea > -math.huge) and sea or -self.amplitude
    local span = max(self.amplitude * 1.6, 1)
    local t = util.clamp((h - base) / span, 0, 1)

    if x then
        -- patches of tone over ~90 m, which is the scale a hillside varies on
        local patch = noise.perlin2(self.seed + 9901, x / 90, z / 90)
        t = util.clamp(t + patch * 0.22, 0, 1)
    end

    local col
    if t < 0.5 then
        col = palette.mix(b.low, b.mid, t * 2)
    else
        col = palette.mix(b.mid, b.high, (t - 0.5) * 2)
    end

    -- Push it towards the world's accent hue, at its own lightness, and lift
    -- the saturation. This is what turns a planet of five greys and a brown
    -- into a planet that has a colour.
    local a = self.accent
    local k = self.accentStrength
    local lum = col[1] * 0.30 + col[2] * 0.59 + col[3] * 0.11
    local r = col[1] + (lum * a[1] - col[1]) * k
    local g = col[2] + (lum * a[2] - col[2]) * k
    local bch = col[3] + (lum * a[3] - col[3]) * k
    local grey = r * 0.30 + g * 0.59 + bch * 0.11
    local sat = self.saturate
    col = {
        util.clamp(grey + (r - grey) * sat, 0, 1),
        util.clamp(grey + (g - grey) * sat, 0, 1),
        util.clamp(grey + (bch - grey) * sat, 0, 1),
        col[4] or 1,
    }

    if x then
        -- Facet to facet variation. Brightness alone still reads as one
        -- colour under a light, so the channels are pushed apart a little as
        -- well: that is what turns a slab of paint into ground.
        local n = facetHash(self.seed, x, z)
        local k = 0.88 + n * 0.24
        local hue = (n - 0.5) * 0.13
        col[1] = util.clamp(col[1] * (k + hue), 0, 1)
        col[2] = util.clamp(col[2] * k, 0, 1)
        col[3] = util.clamp(col[3] * (k - hue), 0, 1)
    end
    return col
end

--- Colour for a point on the sphere, used by the orbital mesh.
--
-- It takes a direction rather than a latitude so that it can ask the same
-- biome question the ground asks: the brown wedge of desert seen from orbit
-- has to be the desert that is landed in.
function Field:colorDir(dx, dy, dz, h)
    if self:isWater(h) then return self:waterColor(h) end
    local lat = math.asin(util.clamp(dy, -1, 1))
    local lon = (math.atan2 or math.atan)(dz, dx)
    local b = self.climate:at(lat, lon, h)
    return self:biomeColor(b, h)
end

--- Colour for a height with no direction available.  Kept for callers that
--- only have a height (the galaxy map's little world icons).
function Field:colorForHeight(h, latitude)
    local ramp = self.ramp
    local n = #ramp
    if self:isWater(h) then return self:waterColor(h) end
    local t = util.clamp((h + self.amplitude) / (self.amplitude * 2), 0, 0.999)
    local idx = 1 + t * (n - 1)
    local i0 = floor(idx)
    local col = palette.mix(ramp[max(i0, 1)], ramp[min(i0 + 1, n)], idx - i0)
    if latitude then
        local polar = util.smoothstep(1.05, 1.42, abs(latitude))
        if polar > 0 then col = palette.mix(col, palette.colors.snow, polar) end
    end
    return col
end

--- Colour for a point, from the class ramp plus slope and latitude effects.
--
-- `ny` is the vertical component of the surface normal. Pass it when the
-- caller already knows it: without it this falls back to `Field:normal`, which
-- is four more full noise-stack evaluations *per quad*. Chunk building does
-- know it -- it has the quad's four corner heights in hand -- and that one
-- argument is worth roughly a fivefold cut in the cost of building a chunk,
-- the most expensive operation in the game.
function Field:colorAt(x, z, h, ny)
    -- water first: sea and river channels
    if self:isWater(h) then return self:waterColor(h) end

    local b = self:biomeAt(x, z, h)
    local col = self:biomeColor(b, h, x, z)

    -- steep ground shows the biome's rock regardless of altitude
    if not ny then
        local _, computed = self:normal(x, z, 30)
        ny = computed
    end
    if ny < 0.82 then
        col = palette.mix(col, b.rock or palette.colors.rockGrey,
            util.clamp((0.82 - ny) / 0.35, 0, 1))
    end
    return col
end

--- The biome at a point in the local tangent plane.
function Field:biomeAt(x, z, h)
    local lat0 = self.originLat or 0
    local R = self.radius
    local lat = lat0 + z / R
    local lon = (self.originLon or 0) + x / (R * max(math.cos(lat0), 0.02))
    return (self.climate:at(lat, lon, h or self:height(x, z)))
end

-- ---------------------------------------------------------------------------
-- Chunk meshes
-- ---------------------------------------------------------------------------

--- Builds one square patch of ground.
-- `ox, oz`  patch origin in tangent-plane metres
-- `size`    patch edge length in metres
-- `res`     vertices per edge (higher = finer)
function Field:buildChunk(ox, oz, size, res)
    res = max(2, res or config.render.terrainChunk)
    local key = string.format("%d,%d,%d", floor(ox), floor(oz), res)
    local hit = self.chunks[key]
    if hit then return hit end

    local b = MeshBuilder.new()
    local step = size / res
    -- sample one extra row/column so neighbouring chunks share exact heights
    local hs = {}
    for j = 0, res do
        hs[j] = {}
        for i = 0, res do
            hs[j][i] = self:height(ox + i * step, oz + j * step)
        end
    end

    local minH, maxH = math.huge, -math.huge
    for j = 0, res - 1 do
        for i = 0, res - 1 do
            local x0, z0 = ox + i * step, oz + j * step
            local x1, z1 = x0 + step, z0 + step
            local h00, h10 = hs[j][i], hs[j][i + 1]
            local h01, h11 = hs[j + 1][i], hs[j + 1][i + 1]
            local hc = (h00 + h10 + h01 + h11) * 0.25
            local col = self:colorAt(x0 + step * 0.5, z0 + step * 0.5, hc)
            -- split the quad along the shorter diagonal: fewer sliver facets
            if abs(h00 - h11) <= abs(h10 - h01) then
                b:tri(x0 - ox, h00, z0 - oz, x1 - ox, h10, z0 - oz, x1 - ox, h11, z1 - oz, col)
                b:tri(x0 - ox, h00, z0 - oz, x1 - ox, h11, z1 - oz, x0 - ox, h01, z1 - oz, col)
            else
                b:tri(x0 - ox, h00, z0 - oz, x1 - ox, h10, z0 - oz, x0 - ox, h01, z1 - oz, col)
                b:tri(x1 - ox, h10, z0 - oz, x1 - ox, h11, z1 - oz, x0 - ox, h01, z1 - oz, col)
            end
            minH = min(minH, h00); maxH = max(maxH, h00)
        end
    end

    local chunk = {
        ox = ox, oz = oz, size = size, res = res,
        model = b:build(),
        minH = minH, maxH = maxH,
    }
    self.chunks[key] = chunk
    self.chunkOrder[#self.chunkOrder + 1] = key
    if #self.chunkOrder > self.chunkLimit then
        local old = table.remove(self.chunkOrder, 1)
        local c = self.chunks[old]
        if c and c.model and c.model.mesh and c.model.mesh.release then c.model.mesh:release() end
        self.chunks[old] = nil
    end
    return chunk
end

--- Scenery for one chunk: whatever the biomes under it grow.
--
-- Returned as one baked mesh, so a chunk's entire ground cover -- which may be
-- two hundred objects -- costs a single draw call.
--
-- What is placed comes from the biome at each point rather than from the
-- planet's class, so a valley of pines can end at a ridge and become bare
-- scree, and the density is modulated by a low frequency field so cover
-- clumps into groves and clearings instead of being sprinkled evenly. A
-- uniform sprinkle is the thing that most reliably reads as procedural.
--
-- This deliberately does *not* cache. It used to keep every mesh it had ever
-- built in `self.scatter`, while the caller (`Surface:update`) released those
-- same meshes when their chunk left the working set -- so walking away from a
-- chunk and back handed the renderer a destroyed Mesh. The scatter belongs to
-- the chunk, and it lives and dies with it.
-- `hs` is the caller's height grid: `hs[j][i]` at (i*step, j*step) from the
-- chunk origin, `res` samples to a side. Passing it in removes every noise
-- evaluation from this function -- placing two hundred objects used to cost
-- one height sample and a four-sample normal each, about as much as building
-- the chunk itself. It is also more correct: objects then sit on the surface
-- that is actually drawn rather than on the exact field, so nothing floats or
-- sinks at the seams.
function Field:buildScatter(ox, oz, size, density, hs, res)
    local flora = require("src.procgen.flora")
    local rng = Rng.new(self.seed, "scatter", floor(ox), floor(oz))
    local b = MeshBuilder.new()
    local step = res and (size / res) or nil

    -- height and upward normal from the grid, bilinear
    local function ground(x, z)
        if not hs then
            local h = self:height(ox + x, oz + z)
            local _, ny = self:normal(ox + x, oz + z, 20)
            return h, ny
        end
        local gx = util.clamp(x / step, 0, res - 1e-4)
        local gz = util.clamp(z / step, 0, res - 1e-4)
        local i0, j0 = floor(gx), floor(gz)
        local fx, fz = gx - i0, gz - j0
        local h00, h10 = hs[j0][i0], hs[j0][i0 + 1]
        local h01, h11 = hs[j0 + 1][i0], hs[j0 + 1][i0 + 1]
        local h = (h00 * (1 - fx) + h10 * fx) * (1 - fz)
                + (h01 * (1 - fx) + h11 * fx) * fz
        local dhx = ((h10 + h11) - (h00 + h01)) / (2 * step)
        local dhz = ((h01 + h11) - (h00 + h10)) / (2 * step)
        return h, 1 / sqrt(dhx * dhx + 1 + dhz * dhz)
    end

    -- Attempts, not objects: each one lands somewhere, asks the biome there
    -- what grows, and usually gets nothing. Scaling with area keeps the cover
    -- per hectare constant whatever the chunk size is.
    local attempts = floor((density or 1) * 220 * (size / 900) ^ 2)
    local sea = self:seaHeight()
    local groveScale = 260 + (self.seed % 7) * 90

    for _ = 1, attempts do
        local x = rng:range(0, size)
        local z = rng:range(0, size)
        local wx, wz = ox + x, oz + z
        local h, ny = ground(x, z)
        if h > sea + 4 then
            if ny > 0.72 then
                local biome = self:biomeAt(wx, wz, h)
                local list = biome.scatter
                if list and #list > 0 then
                    -- groves and clearings
                    local grove = noise.perlin2(self.seed + 8803, wx / groveScale, wz / groveScale)
                    local clump = util.clamp(grove * 0.5 + 0.62, 0, 1)
                    -- pick a kind in proportion to its density, then roll
                    -- against that density so a sparse biome stays sparse
                    local pick = list[rng:int(1, #list)]
                    if rng:float() < util.clamp(pick.density, 0, 1) * clump then
                        -- Push it into the hill by the drop across its own
                        -- base. Everything here stands upright while the
                        -- ground does not, so on a slope an object planted
                        -- exactly on the surface has one side of its base
                        -- hanging in the air; sinking it by half the drop
                        -- plants both sides. The footprint is the kind's
                        -- nominal one, because the exact size is not known
                        -- until the object has been built and rebuilding it
                        -- would consume the rng and produce a different one.
                        local foot = (flora.FOOTPRINT[pick.kind] or 1) * (pick.scale or 1)
                        local slope = sqrt(max(1 - ny * ny, 0)) / max(ny, 0.2)
                        local sink = min(foot * slope * 0.5, foot * 0.8)
                        b:push():translate(x, h - sink, z)
                        b:rotateY(rng:range(0, math.pi * 2))
                        flora.build(pick.kind, b, rng, pick.scale or 1)
                        b:pop()
                    end
                end
            end
        end
    end

    return b:build()
end

--- Drops all cached GPU meshes (called when leaving a body).
function Field:release()
    for _, c in pairs(self.chunks) do
        if c.model and c.model.mesh and c.model.mesh.release then c.model.mesh:release() end
    end
    self.chunks, self.chunkOrder = {}, {}
end

-- ---------------------------------------------------------------------------

local fieldCache = {}
local fieldOrder = {}

--- Returns (and caches) the height field for a body.
function terrain.field(body)
    local key = tostring(body.seed) .. ":" .. tostring(body.terrain)
    local f = fieldCache[key]
    if not f then
        f = Field.new(body)
        fieldCache[key] = f
        fieldOrder[#fieldOrder + 1] = key
        if #fieldOrder > 6 then
            local old = table.remove(fieldOrder, 1)
            if fieldCache[old] then fieldCache[old]:release() end
            fieldCache[old] = nil
        end
    end
    return f
end

function terrain.clearCache()
    for _, f in pairs(fieldCache) do f:release() end
    fieldCache, fieldOrder = {}, {}
end

--- The tangent frame at a surface point: east, north and up unit vectors in
--- world space.  Everything on the ground is positioned with these.
function terrain.tangentFrame(body, lat, lon)
    local systemMod = require("src.procgen.system")
    local x, y, z, ux, uy, uz = systemMod.surfacePoint(body, lat, lon, 0)
    -- north = derivative with respect to latitude
    local x2, y2, z2 = systemMod.surfacePoint(body, lat + 0.0005, lon, 0)
    local nx, ny, nz = x2 - x, y2 - y, z2 - z
    local nl = sqrt(nx * nx + ny * ny + nz * nz)
    if nl < 1e-9 then nx, ny, nz, nl = 0, 1, 0, 1 end
    nx, ny, nz = nx / nl, ny / nl, nz / nl
    -- east = north x up
    local ex = ny * uz - nz * uy
    local ey = nz * ux - nx * uz
    local ez = nx * uy - ny * ux
    local el = sqrt(ex * ex + ey * ey + ez * ez)
    if el < 1e-9 then ex, ey, ez, el = 1, 0, 0, 1 end
    return { x = ex / el, y = ey / el, z = ez / el },
           { x = ux, y = uy, z = uz },
           { x = nx, y = ny, z = nz },
           { x = x, y = y, z = z }
end

terrain.PROFILES = PROFILES

return terrain

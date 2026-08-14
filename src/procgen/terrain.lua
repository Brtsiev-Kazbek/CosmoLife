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

    -- craters carved on airless worlds, laid out in an equirectangular grid
    if self.craterAmount > 0.01 then
        local lat = math.asin(util.clamp(dy, -1, 1))
        local lon = (math.atan2 or math.atan)(dz, dx)
        local cu = lon * R * math.cos(lat) / self.craterScale
        local cv = lat * R / self.craterScale
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

--- Colour for a height, straight off the class ramp.  Used by the orbital
--- sphere mesh, which has no slope information.
function Field:colorForHeight(h, latitude)
    local ramp = self.ramp
    local n = #ramp
    if self:isWater(h) then
        -- shallows near the waterline, deep water further down; rivers land in
        -- the shallow band and so read as water too
        local sea = self:seaHeight()
        local depth = util.clamp((sea - h) / (self.amplitude * 0.4), 0, 1)
        local col = palette.mix(ramp[2] or ramp[1], ramp[1], depth)
        -- a little variation across facets so a calm sea is not one flat tone
        local k = 0.94 + ((h - sea) * 0.9 % 0.12)
        return { col[1] * k, col[2] * k, col[3] * k * 1.03, col[4] or 1 }
    end
    local t = util.clamp((h + self.amplitude) / (self.amplitude * 2), 0, 0.999)
    local idx = 1 + t * (n - 1)
    local i0 = floor(idx)
    local col = palette.mix(ramp[max(i0, 1)], ramp[min(i0 + 1, n)], idx - i0)
    -- ice caps: everything past the polar circles whitens out
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
    local ramp = self.ramp
    local n = #ramp
    local t = util.clamp((h + self.amplitude) / (self.amplitude * 2), 0, 0.999)
    -- water first: sea and river channels use the two lowest ramp stops
    local sea = self:seaHeight()
    if self:isWater(h) then
        local depth = util.clamp((sea - h) / (self.amplitude * 0.4), 0, 1)
        return palette.mix(ramp[2] or ramp[1], ramp[1], depth)
    end
    local idx = 1 + t * (n - 1)
    local i0 = floor(idx)
    local i1 = min(i0 + 1, n)
    local f = idx - i0
    local col = palette.mix(ramp[max(i0, 1)], ramp[i1], f)

    if self:isWater(h) then return col end
    -- steep ground shows rock regardless of altitude
    if not ny then
        local _, computed = self:normal(x, z, 30)
        ny = computed
    end
    if ny < 0.82 then
        local rock = palette.colors.rockGrey
        col = palette.mix(col, rock, util.clamp((0.82 - ny) / 0.35, 0, 1))
    end
    return col
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

--- Scatters boulders and, on living worlds, vegetation over a patch.
-- Returned as one baked mesh so scenery costs a single draw call per chunk.
-- Scenery for one chunk.
--
-- This deliberately does *not* cache. It used to keep every mesh it had ever
-- built in `self.scatter`, while the caller (`Surface:update`) released those
-- same meshes when their chunk left the working set -- so walking away from a
-- chunk and back handed the renderer a destroyed Mesh. The scatter belongs to
-- the chunk, and it lives and dies with it.
function Field:buildScatter(ox, oz, size, density)
    local geometry = require("src.render.geometry")
    local rng = Rng.new(self.seed, "scatter", floor(ox), floor(oz))
    local b = MeshBuilder.new()
    local count = floor((density or 1) * 26)
    local vegetated = (self.kind == "terran" or self.kind == "toxic" or self.kind == "ocean")

    for _ = 1, count do
        local x = rng:range(0, size)
        local z = rng:range(0, size)
        local h = self:height(ox + x, oz + z)
        if h > self:seaHeight() + 4 then
            local _, ny = self:normal(ox + x, oz + z, 20)
            if ny > 0.72 then
                b:push():translate(x, h, z)
                b:rotateY(rng:range(0, math.pi * 2))
                if vegetated and rng:bool(0.55) then
                    local th = rng:range(4, 13)
                    geometry.cylinder(b, th * 0.06, th * 0.55, 5, palette.colors.rockDry, nil, 0.7, true)
                    b:push():translate(0, th * 0.5, 0)
                    geometry.cone(b, th * 0.24, th * 0.6, 6, palette.colors.forest, palette.colors.darkGreen)
                    b:pop()
                else
                    local r = rng:range(1.2, 5.5)
                    geometry.rock(b, r, 7, 5, rng, 0.34, palette.colors.rockGrey)
                end
                b:pop()
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

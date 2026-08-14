-- The surface view: a tangent-plane working set on top of a spherical body.
--
-- While the ship is high up, a body is just a sphere mesh.  Below
-- `config.scale.surfaceHandover` this object takes over: it fixes a tangent
-- frame under the ship, streams height field chunks around it, places the
-- settlements that belong on that patch, and answers ground queries.
--
-- Two details make the transition invisible:
--   * chunk vertices are pulled down by x^2+z^2 / 2R, so the flat patch
--     follows the curvature of the sphere it is standing in for and meets the
--     horizon where the sphere does;
--   * the frame is rebuilt from the body's live position and spin every
--     frame, so a landed ship rides its planet around its star.
--
-- Positions inside a surface are *local*: metres east, up and north of the
-- frame origin.  The flight state integrates the ship in these coordinates
-- while it is here, which is what keeps a landed ship glued to a rotating
-- world without any special cases.

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local vec3 = require("src.lib.vec3")
local util = require("src.lib.util")
local config = require("src.config")
local terrain = require("src.procgen.terrain")
local systemGen = require("src.procgen.system")
local settlementGen = require("src.procgen.settlement")

local Surface = class("Surface")

local floor, sqrt, max, min, abs = math.floor, math.sqrt, math.max, math.min, math.abs

local CHUNK = config.render.terrainChunkSize
local settings = require("src.settings")
local RINGS = config.render.terrainRings
local REORIGIN_DISTANCE = CHUNK * 6
local BUILD_BUDGET = 3            -- chunks per frame, to avoid hitches

-- Milliseconds of chunk building allowed in one frame.
--
-- A count is the wrong unit: a near chunk at full resolution and a far chunk
-- at a quarter of it differ by an order of magnitude, so "three chunks" was
-- 6 ms in one place and 98 ms in another -- and 98 ms is exactly the stutter
-- the descent benchmark was reporting. Time is what the player feels, so time
-- is what gets budgeted. At least one chunk is always built, otherwise a slow
-- machine would never finish a patch.
local BUILD_MS = 6

local clock = os.clock
local function nowMs()
    if love and love.timer then return love.timer.getTime() * 1000 end
    return clock() * 1000
end

--- Chunk edge length for an altitude.
--
-- A sphere mesh fine enough to look like ground from 60 km up would need
-- thousands of segments, so above the treetops the patch itself grows: chunks
-- double in size every octave of altitude, keeping roughly the same number of
-- them on screen and the same number of pixels per triangle.  Sizes snap to
-- powers of two of the base so the level is stable and does not flicker.
-- `current` is the level already in force. Rounding to nearest with no dead
-- band meant that hovering at a boundary flipped the level frame to frame,
-- and every flip drops and rebuilds the entire ~120 chunk working set: a
-- sustained stutter with no visible cause. A level is only left once the
-- altitude is well past the point that would have chosen it.
local LOD_HYSTERESIS = 0.28

local function lodSizeFor(altitude, current)
    local target = math.max(CHUNK, (altitude or 0) * 0.55)
    local exact = math.log(target / CHUNK) / math.log(2)
    local level = math.floor(exact + 0.5)
    if current and math.abs(exact - current) < 0.5 + LOD_HYSTERESIS then
        level = current
    end
    if level < 0 then level = 0 elseif level > 5 then level = 5 end
    return CHUNK * (2 ^ level), level
end

function Surface:init(body, opts)
    opts = opts or {}
    self.body = body
    self.field = terrain.field(body)
    self.radius = body.radius
    self.gravity = body.gravity or 9.0
    self.originLat, self.originLon = 0, 0
    self.east = vec3(1, 0, 0)
    self.up = vec3(0, 1, 0)
    self.north = vec3(0, 0, 1)
    self.origin = vec3(0, 0, 0)
    self.settlements = {}
    self.settlementMeshes = {}
    self.pending = {}
    self.active = {}
    self.viewRange = config.scale.terrainViewRange
    self.chunkSize = CHUNK
    self.lodLevel = 0
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

--- Fixes the tangent frame at a latitude/longitude and clears the working set.
function Surface:setOrigin(lat, lon, allSettlements)
    self.originLat, self.originLon = lat, lon
    self.field:setOrigin(lat, lon)
    self:_dropCache(self.chunkCache)
    if self.pendingLod then
        self:_dropCache(self.pendingLod.cache)
        self.pendingLod = nil
    end
    self.chunkCache = {}
    self._wanted = nil
    self.pending = {}
    self.active = {}
    self:refreshFrame()

    -- register the settlements that fall inside this patch so the height
    -- field can flatten their sites before any chunk is built
    self.field.flattens = {}
    self.settlements = {}
    local list = allSettlements or (self.body.settlements or {})
    for _, s in ipairs(list) do
        local x, z = self:latLonToLocal(s.latitude, s.longitude)
        local d = sqrt(x * x + z * z)
        if d < self.viewRange * 2.4 then
            local r = 60 + (s.tier or 2) * 26 + (s.pads or 1) * 8
            local h = self.field:height(x, z)
            self.field.flattens[#self.field.flattens + 1] = { x = x, z = z, r = r * 1.9, h = h }
            self.settlements[#self.settlements + 1] = {
                place = s, x = x, z = z, h = h, radius = r,
            }
        end
    end
end

--- Recomputes the world-space frame from the body's current position/spin.
function Surface:refreshFrame()
    local east, up, north, origin = terrain.tangentFrame(self.body, self.originLat, self.originLon)
    self.east:set(east.x, east.y, east.z)
    self.up:set(up.x, up.y, up.z)
    self.north:set(north.x, north.y, north.z)
    self.origin:set(origin.x, origin.y, origin.z)
end

--- Local (east, up, north) -> world.
function Surface:toWorld(x, y, z, out)
    out = out or vec3()
    out:set(
        self.origin.x + self.east.x * x + self.up.x * y + self.north.x * z,
        self.origin.y + self.east.y * x + self.up.y * y + self.north.y * z,
        self.origin.z + self.east.z * x + self.up.z * y + self.north.z * z)
    return out
end

--- World -> local (east, up, north).
function Surface:toLocal(wx, wy, wz)
    local dx = wx - self.origin.x
    local dy = wy - self.origin.y
    local dz = wz - self.origin.z
    return dx * self.east.x + dy * self.east.y + dz * self.east.z,
           dx * self.up.x + dy * self.up.y + dz * self.up.z,
           dx * self.north.x + dy * self.north.y + dz * self.north.z
end

function Surface:dirToWorld(x, y, z)
    return self.east.x * x + self.up.x * y + self.north.x * z,
           self.east.y * x + self.up.y * y + self.north.y * z,
           self.east.z * x + self.up.z * y + self.north.z * z
end

function Surface:dirToLocal(x, y, z)
    return x * self.east.x + y * self.east.y + z * self.east.z,
           x * self.up.x + y * self.up.y + z * self.up.z,
           x * self.north.x + y * self.north.y + z * self.north.z
end

--- Latitude/longitude -> local metres (small angle, good across a patch).
function Surface:latLonToLocal(lat, lon)
    local dLat = lat - self.originLat
    local dLon = lon - self.originLon
    -- wrap longitude into -pi..pi so a patch near the date line behaves
    dLon = (dLon + math.pi) % (2 * math.pi) - math.pi
    local R = self.radius
    return dLon * R * math.cos(self.originLat), dLat * R
end

function Surface:localToLatLon(x, z)
    local R = self.radius
    return self.originLat + z / R,
           self.originLon + x / (R * max(math.cos(self.originLat), 0.02))
end

-- ---------------------------------------------------------------------------
-- Ground queries
-- ---------------------------------------------------------------------------

--- Terrain height at a local point, including curvature and flattened sites.
function Surface:groundHeight(x, z)
    local h = self.field:height(x, z)
    local flats = self.field.flattens
    if flats then
        for i = 1, #flats do
            local f = flats[i]
            local dx, dz = x - f.x, z - f.z
            local d = sqrt(dx * dx + dz * dz)
            if d < f.r then
                local t = util.smoothstep(f.r, f.r * 0.55, d)
                h = util.lerp(h, f.h, t)
            end
        end
    end
    -- curvature: the flat patch has to bend away like the sphere it replaces
    return h - (x * x + z * z) / (2 * self.radius)
end

--- Height above ground for a local point.
function Surface:altitude(x, y, z) return y - self:groundHeight(x, z) end

--- Upward normal of the ground at a local point.
function Surface:groundNormal(x, z, eps)
    eps = eps or 6
    local hl = self:groundHeight(x - eps, z)
    local hr = self:groundHeight(x + eps, z)
    local hd = self:groundHeight(x, z - eps)
    local hu = self:groundHeight(x, z + eps)
    local nx, ny, nz = hl - hr, 2 * eps, hd - hu
    local l = sqrt(nx * nx + ny * ny + nz * nz)
    return nx / l, ny / l, nz / l
end

--- Is this spot flat and clear enough to set down on?
function Surface:isLandable(x, z, radius)
    local _, ny = self:groundNormal(x, z, radius or 12)
    return ny > math.cos(config.flight.landingAngleMax), ny
end

--- The settlement pad nearest to a local point, if any is in reach.
function Surface:padNear(x, z, maxDistance)
    local best, bestD = nil, maxDistance or 300
    for _, s in ipairs(self.settlements) do
        local mesh = self.settlementMeshes[s.place.seed]
        if mesh then
            for _, p in ipairs(mesh.pads) do
                local px = s.x + p.x
                local pz = s.z + p.z
                local d = sqrt((x - px) ^ 2 + (z - pz) ^ 2)
                if d < bestD then
                    best = { settlement = s, pad = p, x = px, z = pz, distance = d }
                    bestD = d
                end
            end
        end
    end
    return best
end

--- The settlement whose grounds contain a point (for on-foot mode).
function Surface:settlementAt(x, z)
    for _, s in ipairs(self.settlements) do
        local mesh = self.settlementMeshes[s.place.seed]
        if mesh then
            local d = sqrt((x - s.x) ^ 2 + (z - s.z) ^ 2)
            if d < mesh.radius then return s, mesh, d end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Streaming
-- ---------------------------------------------------------------------------

local function chunkKey(cx, cz) return cx .. ":" .. cz end

--- The disc of chunk coordinates that should be resident around (cx0, cz0).
local function ringSet(cx0, cz0, rings)
    local wanted = {}
    for dz = -rings, rings do
        for dx = -rings, rings do
            local d = sqrt(dx * dx + dz * dz)
            if d <= rings + 0.4 then
                local cx, cz = cx0 + dx, cz0 + dz
                wanted[chunkKey(cx, cz)] = { cx = cx, cz = cz, d = d }
            end
        end
    end
    return wanted
end

local function byDistance(a, b) return a.d < b.d end

--- Brings the working set up to date around a local point.
function Surface:update(x, z, dt, altitude)
    self:refreshFrame()
    self.chunkCache = self.chunkCache or {}

    -- Switch detail level with altitude.
    --
    -- This used to drop the entire resident set the instant the level changed
    -- and rebuild it from nothing, which is ~120 chunks -- and a descent
    -- crosses several octaves, so the benchmark measured 300 rebuilds for one
    -- landing, each one a hole in the ground under the ship while it caught
    -- up. The new level is now built *alongside* the old one and swapped in
    -- when its near ring is ready: the same chunks get built, but the player
    -- always has ground to look at, and no frame has to build a whole ring.
    --
    -- The two sets are never drawn together, so nothing z-fights.
    local size, level = lodSizeFor(altitude, self.lodLevel)
    if level ~= self.lodLevel and next(self.chunkCache) == nil then
        -- nothing resident to preserve (a fresh patch): just take the level
        self.chunkSize, self.lodLevel = size, level
        self._wanted = nil
        if self.pendingLod then
            self:_dropCache(self.pendingLod.cache)
            self.pendingLod = nil
        end
    elseif level ~= self.lodLevel then
        if self.pendingLod and self.pendingLod.level ~= level then
            self:_dropCache(self.pendingLod.cache)
            self.pendingLod = nil
        end
        if not self.pendingLod then
            self.pendingLod = { level = level, size = size, cache = {} }
        end
    elseif self.pendingLod then
        -- altitude came back before the swap happened: the level we are
        -- already at is the right one after all
        self:_dropCache(self.pendingLod.cache)
        self.pendingLod = nil
    end
    if self.pendingLod then
        self:_advanceLod(x, z)
        -- While a level is on its way in, the resident set is about to be
        -- thrown away: filling in its outer rings is work that gets discarded
        -- seconds later, and it was the reason the descent benchmark got
        -- *slower* when the swap was first added. Leave it exactly as it is
        -- and spend the frame's budget on the level that will survive.
        if self.pendingLod then
            self:_updateSettlements(x, z)
            return
        end
    end

    local CH = self.chunkSize

    local cx0 = floor(x / CH)
    local cz0 = floor(z / CH)

    -- Mark what should be resident.
    --
    -- The set only changes when the ship crosses a chunk boundary or the
    -- quality preset moves, but this was rebuilt every frame: ~120 tables,
    -- ~120 concatenated string keys and a sort, sixty times a second, to
    -- arrive at the same answer.
    local rings = settings.q().terrainRings
    if self._wantedCx ~= cx0 or self._wantedCz ~= cz0
        or self._wantedRings ~= rings or not self._wanted then
        self._wanted = ringSet(cx0, cz0, rings)
        self._wantedCx, self._wantedCz, self._wantedRings = cx0, cz0, rings
    end
    local wanted = self._wanted

    -- drop chunks that fell out of range
    for key, c in pairs(self.chunkCache) do
        if not wanted[key] then
            if c.model and c.model.mesh and c.model.mesh.release then c.model.mesh:release() end
            if c.scatter and c.scatter.mesh and c.scatter.mesh.release then c.scatter.mesh:release() end
            self.chunkCache[key] = nil
        end
    end

    -- build missing chunks nearest-first, a couple per frame
    local todo = {}
    for key, c in pairs(wanted) do
        if not self.chunkCache[key] then todo[#todo + 1] = { key = key, cx = c.cx, cz = c.cz, d = c.d } end
    end
    table.sort(todo, byDistance)

    -- On a new patch the ground must not be missing under the ship, so the
    -- nearest ring is prioritised and gets a larger slice of the frame; once
    -- it is down, streaming settles to the steady-state slice.
    local budget = settings.q().buildBudget or BUILD_BUDGET
    local ms = BUILD_MS
    if not self.primed then
        local near = 0
        for i = 1, #todo do
            if todo[i].d <= 1.5 then near = near + 1 end
        end
        budget, ms = budget * 3, BUILD_MS * 2
        if near == 0 then self.primed = true end
    end
    self:_buildSome(todo, budget, ms)

    self:_updateSettlements(x, z)
end

--- Detail meshes for any settlement close enough to see, one per frame.
function Surface:_updateSettlements(x, z)
    for _, s in ipairs(self.settlements) do
        local d = sqrt((x - s.x) ^ 2 + (z - s.z) ^ 2)
        if d < math.min(self.viewRange, settings.q().settlementRange)
            and not self.settlementMeshes[s.place.seed] then
            self:_buildSettlement(s)
            return     -- one town per frame is plenty
        end
    end
end

--- Builds from a nearest-first list until the frame's slice is used up.
-- Always builds at least one, so progress is guaranteed however slow the
-- machine is.
function Surface:_buildSome(todo, maxChunks, maxMs, target)
    local deadline = nowMs() + (maxMs or BUILD_MS)
    for i = 1, min(maxChunks, #todo) do
        local t = todo[i]
        self:_buildChunk(t.cx, t.cz, t.d, target)
        if nowMs() >= deadline then return i end
    end
    return min(maxChunks, #todo)
end

--- Releases every mesh in a chunk table and empties it.
function Surface:_dropCache(cache)
    if not cache then return end
    for key, c in pairs(cache) do
        if c.model and c.model.mesh and c.model.mesh.release then c.model.mesh:release() end
        if c.scatter and c.scatter.mesh and c.scatter.mesh.release then c.scatter.mesh:release() end
        cache[key] = nil
    end
end

--- Builds the incoming detail level in the background and swaps it in whole.
--
-- Only the near ring has to be ready to swap: the outer rings then fill in
-- under the ordinary per-frame budget, exactly as they do after a re-origin.
function Surface:_advanceLod(x, z)
    local p = self.pendingLod
    local CH = p.size
    local cx0, cz0 = floor(x / CH), floor(z / CH)
    local rings = settings.q().terrainRings
    if p.cx ~= cx0 or p.cz ~= cz0 or p.rings ~= rings or not p.wanted then
        p.wanted = ringSet(cx0, cz0, rings)
        p.cx, p.cz, p.rings = cx0, cz0, rings
    end

    local todo = self._lodTodo or {}
    self._lodTodo = todo
    for i = #todo, 1, -1 do todo[i] = nil end
    local missingNear = 0
    for key, c in pairs(p.wanted) do
        if not p.cache[key] then
            todo[#todo + 1] = { cx = c.cx, cz = c.cz, d = c.d }
            if c.d <= 1.5 then missingNear = missingNear + 1 end
        end
    end

    if missingNear > 0 then
        table.sort(todo, byDistance)
        local budget = settings.q().buildBudget or BUILD_BUDGET
        self:_buildSome(todo, budget * 3, BUILD_MS, p)
        return
    end

    -- near ring complete: the new level takes over in one step, so there is
    -- never a frame with two sets of ground in it
    self:_dropCache(self.chunkCache)
    self.chunkCache = p.cache
    self.chunkSize = p.size
    self.lodLevel = p.level
    self.pendingLod = nil
    self.primed = true
    self._wanted = nil                -- recompute the resident set at the new size
end

--- Builds one chunk into `target` (a pending LOD set), or into the live one.
function Surface:_buildChunk(cx, cz, ringDistance, target)
    target = target or self
    local CH = target.size or self.chunkSize
    local ox, oz = cx * CH, cz * CH
    -- resolution falls off with distance: near ground is detailed, the far
    -- ring is coarse, and because heights are a pure function of position the
    -- seams between resolutions stay small
    local res = settings.q().terrainRes or config.render.terrainChunk
    if ringDistance > 3 then res = floor(res / 4)
    elseif ringDistance > 1.8 then res = floor(res / 2) end
    res = max(res, 4)

    local b = require("src.render.mesh").new()
    local step = CH / res
    local hs = {}
    for j = 0, res do
        hs[j] = {}
        for i = 0, res do
            hs[j][i] = self:groundHeight(ox + i * step, oz + j * step)
        end
    end
    for j = 0, res - 1 do
        for i = 0, res - 1 do
            local x0, z0 = i * step, j * step
            local x1, z1 = x0 + step, z0 + step
            local h00, h10 = hs[j][i], hs[j][i + 1]
            local h01, h11 = hs[j + 1][i], hs[j + 1][i + 1]
            local hc = (h00 + h10 + h01 + h11) * 0.25
            -- the quad's own corners already describe its slope, so the
            -- colour lookup does not have to re-sample the noise field
            local dhx = ((h10 + h11) - (h00 + h01)) / (2 * step)
            local dhz = ((h01 + h11) - (h00 + h10)) / (2 * step)
            local ny = 1 / sqrt(dhx * dhx + 1 + dhz * dhz)
            local col = self.field:colorAt(ox + x0 + step * 0.5, oz + z0 + step * 0.5, hc, ny)
            if abs(h00 - h11) <= abs(h10 - h01) then
                b:tri(x0, h00, z0, x1, h10, z0, x1, h11, z1, col)
                b:tri(x0, h00, z0, x1, h11, z1, x0, h01, z1, col)
            else
                b:tri(x0, h00, z0, x1, h10, z0, x0, h01, z1, col)
                b:tri(x1, h10, z0, x1, h11, z1, x0, h01, z1, col)
            end
        end
    end

    local chunk = { ox = ox, oz = oz, size = CH, model = b:build(), res = res }
    -- scenery is only worth placing at the finest level, where it is visible
    local level = target.level or self.lodLevel
    local cache = target.cache or self.chunkCache
    if ringDistance <= 1.5 and level == 0 and settings.q().scatter then
        chunk.scatter = self.field:buildScatter(ox, oz, CH, settings.q().scatter and 1 or 0, hs, res)
    end
    cache[chunkKey(cx, cz)] = chunk
    return chunk
end

function Surface:_buildSettlement(s)
    local place = s.place
    local detail = settlementGen.generate({
        seed = place.seed,
        name = place.name,
        tier = place.tier or 2,
        population = place.population,
        economyId = place.economyId,
        techLevel = place.techLevel,
        factionId = place.factionId,
        pads = place.pads or 2,
        services = place.services,
        player = place.player,
    })
    self.settlementMeshes[place.seed] = detail
    return detail
end

--- Ensures a settlement's mesh exists right now (used when landing at one).
function Surface:ensureSettlement(place)
    if self.settlementMeshes[place.seed] then return self.settlementMeshes[place.seed] end
    for _, s in ipairs(self.settlements) do
        if s.place == place then return self:_buildSettlement(s) end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Submits terrain, scatter and settlements to the renderer.
function Surface:draw(renderer, opts)
    local basis = self._basis or {
        right = self.east,
        up = self.up,
        fwd = vec3(-self.north.x, -self.north.y, -self.north.z),
    }
    basis.right = self.east
    basis.up = self.up
    basis.fwd:set(-self.north.x, -self.north.y, -self.north.z)
    self._basis = basis

    local pos = self._drawPos or vec3()
    self._drawPos = pos

    -- A high altitude patch is hundreds of kilometres across, well past the
    -- near layer's far plane, so each chunk picks its own depth layer by how
    -- far away it is.  The two layers overlap, so there is no seam.
    local eye = opts and opts.eye
    local nearOpts = self._nearOpts or { layer = renderer.LAYER_NEAR }
    local farOpts = self._farOpts or { layer = renderer.LAYER_FAR }
    self._nearOpts, self._farOpts = nearOpts, farOpts
    local split = 22000

    for _, c in pairs(self.chunkCache) do
        local o = nearOpts
        if eye then
            local half = (c.size or self.chunkSize) * 0.5
            local dx = c.ox + half - eye.x
            local dz = c.oz + half - eye.z
            local dy = eye.y or 0
            if sqrt(dx * dx + dz * dz + dy * dy) - half > split then o = farOpts end
        end
        if c.model then
            self:toWorld(c.ox, 0, c.oz, pos)
            renderer:draw(c.model, pos, basis, o)
        end
        if c.scatter then
            self:toWorld(c.ox, 0, c.oz, pos)
            renderer:draw(c.scatter, pos, basis, nearOpts)
        end
    end

    for _, s in ipairs(self.settlements) do
        local mesh = self.settlementMeshes[s.place.seed]
        if mesh then
            self:toWorld(s.x, s.h, s.z, pos)
            if mesh.model then
                renderer:draw(mesh.model, pos, basis, { layer = renderer.LAYER_NEAR })
            end
            if mesh.glowModel then
                renderer:draw(mesh.glowModel, pos, basis,
                    { layer = renderer.LAYER_NEAR, emissive = opts and opts.nightGlow or 1 })
            end
        end
    end
end

function Surface:release()
    self:_dropCache(self.chunkCache)
    if self.pendingLod then
        self:_dropCache(self.pendingLod.cache)
        self.pendingLod = nil
    end
    self.chunkCache = {}
    for _, m in pairs(self.settlementMeshes) do
        if m.model and m.model.mesh and m.model.mesh.release then m.model.mesh:release() end
        if m.glowModel and m.glowModel.mesh and m.glowModel.mesh.release then m.glowModel.mesh:release() end
    end
    self.settlementMeshes = {}
    self.primed = false
end

Surface.CHUNK = CHUNK

return Surface

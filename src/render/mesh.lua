-- Mesh building.
--
-- Every visible object in CosmoLife is generated at runtime, so this builder is
-- the single choke point where geometry becomes GPU data.  Design notes:
--
--  * Flat shading is the whole aesthetic, so triangles never share vertices:
--    each triangle contributes three vertices carrying the face normal.  This
--    triples the vertex count but removes every seam-normal problem and lets a
--    single draw call cover an entire city.
--  * The builder owns a transform stack.  Generators (a building, a landing
--    pad, a gun turret) emit geometry in convenient local coordinates and the
--    stack bakes it into one world-space buffer.
--  * `build()` is the only part that touches LOVE, so generators can be unit
--    tested head-less.

local class = require("src.lib.class")
local mat4 = require("src.lib.mat4")

local Builder = class("MeshBuilder")

local sqrt, min, max, floor = math.sqrt, math.min, math.max, math.floor

local VERTEX_FORMAT = {
    { "VertexPosition", "float", 3 },
    { "VertexNormal", "float", 3 },
    { "VertexColor", "byte", 4 },
}

function Builder:init()
    self.verts = {}      -- flat array of per-vertex tables
    self.n = 0
    self.stack = {}
    self.m = mat4.identity()
    self.minx, self.miny, self.minz = math.huge, math.huge, math.huge
    self.maxx, self.maxy, self.maxz = -math.huge, -math.huge, -math.huge
    self.radius = 0
end

-- ---------------------------------------------------------------------------
-- Transform stack
-- ---------------------------------------------------------------------------

function Builder:push()
    self.stack[#self.stack + 1] = mat4.copy(self.m)
    return self
end

function Builder:pop()
    local top = self.stack[#self.stack]
    if not top then error("MeshBuilder: pop without push", 2) end
    self.stack[#self.stack] = nil
    self.m = top
    return self
end

function Builder:apply(m)
    self.m = mat4.mul(self.m, m)
    return self
end

function Builder:translate(x, y, z) return self:apply(mat4.translation(x, y, z)) end
function Builder:scale(x, y, z) return self:apply(mat4.scaling(x, y or x, z or x)) end
function Builder:rotateX(a) return self:apply(mat4.rotationX(a)) end
function Builder:rotateY(a) return self:apply(mat4.rotationY(a)) end
function Builder:rotateZ(a) return self:apply(mat4.rotationZ(a)) end

--- Aligns local +Y with an arbitrary direction (used for antennas, pipes,
--- anything grown along a surface normal).
function Builder:alignY(dx, dy, dz)
    local l = sqrt(dx * dx + dy * dy + dz * dz)
    if l < 1e-9 then return self end
    dx, dy, dz = dx / l, dy / l, dz / l
    local ax, ay, az = 1, 0, 0
    if math.abs(dx) > 0.9 then ax, ay, az = 0, 1, 0 end
    -- right = up x axis
    local rx = dy * az - dz * ay
    local ry = dz * ax - dx * az
    local rz = dx * ay - dy * ax
    local rl = sqrt(rx * rx + ry * ry + rz * rz)
    rx, ry, rz = rx / rl, ry / rl, rz / rl
    local fx = ry * dz - rz * dy
    local fy = rz * dx - rx * dz
    local fz = rx * dy - ry * dx
    return self:apply({ rx, ry, rz, 0, dx, dy, dz, 0, fx, fy, fz, 0, 0, 0, 0, 1 })
end

-- ---------------------------------------------------------------------------
-- Primitive emission
-- ---------------------------------------------------------------------------

-- Vertex colours go to the GPU in 0..1, not 0..255.
--
-- `{"VertexColor", "byte", 4}` is a *normalised* unsigned byte: LOVE 11 takes
-- the component as 0..1 and does the multiply by 255 itself. This used to
-- return 0..255, so every channel of every colour clamped to 1.0 and every
-- surface in the game -- terrain, hulls, buildings, foliage -- was drawn pure
-- white. What reached the screen was therefore not the palette at all but the
-- lighting alone, which is why every biome rendered the same flat blue-grey,
-- why ship hulls came out white, and why night looked lit.
--
-- Measured, not guessed: a triangle written as 0.24/0.90/0.99 read back
-- 0.239/0.898/0.988 through a pass-through shader, and the same colour written
-- as 61/229/252 read back 1.000/1.000/1.000.
--
-- The rounding is kept so the value in `verts` is exactly what the GPU will
-- store, which keeps head-less geometry comparable with a rendered frame.
local function encodeColor(col)
    local a = col[4] or 1
    return floor(min(max(col[1], 0), 1) * 255 + 0.5) / 255,
           floor(min(max(col[2], 0), 1) * 255 + 0.5) / 255,
           floor(min(max(col[3], 0), 1) * 255 + 0.5) / 255,
           floor(min(max(a, 0), 1) * 255 + 0.5) / 255
end

function Builder:_track(x, y, z)
    if x < self.minx then self.minx = x end
    if y < self.miny then self.miny = y end
    if z < self.minz then self.minz = z end
    if x > self.maxx then self.maxx = x end
    if y > self.maxy then self.maxy = y end
    if z > self.maxz then self.maxz = z end
    local d = x * x + y * y + z * z
    if d > self.radius then self.radius = d end
end

--- Adds a triangle given three local-space points and a colour.
-- Winding is counter clockwise as seen from the front face.
function Builder:tri(ax, ay, az, bx, by, bz, cx, cy, cz, col)
    local m = self.m
    local x1, y1, z1 = mat4.mulPoint(m, ax, ay, az)
    local x2, y2, z2 = mat4.mulPoint(m, bx, by, bz)
    local x3, y3, z3 = mat4.mulPoint(m, cx, cy, cz)

    local ux, uy, uz = x2 - x1, y2 - y1, z2 - z1
    local vx, vy, vz = x3 - x1, y3 - y1, z3 - z1
    local nx = uy * vz - uz * vy
    local ny = uz * vx - ux * vz
    local nz = ux * vy - uy * vx
    local nl = sqrt(nx * nx + ny * ny + nz * nz)
    if nl < 1e-12 then return self end   -- degenerate, drop it
    nx, ny, nz = nx / nl, ny / nl, nz / nl

    local r, g, b, a = encodeColor(col)
    local verts, n = self.verts, self.n
    verts[n + 1] = { x1, y1, z1, nx, ny, nz, r, g, b, a }
    verts[n + 2] = { x2, y2, z2, nx, ny, nz, r, g, b, a }
    verts[n + 3] = { x3, y3, z3, nx, ny, nz, r, g, b, a }
    self.n = n + 3

    self:_track(x1, y1, z1)
    self:_track(x2, y2, z2)
    self:_track(x3, y3, z3)
    return self
end

--- Convex quad a-b-c-d (counter clockwise).
function Builder:quad(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, col)
    self:tri(ax, ay, az, bx, by, bz, cx, cy, cz, col)
    self:tri(ax, ay, az, cx, cy, cz, dx, dy, dz, col)
    return self
end

--- Convex polygon fan from an array of {x,y,z} points.
function Builder:poly(points, col)
    for i = 2, #points - 1 do
        local a, b, c = points[1], points[i], points[i + 1]
        self:tri(a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3], col)
    end
    return self
end

--- Appends another builder's geometry, transformed by the current stack.
function Builder:append(other)
    local m = self.m
    local verts, n = self.verts, self.n
    for i = 1, other.n do
        local v = other.verts[i]
        local x, y, z = mat4.mulPoint(m, v[1], v[2], v[3])
        local nx, ny, nz = mat4.mulDir(m, v[4], v[5], v[6])
        local nl = sqrt(nx * nx + ny * ny + nz * nz)
        if nl > 1e-12 then nx, ny, nz = nx / nl, ny / nl, nz / nl end
        verts[n + i] = { x, y, z, nx, ny, nz, v[7], v[8], v[9], v[10] }
        self:_track(x, y, z)
    end
    self.n = n + other.n
    return self
end

-- ---------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------

function Builder:isEmpty() return self.n == 0 end
function Builder:triangleCount() return self.n / 3 end

function Builder:bounds()
    if self.n == 0 then return 0, 0, 0, 0, 0, 0 end
    return self.minx, self.miny, self.minz, self.maxx, self.maxy, self.maxz
end

--- Radius of the bounding sphere centred on the local origin.
function Builder:boundingRadius() return sqrt(self.radius) end

function Builder:center()
    if self.n == 0 then return 0, 0, 0 end
    return (self.minx + self.maxx) * 0.5, (self.miny + self.maxy) * 0.5, (self.minz + self.maxz) * 0.5
end

--- Creates the LOVE mesh.  Returns a `Model`: the GPU mesh plus the metadata
--- the renderer and the collision code need.
function Builder:build(usage)
    if self.n == 0 then return nil end
    local model = {
        triangles = self.n / 3,
        radius = self:boundingRadius(),
        min = { self.minx, self.miny, self.minz },
        max = { self.maxx, self.maxy, self.maxz },
    }
    if love and love.graphics then
        model.mesh = love.graphics.newMesh(VERTEX_FORMAT, self.verts, "triangles", usage or "static")
    else
        model.verts = self.verts       -- head-less mode (tests)
    end
    return model
end

Builder.VERTEX_FORMAT = VERTEX_FORMAT

return Builder

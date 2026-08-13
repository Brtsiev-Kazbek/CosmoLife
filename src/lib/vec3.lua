-- 3D vector helpers.
--
-- Two flavours live here on purpose:
--   * `vec3.new` / metatable operators for readable, non-hot code;
--   * plain "scalar triple" functions (`vec3.addT`, `vec3.normT`, ...) that
--     take and return three numbers, for the inner loops where allocating a
--     table per operation would dominate the frame time.

local vec3 = {}
vec3.__index = vec3

local sqrt, abs = math.sqrt, math.abs

local function new(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vec3)
end
vec3.new = new

function vec3.__add(a, b) return new(a.x + b.x, a.y + b.y, a.z + b.z) end
function vec3.__sub(a, b) return new(a.x - b.x, a.y - b.y, a.z - b.z) end
function vec3.__unm(a) return new(-a.x, -a.y, -a.z) end
function vec3.__eq(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function vec3.__tostring(a) return string.format("(%.3f, %.3f, %.3f)", a.x, a.y, a.z) end

function vec3.__mul(a, b)
    if type(a) == "number" then return new(a * b.x, a * b.y, a * b.z) end
    if type(b) == "number" then return new(a.x * b, a.y * b, a.z * b) end
    return new(a.x * b.x, a.y * b.y, a.z * b.z)
end

function vec3.__div(a, b)
    if type(b) == "number" then return new(a.x / b, a.y / b, a.z / b) end
    return new(a.x / b.x, a.y / b.y, a.z / b.z)
end

function vec3:clone() return new(self.x, self.y, self.z) end

function vec3:set(x, y, z)
    self.x, self.y, self.z = x, y, z
    return self
end

function vec3:copyFrom(o)
    self.x, self.y, self.z = o.x, o.y, o.z
    return self
end

function vec3:addScaled(o, s)
    self.x = self.x + o.x * s
    self.y = self.y + o.y * s
    self.z = self.z + o.z * s
    return self
end

function vec3:scale(s)
    self.x, self.y, self.z = self.x * s, self.y * s, self.z * s
    return self
end

function vec3.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

function vec3.cross(a, b)
    return new(a.y * b.z - a.z * b.y,
               a.z * b.x - a.x * b.z,
               a.x * b.y - a.y * b.x)
end

function vec3:lengthSq() return self.x * self.x + self.y * self.y + self.z * self.z end
function vec3:length() return sqrt(self:lengthSq()) end

function vec3:normalize()
    local l = self:length()
    if l > 1e-12 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end
    return self
end

function vec3:normalized() return self:clone():normalize() end

function vec3.distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function vec3.distanceSq(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

function vec3.lerp(a, b, t)
    return new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

--- Any unit vector perpendicular to `v`.
function vec3.perpendicular(v)
    if abs(v.x) < 0.9 then
        return vec3.cross(v, new(1, 0, 0)):normalize()
    end
    return vec3.cross(v, new(0, 1, 0)):normalize()
end

--- Rotates `v` around unit axis `axis` by `angle` radians (Rodrigues).
function vec3.rotateAround(v, axis, angle)
    local c, s = math.cos(angle), math.sin(angle)
    local d = vec3.dot(axis, v)
    local cr = vec3.cross(axis, v)
    return new(
        v.x * c + cr.x * s + axis.x * d * (1 - c),
        v.y * c + cr.y * s + axis.y * d * (1 - c),
        v.z * c + cr.z * s + axis.z * d * (1 - c))
end

-- ---------------------------------------------------------------------------
-- Allocation free variants (three numbers in, three numbers out).
-- ---------------------------------------------------------------------------

function vec3.addT(ax, ay, az, bx, by, bz) return ax + bx, ay + by, az + bz end
function vec3.subT(ax, ay, az, bx, by, bz) return ax - bx, ay - by, az - bz end
function vec3.mulT(ax, ay, az, s) return ax * s, ay * s, az * s end
function vec3.dotT(ax, ay, az, bx, by, bz) return ax * bx + ay * by + az * bz end

function vec3.crossT(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

function vec3.lenT(x, y, z) return sqrt(x * x + y * y + z * z) end

function vec3.normT(x, y, z)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-12 then return 0, 0, 0 end
    return x / l, y / l, z / l
end

vec3.zero = new(0, 0, 0)
vec3.unitX = new(1, 0, 0)
vec3.unitY = new(0, 1, 0)
vec3.unitZ = new(0, 0, 1)

return setmetatable(vec3, { __call = function(_, x, y, z) return new(x, y, z) end })

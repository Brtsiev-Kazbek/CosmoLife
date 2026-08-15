-- 4x4 matrices, stored as a flat array of 16 numbers in *column major* order
-- so they can be handed to `Shader:send(name, "column", m)` untouched.
--
--   index = column * 4 + row + 1
--
--   m[1] m[5] m[ 9] m[13]
--   m[2] m[6] m[10] m[14]
--   m[3] m[7] m[11] m[15]
--   m[4] m[8] m[12] m[16]

local mat4 = {}

local tan, sqrt = math.tan, math.sqrt

function mat4.identity(out)
    out = out or {}
    for i = 1, 16 do out[i] = 0 end
    out[1], out[6], out[11], out[16] = 1, 1, 1, 1
    return out
end

function mat4.new() return mat4.identity() end

function mat4.copy(m, out)
    out = out or {}
    for i = 1, 16 do out[i] = m[i] end
    return out
end

--- out = a * b  (apply b first, then a -- standard OpenGL convention)
function mat4.mul(a, b, out)
    out = out or {}
    local a1, a2, a3, a4 = a[1], a[2], a[3], a[4]
    local a5, a6, a7, a8 = a[5], a[6], a[7], a[8]
    local a9, a10, a11, a12 = a[9], a[10], a[11], a[12]
    local a13, a14, a15, a16 = a[13], a[14], a[15], a[16]
    for c = 0, 3 do
        local b1, b2, b3, b4 = b[c * 4 + 1], b[c * 4 + 2], b[c * 4 + 3], b[c * 4 + 4]
        out[c * 4 + 1] = a1 * b1 + a5 * b2 + a9 * b3 + a13 * b4
        out[c * 4 + 2] = a2 * b1 + a6 * b2 + a10 * b3 + a14 * b4
        out[c * 4 + 3] = a3 * b1 + a7 * b2 + a11 * b3 + a15 * b4
        out[c * 4 + 4] = a4 * b1 + a8 * b2 + a12 * b3 + a16 * b4
    end
    return out
end

--- Right handed perspective projection (camera looks down -Z), OpenGL clip space.
function mat4.perspective(fovy, aspect, near, far, out)
    out = mat4.identity(out)
    local f = 1 / tan(fovy * 0.5)
    out[1] = f / aspect
    out[6] = f
    out[11] = (far + near) / (near - far)
    out[12] = -1
    out[15] = (2 * far * near) / (near - far)
    out[16] = 0
    return out
end

function mat4.ortho(l, r, b, t, near, far, out)
    out = mat4.identity(out)
    out[1] = 2 / (r - l)
    out[6] = 2 / (t - b)
    out[11] = -2 / (far - near)
    out[13] = -(r + l) / (r - l)
    out[14] = -(t + b) / (t - b)
    out[15] = -(far + near) / (far - near)
    return out
end

--- View matrix from an orthonormal camera basis and an eye position.
-- `fwd` is the direction the camera looks at.
function mat4.view(eye, right, up, fwd, out)
    out = out or {}
    out[1], out[5], out[9] = right.x, right.y, right.z
    out[2], out[6], out[10] = up.x, up.y, up.z
    out[3], out[7], out[11] = -fwd.x, -fwd.y, -fwd.z
    out[4], out[8], out[12] = 0, 0, 0
    out[13] = -(right.x * eye.x + right.y * eye.y + right.z * eye.z)
    out[14] = -(up.x * eye.x + up.y * eye.y + up.z * eye.z)
    out[15] = (fwd.x * eye.x + fwd.y * eye.y + fwd.z * eye.z)
    out[16] = 1
    return out
end

--- Model matrix from an orthonormal basis, a translation and a uniform scale.
-- Object space convention: +X right, +Y up, -Z forward (same as the camera).
function mat4.model(pos, right, up, fwd, scale, out)
    out = out or {}
    scale = scale or 1
    out[1], out[2], out[3], out[4] = right.x * scale, right.y * scale, right.z * scale, 0
    out[5], out[6], out[7], out[8] = up.x * scale, up.y * scale, up.z * scale, 0
    out[9], out[10], out[11], out[12] = -fwd.x * scale, -fwd.y * scale, -fwd.z * scale, 0
    out[13], out[14], out[15], out[16] = pos.x, pos.y, pos.z, 1
    return out
end

function mat4.translation(x, y, z, out)
    out = mat4.identity(out)
    out[13], out[14], out[15] = x, y, z
    return out
end

function mat4.scaling(sx, sy, sz, out)
    out = mat4.identity(out)
    out[1], out[6], out[11] = sx, sy or sx, sz or sx
    return out
end

function mat4.rotationX(a, out)
    out = mat4.identity(out)
    local c, s = math.cos(a), math.sin(a)
    out[6], out[7], out[10], out[11] = c, s, -s, c
    return out
end

function mat4.rotationY(a, out)
    out = mat4.identity(out)
    local c, s = math.cos(a), math.sin(a)
    out[1], out[3], out[9], out[11] = c, -s, s, c
    return out
end

function mat4.rotationZ(a, out)
    out = mat4.identity(out)
    local c, s = math.cos(a), math.sin(a)
    out[1], out[2], out[5], out[6] = c, s, -s, c
    return out
end

--- Transforms a point (w = 1); returns four numbers (x, y, z, w).
function mat4.mulPoint(m, x, y, z)
    return m[1] * x + m[5] * y + m[9] * z + m[13],
           m[2] * x + m[6] * y + m[10] * z + m[14],
           m[3] * x + m[7] * y + m[11] * z + m[15],
           m[4] * x + m[8] * y + m[12] * z + m[16]
end

--- Transforms a direction (w = 0).
function mat4.mulDir(m, x, y, z)
    return m[1] * x + m[5] * y + m[9] * z,
           m[2] * x + m[6] * y + m[10] * z,
           m[3] * x + m[7] * y + m[11] * z
end

--- Inverse of a rigid body transform (rotation + translation, no scale).
function mat4.invertRigid(m, out)
    out = out or {}
    out[1], out[5], out[9] = m[1], m[2], m[3]
    out[2], out[6], out[10] = m[5], m[6], m[7]
    out[3], out[7], out[11] = m[9], m[10], m[11]
    out[4], out[8], out[12] = 0, 0, 0
    local tx, ty, tz = m[13], m[14], m[15]
    out[13] = -(m[1] * tx + m[2] * ty + m[3] * tz)
    out[14] = -(m[5] * tx + m[6] * ty + m[7] * tz)
    out[15] = -(m[9] * tx + m[10] * ty + m[11] * tz)
    out[16] = 1
    return out
end

--- Re-orthonormalises a basis that has drifted after many incremental
--- rotations.  Called every frame on every rotating body.
--- Rebuilds an orthonormal basis from `fwd` and roughly-`up`.
--
-- `handed` is +1 (the default) for a right-handed coordinate system and -1 for
-- a left-handed one. It exists because the surface tangent frame
-- (east, up, north) *is* left-handed -- its determinant is exactly -1 -- and a
-- cross product taken in that frame comes out mirrored. Rebuilding a ship's
-- basis there gave a `right` vector pointing the wrong way, which the flight
-- controls then used to yaw and roll: measured, the reconstructed right and
-- the true right had a dot product of -1.000, and the player's answer was
-- "right is left when I approach a planet".
function mat4.orthonormalize(right, up, fwd, handed)
    local fl = sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
    if fl < 1e-9 then fwd:set(0, 0, -1); fl = 1 end
    fwd.x, fwd.y, fwd.z = fwd.x / fl, fwd.y / fl, fwd.z / fl

    -- With X = right, Y = up, Z = -fwd forming a right handed frame we have
    -- right = fwd x up and up = right x fwd.
    local h = handed or 1
    local rx = (fwd.y * up.z - fwd.z * up.y) * h
    local ry = (fwd.z * up.x - fwd.x * up.z) * h
    local rz = (fwd.x * up.y - fwd.y * up.x) * h
    local rl = sqrt(rx * rx + ry * ry + rz * rz)
    if rl < 1e-6 then
        -- up drifted parallel to fwd: rebuild it from any other axis
        local ax, ay, az = 0, 1, 0
        if math.abs(fwd.y) > 0.9 then ax, ay, az = 1, 0, 0 end
        rx = (fwd.y * az - fwd.z * ay) * h
        ry = (fwd.z * ax - fwd.x * az) * h
        rz = (fwd.x * ay - fwd.y * ax) * h
        rl = sqrt(rx * rx + ry * ry + rz * rz)
        if rl < 1e-9 then rx, ry, rz, rl = 1, 0, 0, 1 end
    end
    right:set(rx / rl, ry / rl, rz / rl)

    -- up = right x fwd, mirrored in a left-handed frame like the cross above
    up:set((right.y * fwd.z - right.z * fwd.y) * h,
           (right.z * fwd.x - right.x * fwd.z) * h,
           (right.x * fwd.y - right.y * fwd.x) * h)
end

return mat4

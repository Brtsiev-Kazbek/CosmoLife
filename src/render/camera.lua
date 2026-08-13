-- Camera.
--
-- The camera lives in absolute world coordinates (doubles, metres).  The
-- renderer only ever uses its orientation plus camera-relative offsets, which
-- is what keeps a 1e11 m wide star system free of floating point jitter.

local class = require("src.lib.class")
local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local util = require("src.lib.util")

local Camera = class("Camera")

function Camera:init()
    self.pos = vec3(0, 0, 0)
    self.right = vec3(1, 0, 0)
    self.up = vec3(0, 1, 0)
    self.fwd = vec3(0, 0, -1)
    self.fov = math.rad(72)
    self.aspect = 16 / 9
    self.shake = 0
    self.shakeOffset = vec3(0, 0, 0)
    self.mode = "cockpit"          -- cockpit | chase | free
    self.chaseDistance = 26
    self.chaseHeight = 7
    self._smoothPos = vec3(0, 0, 0)
    self._hasSmooth = false
end

function Camera:setBasis(right, up, fwd)
    self.right:copyFrom(right)
    self.up:copyFrom(up)
    self.fwd:copyFrom(fwd)
    mat4.orthonormalize(self.right, self.up, self.fwd)
end

--- Attaches the camera to a body (ship, walker) in the current view mode.
function Camera:follow(body, dt, offset)
    local mode = self.mode
    if mode == "cockpit" then
        local o = offset or body.cockpitOffset
        local px, py, pz = body.pos.x, body.pos.y, body.pos.z
        if o then
            px = px + body.right.x * o.x + body.up.x * o.y - body.fwd.x * o.z
            py = py + body.right.y * o.x + body.up.y * o.y - body.fwd.y * o.z
            pz = pz + body.right.z * o.x + body.up.z * o.y - body.fwd.z * o.z
        end
        self.pos:set(px, py, pz)
        self:setBasis(body.right, body.up, body.fwd)
        self._hasSmooth = false
    else
        local dist = self.chaseDistance * (body.chaseScale or 1)
        local tx = body.pos.x - body.fwd.x * dist + body.up.x * self.chaseHeight
        local ty = body.pos.y - body.fwd.y * dist + body.up.y * self.chaseHeight
        local tz = body.pos.z - body.fwd.z * dist + body.up.z * self.chaseHeight
        if not self._hasSmooth then
            self._smoothPos:set(tx, ty, tz)
            self._hasSmooth = true
        else
            -- critically damped follow; snap if the body jumped (hyperspace)
            local d = math.sqrt((tx - self._smoothPos.x) ^ 2 + (ty - self._smoothPos.y) ^ 2 + (tz - self._smoothPos.z) ^ 2)
            if d > dist * 40 then
                self._smoothPos:set(tx, ty, tz)
            else
                local k = 1 - math.exp(-12 * dt)
                self._smoothPos.x = self._smoothPos.x + (tx - self._smoothPos.x) * k
                self._smoothPos.y = self._smoothPos.y + (ty - self._smoothPos.y) * k
                self._smoothPos.z = self._smoothPos.z + (tz - self._smoothPos.z) * k
            end
        end
        self.pos:copyFrom(self._smoothPos)
        local fwd = (body.pos - self.pos):normalize()
        self:setBasis(body.right, body.up, fwd)
    end
    self:updateShake(dt)
end

function Camera:addShake(amount)
    self.shake = math.min(self.shake + amount, 1.5)
end

function Camera:updateShake(dt)
    if self.shake > 0 then
        self.shake = math.max(0, self.shake - dt * 1.6)
        local s = self.shake * self.shake * 0.9
        local t = love and love.timer and love.timer.getTime() or 0
        self.shakeOffset:set(
            math.sin(t * 61.3) * s,
            math.sin(t * 47.7) * s,
            math.sin(t * 83.1) * s * 0.5)
        self.pos.x = self.pos.x + self.right.x * self.shakeOffset.x + self.up.x * self.shakeOffset.y
        self.pos.y = self.pos.y + self.right.y * self.shakeOffset.x + self.up.y * self.shakeOffset.y
        self.pos.z = self.pos.z + self.right.z * self.shakeOffset.x + self.up.z * self.shakeOffset.y
    end
end

--- Rotation-only view matrix (the camera sits at the origin of render space).
function Camera:viewMatrix(out)
    return mat4.view(vec3.zero, self.right, self.up, self.fwd, out)
end

function Camera:projection(near, far, out)
    return mat4.perspective(self.fov, self.aspect, near, far, out)
end

--- Projects a world point to screen coordinates.
-- Returns x, y, depth (metres) or nil when the point is behind the camera.
function Camera:project(wx, wy, wz, screenW, screenH)
    local dx, dy, dz = wx - self.pos.x, wy - self.pos.y, wz - self.pos.z
    local zf = dx * self.fwd.x + dy * self.fwd.y + dz * self.fwd.z
    if zf <= 0.001 then return nil end
    local xr = dx * self.right.x + dy * self.right.y + dz * self.right.z
    local yu = dx * self.up.x + dy * self.up.y + dz * self.up.z
    local t = math.tan(self.fov * 0.5)
    local ndcx = (xr / zf) / (t * self.aspect)
    local ndcy = (yu / zf) / t
    return (ndcx * 0.5 + 0.5) * screenW, (0.5 - ndcy * 0.5) * screenH, zf
end

--- Angle in radians between the view direction and a world point.
function Camera:angleTo(wx, wy, wz)
    local dx, dy, dz = wx - self.pos.x, wy - self.pos.y, wz - self.pos.z
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    if l < 1e-9 then return 0 end
    local d = (dx * self.fwd.x + dy * self.fwd.y + dz * self.fwd.z) / l
    return math.acos(util.clamp(d, -1, 1))
end

return Camera

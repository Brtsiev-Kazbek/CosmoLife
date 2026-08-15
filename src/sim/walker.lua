-- First person controller, shared by the planet surface and by interiors.
--
-- `OnFoot` and `Room` each carried their own copy of "mouse into yaw/pitch,
-- WASD into a velocity", and the two copies disagreed with the camera in
-- opposite ways: outside, moving the mouse right turned you left; inside, D
-- stepped you left.  Both are the same mistake made twice -- writing the
-- sideways vector out by hand instead of deriving it the way the camera does.
--
-- The camera's convention is fixed by `mat4.orthonormalize`: right = fwd x up.
-- Screen-right is `dot(d, camera.right)` (`Camera:project`), so that one
-- formula decides which way the mouse turns you and which way D steps.
--
-- The sign is not a matter of taste, and it is not the same in both places.
-- The surface tangent frame is (east, up, north) with east = north x up
-- (`terrain.tangentFrame`), so east x up = -north: a LEFT handed triple.  An
-- interior is drawn in the plain world axes, which are right handed.  With
-- up = (0,1,0) and fwd = (sin yaw, 0, cos yaw), fwd x up works out to
-- (-cos yaw, 0, sin yaw) in a right handed frame and the negative of that in a
-- left handed one -- so a single `handed` factor covers both, and it is the
-- only place the difference is allowed to live.

local class = require("src.lib.class")
local vec3 = require("src.lib.vec3")
local util = require("src.lib.util")
local config = require("src.config")
local settings = require("src.settings")

local Walker = class("Walker")

local sin, cos, sqrt, exp = math.sin, math.cos, math.sqrt, math.exp

local PITCH_LIMIT = 1.45

--- `frame` is "surface" (east, up, north -- left handed) or "world"
--- (x, y, z -- right handed).
function Walker:init(opts)
    opts = opts or {}
    self.frame = opts.frame or "world"
    self.handed = (self.frame == "surface") and -1 or 1
    self.pos = vec3(opts.x or 0, opts.y or 0, opts.z or 0)
    self.vel = vec3(0, 0, 0)
    self.yaw = opts.yaw or 0
    self.pitch = opts.pitch or 0
    self.onGround = true
    self.running = false
end

-- ---------------------------------------------------------------------------
-- Looking
-- ---------------------------------------------------------------------------

--- Metres-per-pixel of mouse travel, honouring the player's own sensitivity.
--
-- On foot this was a hard coded constant that ignored `mouseSensitivity` and
-- `invertY` entirely, so the settings screen quietly did nothing outside the
-- cockpit.
function Walker.sensitivity()
    local base = config.walk.mouseSens
    local user = settings.get("mouseSensitivity") or 0.055
    local nominal = 0.055                       -- the schema default
    return base * (user / nominal)
end

--- Applies a mouse delta.  Positive `dx` is the mouse moving right, and the
--- view turns right in both frames.
function Walker:look(dx, dy, sens)
    sens = sens or Walker.sensitivity()
    local invert = settings.get("invertY") and -1 or 1
    -- increasing yaw turns towards +right on the surface and towards -right in
    -- world axes, hence the sign of `handed`
    self.yaw = (self.yaw - self.handed * dx * sens) % (math.pi * 2)
    self.pitch = util.clamp(self.pitch - dy * sens * invert, -PITCH_LIMIT, PITCH_LIMIT)
end

--- View direction in frame-local coordinates.
function Walker:forward()
    local cp = cos(self.pitch)
    return sin(self.yaw) * cp, sin(self.pitch), cos(self.yaw) * cp
end

--- Screen-right in frame-local coordinates: fwd x up, with the frame's
--- handedness applied.  Unit length, and flat -- pitch does not roll you.
function Walker:right()
    return self.handed * -cos(self.yaw), 0, self.handed * sin(self.yaw)
end

--- The flat heading, for walking: forward with the pitch taken out.
function Walker:heading()
    return sin(self.yaw), 0, cos(self.yaw)
end

-- ---------------------------------------------------------------------------
-- Walking
-- ---------------------------------------------------------------------------

--- Turns stick/key axes into a unit direction in the tangent plane.
-- `ax` is +1 for "right", `az` is +1 for "forward".
function Walker:wishDir(ax, az)
    if ax == 0 and az == 0 then return 0, 0 end
    local fx, _, fz = self:heading()
    local rx, _, rz = self:right()
    local x = fx * az + rx * ax
    local z = fz * az + rz * ax
    local len = sqrt(x * x + z * z)
    if len < 1e-9 then return 0, 0 end
    return x / len, z / len
end

--- Moves the horizontal velocity towards the wish velocity.
--
-- Ground and air use different rates: on the ground you change direction
-- almost at once, in the air you keep most of your momentum.  Both used to be
-- one constant, which made a jump feel like walking through water.
function Walker:accelerate(dt, wx, wz, speed, accel)
    local W = config.walk
    accel = accel or (self.onGround and W.accelGround or W.accelAir)
    local blend = 1 - exp(-accel * dt)
    self.vel.x = util.lerp(self.vel.x, wx * speed, blend)
    self.vel.z = util.lerp(self.vel.z, wz * speed, blend)
end

--- One walking step: axes in, horizontal velocity out.
-- `opts.speedScale` lets an interior slow the player down without inventing a
-- second set of constants.
function Walker:walk(dt, ax, az, running, opts)
    local W = config.walk
    opts = opts or {}
    self.running = running and (ax ~= 0 or az ~= 0) or false
    local speed = (running and W.runSpeed or W.speed) * (opts.speedScale or 1)
    local wx, wz = self:wishDir(ax, az)
    self:accelerate(dt, wx, wz, speed, opts.accel)
    return wx, wz
end

--- How fast the player is actually moving across the ground, in m/s.
function Walker:groundSpeed()
    return sqrt(self.vel.x * self.vel.x + self.vel.z * self.vel.z)
end

--- Advances the stride and reports when a foot lands.
--
-- Distance covered, not elapsed time: steps then keep pace with the sprint and
-- with any speed scale a low-gravity world applies, without a second set of
-- constants that would drift out of agreement with the first.
function Walker:stride(dt)
    local speed = self:groundSpeed()
    if not self.onGround or speed < 0.6 then
        -- Carry most of the stride across a stop, so shuffling forward does
        -- not reset the count and go silent; drain it slowly so a long pause
        -- starts the next step from the front foot.
        self.strideDistance = (self.strideDistance or 0) * (1 - util.clamp(dt * 2, 0, 1))
        return false
    end
    local W = config.walk
    self.strideDistance = (self.strideDistance or 0) + speed * dt
    if self.strideDistance < (W.strideLength or 1.9) then return false end
    self.strideDistance = self.strideDistance - (W.strideLength or 1.9)
    return true, util.clamp(speed / math.max(W.runSpeed, 1), 0.25, 1)
end

--- Extra field of view while sprinting.  Cheap, and it reads as speed far
--- better than a number on the HUD does.
function Walker:fovBoost()
    local W = config.walk
    if not self.running then return 0 end
    local t = util.clamp(self:groundSpeed() / math.max(W.runSpeed, 1), 0, 1)
    return t * (W.sprintFov or 0)
end

Walker.PITCH_LIMIT = PITCH_LIMIT

return Walker

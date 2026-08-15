-- The mouse as a stick.
--
-- Pulled out of the flight state so the calibration can be checked by a test
-- rather than by feel, which is how it went wrong in the first place: the
-- virtual stick was given the sensitivity number that had been tuned for the
-- *rate* controller it replaced. That number is a fraction of full deflection
-- per pixel, and at its default it worked out at 0.0495 -- so the stick hit
-- the rail after **twenty pixels** of mouse movement. Every touch of the hand
-- pinned it, and with self-centring off the ship then turned on its own until
-- the player dragged the pointer back. Nothing about the scheme was wrong; the
-- one number underneath it was.
--
-- Sensitivity is now expressed the way it is actually chosen -- how far the
-- hand moves for full deflection -- so it cannot silently mean something else
-- again.

local stick = {}

local sqrt, exp, min = math.sqrt, math.exp, math.min

-- Dead zone at the middle, as a fraction of full deflection. Small, because
-- the response curve already gives the fine control; this exists so that
-- "hands off" really is zero rather than a slow creep.
stick.DEAD = 0.04

-- Exponent of the response curve outside the dead zone. Above one, so most of
-- the disc is spent on the small corrections aiming is made of while full
-- deflection still turns as hard as it ever did.
stick.CURVE = 1.6

--- Applies a mouse movement. `range` is pixels to full deflection.
--
-- Clamped to a disc rather than a square: the corner of a square is 1.41 times
-- the deflection of its edge, so a diagonal pull used to turn faster than any
-- straight one.
function stick.move(sx, sy, dx, dy, range, invert)
    range = (range and range > 1) and range or 320
    local nx = (sx or 0) + (dx or 0) / range
    local ny = (sy or 0) + (dy or 0) / range * (invert and -1 or 1)
    local len = sqrt(nx * nx + ny * ny)
    if len > 1 then nx, ny = nx / len, ny / len end
    return nx, ny
end

--- Deflection to command: dead zone, then curve. Returns the pitch/yaw pair
--- and the deflection that should be written back (zero inside the dead zone).
function stick.command(sx, sy)
    sx, sy = sx or 0, sy or 0
    local len = sqrt(sx * sx + sy * sy)
    if len < stick.DEAD then return 0, 0, 0, 0 end
    local k = ((len - stick.DEAD) / (1 - stick.DEAD)) ^ stick.CURVE / len
    return sx * k, sy * k, sx, sy
end

--- Self-centring. `rate` is per second; zero holds the deflection, which is
--- what a real stick does and what a minority of players prefer.
function stick.centre(sx, sy, rate, dt)
    if not rate or rate <= 0 then return sx, sy end
    local decay = exp(-rate * (dt or 0))
    return (sx or 0) * decay, (sy or 0) * decay
end

--- Seconds for the deflection to fall to `fraction` of itself, for a given
--- rate. Only used to state the feel in numbers, in the settings and in tests.
function stick.halfLife(rate)
    if not rate or rate <= 0 then return math.huge end
    return math.log(2) / rate
end

return stick

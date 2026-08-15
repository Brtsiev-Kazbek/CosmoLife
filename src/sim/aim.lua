-- Where to point to hit something that is moving.
--
-- Bolts in this game travel at a finite speed (config.combat.laserSpeed and
-- whatever a weapon overrides it with), so aiming at where a ship *is* misses
-- everything except a stationary target. The lead point is where it will be
-- when the bolt arrives, and showing it is the one HUD element that directly
-- helps a player land a shot rather than telling them about their situation.
--
-- Pure maths, so the answer can be checked without a game running -- and so
-- the NPC gunners can use the same function the player's reticle does rather
-- than a second implementation that disagrees with it.

local aim = {}

local sqrt = math.sqrt

--- Time until a bolt at `speed` catches a target at relative position r moving
--- at relative velocity v, or nil when it never does.
--
-- |r + v t| = speed * t, squared and rearranged, is a quadratic in t:
--
--   (v.v - speed^2) t^2 + 2 (r.v) t + r.r = 0
--
-- The interesting cases are the degenerate ones. When the target is running
-- away at exactly bolt speed the quadratic collapses to a line; when it is
-- outrunning the bolt there is no positive root at all, and the honest answer
-- is "you cannot hit this", not a number.
function aim.time(rx, ry, rz, vx, vy, vz, speed)
    if not speed or speed <= 0 then return nil end
    local a = vx * vx + vy * vy + vz * vz - speed * speed
    local b = 2 * (rx * vx + ry * vy + rz * vz)
    local c = rx * rx + ry * ry + rz * rz
    if c <= 0 then return 0 end

    if math.abs(a) < 1e-6 then
        -- closing speed equals bolt speed: linear, and only solvable if the
        -- bolt is gaining at all
        if math.abs(b) < 1e-12 then return nil end
        local t = -c / b
        return t > 0 and t or nil
    end

    local disc = b * b - 4 * a * c
    if disc < 0 then return nil end
    local root = sqrt(disc)
    local t1 = (-b - root) / (2 * a)
    local t2 = (-b + root) / (2 * a)
    -- the earliest positive intercept is the one a gunner wants
    local t = nil
    if t1 > 0 then t = t1 end
    if t2 > 0 and (not t or t2 < t) then t = t2 end
    return t
end

--- The point to aim at, in the same frame the inputs were given in.
--
-- Returns the offset from the shooter, plus the flight time, or nil when the
-- target cannot be caught.
function aim.lead(rx, ry, rz, vx, vy, vz, speed)
    local t = aim.time(rx, ry, rz, vx, vy, vz, speed)
    if not t then return nil end
    return rx + vx * t, ry + vy * t, rz + vz * t, t
end

return aim

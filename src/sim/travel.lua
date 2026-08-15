-- Getting somewhere without holding a key for a minute.
--
-- Cruise had two problems that had nothing to do with the flight model.
--
-- The first is that it was `config.down("warp")`: the drive ran only while the
-- key was held, so a two minute crossing was two minutes of holding the space
-- bar. Nothing in the game needs that to be a held key, and no modern game
-- would make it one.
--
-- The second is judgement. Cruise speed already scales with distance to mass,
-- but the pilot still had to guess when to throttle back, and guessing wrong
-- means either crawling the last 50 km or shooting past the station at 300
-- km/s. That is not difficulty, it is arithmetic the game can do -- so it
-- does: given a distance and a standoff, this says how fast to be going and
-- when to drop out.
--
-- The autopilot (`flight/autopilot.lua`) is the other end of this: it also
-- takes the steering. Travel assist leaves the pilot flying and only manages
-- the speed, which is what most players want most of the time.
--
-- Plain arithmetic on plain numbers, so the approach can be flown in a test
-- rather than eyeballed.

local travel = {}

local min, max = math.min, math.max

-- Seconds of travel the assist tries to keep in front of the ship. Lower and
-- the last stretch crawls; higher and the drop-out arrives at a speed the
-- Newtonian hull cannot shed. Six seconds puts a 40 000 km approach at about
-- 6.7 km/s and a 4 km one at walking pace.
travel.LOOKAHEAD = 6

-- How close to the standoff counts as arrived, as a fraction of it.
--
-- Without a band the approach never ends: speed proportional to the distance
-- left is an exponential decay, so the remaining distance halves forever and
-- reaches zero never. Worse, a station orbits at about 100 m/s, so the last
-- stretch became a stern chase at matched speed -- measured, the ship parked
-- 2291 m out and stayed there. Arriving is a band, not a point.
travel.ARRIVE = 0.12
travel.ARRIVE_MIN = 250

-- Seconds of the target's own motion that also count as arrived.
--
-- The command below already matches the target's speed, so this is only the
-- slack for the difference between its speed and its speed *along the line of
-- sight*. Two seconds of it is plenty; the first version tried to solve the
-- chase with this term alone and could not -- with a speed proportional to
-- distance the gap settles at exactly `LOOKAHEAD` times the target's speed, so
-- the band would have had to be bigger than the approach it was ending.
travel.CHASE = 2

--- Speed to be doing, and whether to leave cruise.
--
-- `dist`     metres to the target
-- `standoff` metres at which to arrive
-- `ceiling`  the mass-lock speed limit already in force
-- `floor_`   the slowest cruise can go
--
-- Returns { speed, drop, eta }.
function travel.plan(dist, standoff, ceiling, floor_, targetSpeed)
    standoff = standoff or 0
    floor_ = floor_ or 0
    local remaining = (dist or 0) - standoff
    local band = max(standoff * travel.ARRIVE, travel.ARRIVE_MIN,
        (targetSpeed or 0) * travel.CHASE)
    if remaining <= band then
        return { speed = 0, drop = true, eta = 0 }
    end
    -- Closing speed plus the target's own.
    --
    -- Without the second term the ship is not approaching the station, it is
    -- chasing it: a station orbits at about 100 m/s, and a command of
    -- `remaining / LOOKAHEAD` falls below that a few hundred metres out. The
    -- gap then stops closing entirely -- measured, the ship parked 2291 m from
    -- a 1704 m standoff and stayed there for 80 seconds of flight. Matching
    -- the target's velocity first makes the rest a real approach.
    local speed = remaining / travel.LOOKAHEAD + (targetSpeed or 0)
    -- the floor applies only while there is real distance left: inside a few
    -- seconds of the target, crawling is the point
    if remaining > floor_ * travel.LOOKAHEAD then speed = max(speed, floor_) end
    speed = min(speed, ceiling or speed)
    return { speed = speed, drop = false, eta = remaining / max(speed, 1) }
end

--- How far out to stop, for whatever kind of thing is being flown to.
--
-- Shared with the autopilot so that assisted and automatic approaches agree;
-- a station you were dropped at by one should be where the other drops you.
function travel.standoff(contact)
    if not contact then return 1200 end
    if contact.body then return contact.body.radius * 1.9 + 20000 end
    if contact.station then return (contact.station.size or 600) * 2.2 end
    if contact.place then return 9000 end
    return 1200
end

--- A readable estimate for the HUD: seconds, or nil when it means nothing.
function travel.eta(dist, standoff, speed)
    local remaining = (dist or 0) - (standoff or 0)
    if remaining <= 0 or not speed or speed <= 1 then return nil end
    return remaining / speed
end

return travel

-- What the HUD should be showing right now.
--
-- The flight HUD used to draw all eleven of its groups on every frame, so the
-- screen was equally busy in a fight, on final approach and in an empty
-- cruise, and the one thing that mattered in each of those was no more visible
-- than the ten that did not.
--
-- The decision is here rather than in the drawing, for the same reason
-- src/sim/context.lua exists: a rule about what the player should be looking
-- at is worth stating once, in a place a head-less test can ask. `resolve`
-- takes a plain description of the situation and gives back a mode and an
-- opacity per layer; nothing here knows what a gauge looks like.

local hudmode = {}

-- Every group the flight HUD can draw. A mode lists what it wants; anything
-- unlisted is dimmed rather than removed, because a readout that vanishes and
-- reappears is harder to trust than one that fades.
hudmode.LAYERS = {
    "vitals",     -- shield and hull
    "power",      -- fuel and heat
    "drive",      -- throttle, speed, frame shift
    "nav",        -- altitude, vertical speed, horizon
    "cargo",      -- hold and credits
    "scanner",    -- the contact bowl
    "target",     -- target readout
    "banner",     -- system name and faction
    "objective",  -- what to do next
}

-- How far a layer recedes when the situation does not call for it. Not zero:
-- the numbers stay legible if the player goes looking, they simply stop
-- competing for attention.
hudmode.DIM = 0.28

local MODES = {
    -- A fight: what keeps you alive and what you are shooting at. The system
    -- banner and the objective can wait.
    combat = { vitals = 1, power = 1, drive = 1, target = 1, scanner = 1,
               nav = 0.6, cargo = hudmode.DIM, banner = hudmode.DIM,
               objective = hudmode.DIM },
    -- Final approach: the corridor and the closing speed decide whether this
    -- works, and nothing else does.
    approach = { drive = 1, target = 1, vitals = 0.7, scanner = 0.7,
                 nav = hudmode.DIM, power = hudmode.DIM, cargo = hudmode.DIM,
                 banner = hudmode.DIM, objective = 0.6 },
    -- Over ground: height, vertical speed and whether the ground below can be
    -- landed on.
    surface = { nav = 1, drive = 1, vitals = 0.8, power = 0.8, scanner = 0.7,
                target = 0.7, cargo = hudmode.DIM, banner = hudmode.DIM,
                objective = 1 },
    -- Frame shift: there is nothing to shoot, nothing within scanner range
    -- worth drawing, and the only numbers that matter are the drive's.
    cruise = { drive = 1, banner = 0.8, objective = 1, scanner = 0,
               vitals = hudmode.DIM, power = hudmode.DIM, nav = hudmode.DIM,
               cargo = hudmode.DIM, target = 0.7 },
    -- Ordinary flight: the default, and the only mode where everything is on,
    -- because nothing in particular is happening.
    space = { vitals = 1, power = 1, drive = 1, nav = 1, cargo = 1,
              scanner = 1, target = 1, banner = 1, objective = 1 },
}

hudmode.MODES = MODES

-- How long after taking a hit or firing a shot the HUD stays in combat mode.
-- Long enough to cover the gap between passes in a dogfight; short enough that
-- one stray shot does not leave the screen in combat dress for a minute.
hudmode.COMBAT_HOLD = 8

--- Decides the mode from a description of the situation.
--
-- `s` is a plain table, so this can be called from a test with no game:
--   hostileNear   a hostile contact is within scanner range
--   sinceCombat   seconds since the last shot fired or damage taken, or nil
--   docking       true inside a station's approach envelope
--   horizon       true when there is ground close enough to be level with
--   cruise        true in frame shift (spooling counts)
--   landed        true when sitting on a pad or on the ground
function hudmode.resolve(s)
    s = s or {}
    -- Order matters and is a judgement about what is most urgent. Being shot
    -- at outranks being on approach: a station is not going anywhere.
    if s.hostileNear or (s.sinceCombat and s.sinceCombat < hudmode.COMBAT_HOLD) then
        return "combat"
    end
    if s.cruise then return "cruise" end
    if s.docking then return "approach" end
    if s.horizon or s.landed then return "surface" end
    return "space"
end

--- Opacity for one layer in one mode. Unlisted layers dim rather than vanish.
function hudmode.alpha(mode, layer)
    local m = MODES[mode] or MODES.space
    local a = m[layer]
    if a == nil then return hudmode.DIM end
    return a
end

--- The whole set at once, for a caller that wants to look it up per frame.
function hudmode.layers(mode, out)
    out = out or {}
    for _, name in ipairs(hudmode.LAYERS) do
        out[name] = hudmode.alpha(mode, name)
    end
    return out
end

return hudmode

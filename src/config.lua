-- Central tuning.  Everything a designer would want to touch lives here so the
-- rest of the code can stay free of magic numbers.
--
-- Units: metres, seconds, kilograms, radians.  Star systems are deliberately
-- compressed compared to reality (orbits of a few tens of Gm rather than
-- hundreds) so that a cruise across a system is a minute rather than an hour,
-- while planets keep near-realistic radii so that flying over a surface still
-- feels like flying over a world.

local config = {}

config.version = "0.1.0"
config.title = "CosmoLife"

-- ---------------------------------------------------------------------------
-- Scales
-- ---------------------------------------------------------------------------
config.scale = {
    lightYear      = 9.4607e15,
    au             = 1.4959787e11,

    starRadiusMin  = 1.6e8,
    starRadiusMax  = 7.0e8,

    orbitMin       = 2.0e9,
    orbitMax       = 3.2e10,

    -- Orbital and rotation rates.
    --
    -- These are set so that a planet's own motion is *slow next to the ship*:
    -- a world drifts along its orbit at tens of metres per second and its
    -- equator turns at a similar rate.  Get this wrong and nothing near a
    -- planet works -- with a 90 day orbit a world crosses 600 km every second,
    -- outrunning the ship by a thousand to one and tearing the landing frame
    -- apart between one frame and the next.
    orbitPeriodBase   = 900000,   -- days at orbitMin  (~45 m/s)
    dayLengthBase     = 2200,     -- days per rotation (~30 m/s at the equator)
    stationOrbitPeriod = 4000,    -- days

    planetRadiusMin = 1.4e6,
    planetRadiusMax = 7.2e6,
    moonRadiusMin   = 3.0e5,
    moonRadiusMax   = 1.1e6,

    -- atmosphere / rendering handover
    atmosphereHeight = 90000,     -- top of the visible atmosphere
    surfaceHandover  = 140000,    -- below this altitude terrain patches stream in
    terrainViewRange = 24000,     -- terrain draw distance
}

-- ---------------------------------------------------------------------------
-- Flight model
-- ---------------------------------------------------------------------------
config.flight = {
    -- normal-space thrust
    linearAccel    = 90,          -- m/s^2 at full throttle, baseline hull
    boostMultiplier = 3.2,
    boostDuration  = 4.0,
    boostCooldown  = 7.0,
    maxSpeed       = 620,         -- normal space cruise ceiling
    reverseFactor  = 0.45,
    lateralFactor  = 0.55,

    mouseSensitivity = 0.055,     -- mouse pixels -> attitude command
    pitchRate      = 1.35,        -- rad/s
    yawRate        = 0.85,
    rollRate       = 2.20,
    rotDamping     = 3.4,         -- flight assist strength

    -- "warp" / frame shift cruise
    warpAccel      = 1.9,         -- fraction of the target speed gained per second
    warpMinSpeed   = 500,
    warpMaxSpeed   = 3.0e8,
    warpMassLock   = 0.06,        -- speed ceiling = this * distance to surface
    warpSpoolTime  = 1.6,
    warpMinAltitude = 4500,       -- cannot engage closer than this to a surface

    -- atmospheric flight
    dragSeaLevel   = 0.00022,     -- per m/s per second at 1 atm
    liftFactor     = 0.55,
    heatRate       = 1.1e-8,      -- hull heating per (density * v^3)
    heatCooling    = 0.16,

    -- landing
    landingSpeedMax = 22,
    landingAngleMax = math.rad(28),
    landingPadRadius = 24,

    -- landing ("hover") mode: engaged with the gear down near the ground
    hoverAltitude   = 900,        -- metres at which the assist takes over
    hoverSpeed      = 90,         -- taxi speed cap while hovering
    hoverGravityRelief = 0.18,    -- fraction of weight the pilot still feels
}

config.walk = {
    speed        = 5.2,
    runSpeed     = 9.4,
    jumpSpeed    = 4.4,
    eyeHeight    = 1.72,
    gravityScale = 1.0,
    mouseSens    = 0.0026,
    interactRange = 4.5,
}

-- ---------------------------------------------------------------------------
-- Combat
-- ---------------------------------------------------------------------------
config.combat = {
    laserRange      = 3200,
    laserSpeed      = 2600,
    laserLifetime   = 2.4,
    missileSpeed    = 420,
    missileTurn     = 1.6,
    missileLifetime = 26,
    shieldRegenDelay = 6.0,
    scanRange       = 9000,
    aggroRange      = 6500,
    bountyPerKill   = 900,
}

-- ---------------------------------------------------------------------------
-- Economy
-- ---------------------------------------------------------------------------
config.economy = {
    dayLength         = 300,      -- real seconds per in-game day
    priceImpact       = 0.55,     -- how strongly a trade moves the local price
    restockRate       = 0.09,     -- fraction of the gap closed per day
    driftAmplitude    = 0.06,
    illegalRisk       = 0.35,     -- chance a scan finds contraband per second
    fineRate          = 0.6,      -- fraction of cargo value taken as a fine
    startingCredits   = 1400,
    startingCargo     = 8,
}

config.colony = {
    foundCost         = 55000,
    requiredCargo     = { colonists = 4, machinery = 6, provisions = 6 },
    growthPerDay      = 0.011,
    upkeepPerPop      = 0.35,
    taxPerPopPerDay   = 1.4,
    maxTier           = 5,
    tierPopulation    = { 0, 250, 1800, 12000, 65000, 240000 },
}

-- ---------------------------------------------------------------------------
-- Rendering / feel
-- ---------------------------------------------------------------------------
config.render = {
    fov            = math.rad(74),
    lightBands     = 5,
    post           = true,
    starCount      = 1400,
    -- The streamed patch must reach past the far layer's near plane, or there
    -- is a ring of nothing between the terrain and the planet standing in for
    -- it: rings * chunkSize is the radius covered, and 6 * 2600 = 15.6 km.
    terrainChunk   = 24,          -- vertices per chunk edge
    terrainChunkSize = 2600,      -- metres per chunk edge
    terrainRings   = 6,           -- LOD rings around the player
}

-- ---------------------------------------------------------------------------
-- Controls.  Every action maps to a list of keys; the first is what the UI
-- shows in the help overlay.
-- ---------------------------------------------------------------------------
-- The scheme is the one most space sims settled on, because it is the one
-- people already know: the mouse aims the nose, the keyboard does everything
-- that is not aiming.  Pitch and yaw are never on the same keys as the mouse
-- axes, which is what made the first layout so confusing to fly.
-- Key bindings live in `src.input` now (they are player-editable and can be
-- gamepad sources, which a flat table cannot express).  This proxy keeps the
-- old `config.keys.<action>[1]` spelling working and always reflects the live
-- binding rather than a stale copy.
config.keys = setmetatable({}, {
    __index = function(_, action)
        local name = require("src.input").keyName(action)
        return { name:lower() }
    end,
})

--- Control queries delegate to `src.input`, which owns the live bindings and
--- the baton player.  These wrappers exist because most of the codebase calls
--- `config.down("boost")`, and there is no value in touching all of it.
function config.down(action)
    return require("src.input").down(action)
end

function config.is(action, key)
    return require("src.input").is(action, key)
end

function config.keyName(action)
    return require("src.input").keyName(action)
end

return config

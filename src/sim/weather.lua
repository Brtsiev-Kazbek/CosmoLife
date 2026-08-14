-- Weather.
--
-- Every biome already declared what its sky does -- `weather = { dust = 0.9 }`
-- on a dune sea, `{ rain = 0.85, fog = 0.4 }` in a rainforest -- and nothing
-- read any of it. A planet's air was the same clear air everywhere on it, in
-- every season, forever.
--
-- This turns those declarations into a condition at a place and a time. It is
-- deliberately a pure function of (body, position, day): no state to save, the
-- same storm is over the same valley whenever you come back to that hour, and
-- a save game does not have to remember the sky.
--
-- Weather is not decoration. It cuts visibility, which shortens the range at
-- which anything can be seen or scanned, and it pushes: a walker leans into a
-- gale and a ship has to hold a crab angle on approach. A storm that only
-- changed the colours would be a screensaver.

local noise = require("src.lib.noise")
local util = require("src.lib.util")

local weather = {}

local max, min, abs = math.max, math.min, math.abs

--- The kinds, in the order they take precedence when several are possible.
-- A dust storm and rain are not going to happen at once; the strongest of the
-- biome's tendencies wins and the rest become the background haze.
weather.KINDS = { "dust", "rain", "snow", "fog" }

--- Names for the HUD, translated at the call site.
weather.NAME = {
    clear = "Clear", haze = "Haze", dust = "Dust storm",
    rain = "Rain", snow = "Snowfall", fog = "Fog",
}

--- How the sky is doing at a point on a body, on a given day.
--
-- `biome` is the biome there (see procgen.biome); its `weather` table sets what
-- is possible, and the fields here set whether it is happening right now.
--
-- Returns a table with:
--   kind        one of weather.KINDS, or "haze"/"clear"
--   strength    0..1, how hard it is coming down
--   visibility  0..1 multiplier on how far anything can be seen
--   fog         0..1 how much the air itself is doing
--   wind        metres per second, and windAngle in radians
function weather.at(body, biome, x, z, day, out)
    out = out or {}
    local seed = (body.seed or 1) + 4241
    local w = biome and biome.weather or nil

    -- A slow field over the ground and a slower one over time: fronts drift,
    -- so a valley clears while the next one over is still under it.
    local t = (day or 0) * 0.7
    local fx, fz = x / 26000, z / 26000
    local front = noise.perlin3(seed, fx, t, fz) * 0.5 + 0.5
    local gust = noise.perlin3(seed + 17, fx * 5, t * 9, fz * 5) * 0.5 + 0.5

    -- pick the biome's strongest tendency
    local kind, tendency = nil, 0
    if w then
        for _, k in ipairs(weather.KINDS) do
            local v = w[k] or 0
            if v > tendency then kind, tendency = k, v end
        end
    end

    -- An atmosphere is required for weather at all: nothing falls on a rock
    -- with no air, however much the biome would like it to.
    local air = util.clamp(body.atmosphere or 0, 0, 2)
    tendency = tendency * util.clamp(air * 1.4, 0, 1)

    -- `front` decides whether the tendency is being realised here and now
    local strength = util.clamp((front - (1 - tendency)) / max(tendency, 0.05), 0, 1)
    strength = strength * (0.65 + gust * 0.5)
    strength = util.clamp(strength, 0, 1)

    if not kind or strength < 0.08 then
        out.kind = (air > 0.15 and front > 0.62) and "haze" or "clear"
        out.strength = (out.kind == "haze") and 0.25 or 0
    else
        out.kind = kind
        out.strength = strength
    end

    -- Visibility. Fog is the worst of them, dust next; rain and snow cut less
    -- but still enough to matter on an approach.
    local BITE = { fog = 0.85, dust = 0.7, snow = 0.55, rain = 0.4, haze = 0.25, clear = 0 }
    local bite = (BITE[out.kind] or 0) * out.strength
    out.visibility = util.clamp(1 - bite * 0.85, 0.12, 1)
    out.fog = bite

    -- Wind. Steadier than the precipitation, and it turns slowly.
    local wa = noise.perlin3(seed + 31, fx * 0.6, t * 0.5, fz * 0.6)
    out.windAngle = wa * math.pi * 2
    out.wind = (2 + out.strength * 22) * util.clamp(air, 0, 1.4)
    -- gusts, so it does not feel like a constant sideways force
    out.wind = out.wind * (0.7 + gust * 0.6)

    return out
end

--- The colour the air takes on, given the ground's own palette.
function weather.tint(cond, base)
    if not cond or cond.strength <= 0 then return base end
    local DUST = { 0.72, 0.55, 0.36 }
    local RAIN = { 0.42, 0.46, 0.52 }
    local SNOW = { 0.82, 0.86, 0.92 }
    local FOG  = { 0.62, 0.66, 0.70 }
    local target = (cond.kind == "dust" and DUST)
        or (cond.kind == "rain" and RAIN)
        or (cond.kind == "snow" and SNOW)
        or (cond.kind == "fog" and FOG)
    if not target then return base end
    local k = cond.strength * 0.8
    return {
        base[1] + (target[1] - base[1]) * k,
        base[2] + (target[2] - base[2]) * k,
        base[3] + (target[3] - base[3]) * k,
    }
end

--- Sideways acceleration the wind applies, in metres per second squared.
-- `exposure` scales it: a walker feels far more of it than a ship does.
function weather.push(cond, exposure)
    if not cond or cond.wind <= 0 then return 0, 0 end
    local a = cond.wind * (exposure or 1) * 0.04
    return math.cos(cond.windAngle) * a, math.sin(cond.windAngle) * a
end

return weather

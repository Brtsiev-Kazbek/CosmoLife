-- Lighting presets.
--
-- One hard sun and a flat ambient term is physically honest and visually dull:
-- every unlit face collapses to the same dead grey. Real product shots, and
-- every stylised renderer worth copying, use three lights:
--
--   key    the sun. Hard, directional, sets the shape.
--   fill   a soft, cool, opposing light. Stops shadow sides going black and
--          gives them a colour of their own, which is what makes flat-shaded
--          geometry read as *material* rather than as unlit polygons.
--   rim    a back light along the silhouette. Separates a hull from the
--          starfield behind it -- the single cheapest trick for readability.
--
-- The fill direction is derived from the key rather than fixed in world space,
-- so the scheme holds together whichever way the ship is pointing.

local util = require("src.lib.util")
local vec3 = require("src.lib.vec3")

local lighting = {}

--- Each preset is a set of multipliers on top of the star's own colour, so a
--- red dwarf system still looks like a red dwarf system in every preset.
lighting.presets = {
    classic = {
        name = "Classic",
        blurb = "One hard sun, flat ambient. The 1984 look.",
        keyIntensity = 1.00, fillIntensity = 0.0, rimIntensity = 0.0,
        fillColor = { 0.30, 0.38, 0.55 }, rimColor = { 1.0, 1.0, 1.0 },
        ambientScale = 1.0, shadeFloor = 0.06, bands = 4, saturation = 1.0,
    },
    cinematic = {
        name = "Cinematic",
        blurb = "Warm key, cool fill, bright rim. Reads well against space.",
        keyIntensity = 1.05, fillIntensity = 0.34, rimIntensity = 0.55,
        fillColor = { 0.26, 0.40, 0.72 }, rimColor = { 0.72, 0.86, 1.0 },
        ambientScale = 0.85, shadeFloor = 0.05, bands = 5, saturation = 1.12,
    },
    noir = {
        name = "Noir",
        blurb = "Hard key, almost no fill, cold rim. Long shadows.",
        keyIntensity = 1.15, fillIntensity = 0.10, rimIntensity = 0.75,
        fillColor = { 0.18, 0.22, 0.34 }, rimColor = { 0.60, 0.74, 1.0 },
        ambientScale = 0.45, shadeFloor = 0.02, bands = 3, saturation = 0.80,
    },
    sunset = {
        name = "Sunset",
        blurb = "Amber key against a violet fill.",
        keyIntensity = 1.00, fillIntensity = 0.45, rimIntensity = 0.45,
        fillColor = { 0.42, 0.24, 0.62 }, rimColor = { 1.0, 0.72, 0.48 },
        ambientScale = 0.95, shadeFloor = 0.07, bands = 6, saturation = 1.25,
    },
    clinical = {
        name = "Clinical",
        blurb = "Even, bright, unromantic. Best for reading a scene.",
        keyIntensity = 0.90, fillIntensity = 0.55, rimIntensity = 0.25,
        fillColor = { 0.62, 0.66, 0.72 }, rimColor = { 0.9, 0.94, 1.0 },
        ambientScale = 1.35, shadeFloor = 0.12, bands = 0, saturation = 0.95,
    },
}

lighting.order = { "classic", "cinematic", "noir", "sunset", "clinical" }

function lighting.get(id) return lighting.presets[id] or lighting.presets.cinematic end

--- Applies a preset to a renderer environment for the current sun direction.
--
-- `env.sunDir` must already be set (it points the way the light travels).
-- The fill comes from roughly the opposite side and above; the rim from
-- behind the subject relative to the camera.
function lighting.apply(env, presetId, camera)
    local p = lighting.get(presetId)
    env.preset = p

    -- key: the star itself
    env.keyIntensity = p.keyIntensity

    -- Fill: placed opposite the key and tilted towards world up so it reads
    -- as bounce off whatever the subject is over.
    --
    -- Directions here are the way light *travels*, matching `sunDir`, so the
    -- source of the key is at -sunDir.  The fill source therefore sits at
    -- roughly +sunDir, and the light it casts travels back the other way.
    local s = env.sunDir
    local up = env.worldUp
    local tx = s.x + up.x * 0.55      -- direction towards the fill source
    local ty = s.y + up.y * 0.55
    local tz = s.z + up.z * 0.55
    tx, ty, tz = vec3.normT(tx, ty, tz)
    env.fillDir = env.fillDir or vec3()
    env.fillDir:set(-tx, -ty, -tz)
    env.fillColor = {
        p.fillColor[1] * p.fillIntensity,
        p.fillColor[2] * p.fillIntensity,
        p.fillColor[3] * p.fillIntensity,
    }

    env.rimColor = {
        p.rimColor[1] * p.rimIntensity,
        p.rimColor[2] * p.rimIntensity,
        p.rimColor[3] * p.rimIntensity,
    }

    env.shadeFloor = p.shadeFloor
    env.saturation = p.saturation
    return env
end

--- Scales an ambient triple by the preset, so callers can keep computing a
--- physical ambient (day/night, atmosphere) and still respect the style.
function lighting.ambient(env, r, g, b)
    local k = (env.preset and env.preset.ambientScale) or 1
    return { r * k, g * k, b * k }
end

return lighting

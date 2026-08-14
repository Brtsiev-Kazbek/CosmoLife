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
---
--- A note on `saturation`. It sat between 1.15 and 1.55 because the picture
--- looked washed out and this was the nearest knob. The picture looked washed
--- out because every mesh was reaching the GPU white (see mesh.lua), so the
--- grade was compensating for a missing albedo -- and it stacked on top of the
--- per-world lift in terrain.lua. With colour arriving properly these are back
--- to what a grade should be: a nudge, not a repaint.
lighting.presets = {
    classic = {
        name = "Classic",
        blurb = "One hard sun, flat ambient. The 1984 look.",
        keyIntensity = 0.95, fillIntensity = 0.0, rimIntensity = 0.0,
        fillColor = { 0.30, 0.38, 0.55 }, rimColor = { 1.0, 1.0, 1.0 },
        ambientScale = 1.0, shadeFloor = 0.06, bands = 4, saturation = 1.10,
        exposure = 1.30,
    },
    cinematic = {
        name = "Cinematic",
        blurb = "Warm key, cool fill, bright rim. Reads well against space.",
        keyIntensity = 0.85, fillIntensity = 0.26, rimIntensity = 0.30,
        fillColor = { 0.24, 0.40, 0.78 }, rimColor = { 0.66, 0.84, 1.0 },
        ambientScale = 0.70, shadeFloor = 0.04, bands = 5, saturation = 1.15,
        exposure = 1.15,
    },
    noir = {
        name = "Noir",
        blurb = "Hard key, almost no fill, cold rim. Long shadows.",
        keyIntensity = 0.95, fillIntensity = 0.08, rimIntensity = 0.42,
        fillColor = { 0.16, 0.22, 0.38 }, rimColor = { 0.55, 0.72, 1.0 },
        ambientScale = 0.40, shadeFloor = 0.02, bands = 3, saturation = 1.05,
        exposure = 1.35,
    },
    sunset = {
        name = "Sunset",
        blurb = "Amber key against a violet fill.",
        keyIntensity = 0.88, fillIntensity = 0.34, rimIntensity = 0.28,
        fillColor = { 0.46, 0.22, 0.68 }, rimColor = { 1.0, 0.66, 0.42 },
        ambientScale = 0.72, shadeFloor = 0.05, bands = 6, saturation = 1.18,
        exposure = 1.10,
    },
    clinical = {
        name = "Clinical",
        blurb = "Even, bright, unromantic. Best for reading a scene.",
        keyIntensity = 0.80, fillIntensity = 0.38, rimIntensity = 0.14,
        fillColor = { 0.58, 0.64, 0.72 }, rimColor = { 0.9, 0.94, 1.0 },
        ambientScale = 0.95, shadeFloor = 0.10, bands = 0, saturation = 1.08,
        exposure = 1.05,
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
    env.exposure = p.exposure or 1.15
    return env
end

--- Scales an ambient triple by the preset, so callers can keep computing a
--- physical ambient (day/night, atmosphere) and still respect the style.
function lighting.ambient(env, r, g, b)
    local k = (env.preset and env.preset.ambientScale) or 1
    return { r * k, g * k, b * k }
end

-- ---------------------------------------------------------------------------
-- Ambient with a direction
-- ---------------------------------------------------------------------------

-- How much brighter the sky half is than the bounce half. The two average back
-- to the flat ambient they replace, so nothing gets globally brighter or
-- darker -- the light just acquires an up and a down.
local SPREAD = 0.55
-- How far each half is pushed towards its own colour. Full strength would make
-- a face pointing at a sunset sky orange no matter what it is made of.
local TINT = 0.5

local function hueOf(col, out)
    local m = (col[1] + col[2] + col[3]) / 3
    if m < 1e-4 then out[1], out[2], out[3] = 1, 1, 1 return out end
    out[1], out[2], out[3] = col[1] / m, col[2] / m, col[3] / m
    return out
end

--- Splits the flat ambient term into light from the sky and light off the
--- ground, which is what makes a surface with no sun on it still have shape.
--
-- A single scalar ambient plus `shadeFloor` gives every unlit face the same
-- value whichever way it points, so a landscape at dusk is a flat sheet: the
-- one thing that says "this is a slope" is that its top faces see more sky
-- than its underside does. Here the two halves also carry the colour of what
-- they are: the sky over the point, and the ground under it -- so a sunset
-- reaches the terrain instead of stopping at the horizon.
--
-- The tint only applies where there is air to have a colour. In space, and in
-- interiors, the split is achromatic and only the brightness gradient remains.
function lighting.hemisphere(env, sky, bounce)
    local a = env.ambient or { 0, 0, 0 }
    local floor = env.shadeFloor or 0
    local t = util.clamp((env.atmos or 0) * TINT, 0, TINT)

    local upHue = hueOf(env.zenith or a, lighting._upHue or {})
    local dnHue = hueOf(env.ground or a, lighting._dnHue or {})
    lighting._upHue, lighting._dnHue = upHue, dnHue

    for i = 1, 3 do
        local base = (a[i] or 0) + floor
        sky[i] = base * (1 + SPREAD) * util.lerp(1, upHue[i], t)
        bounce[i] = base * (1 - SPREAD) * util.lerp(1, dnHue[i], t)
    end
    return sky, bounce
end

return lighting

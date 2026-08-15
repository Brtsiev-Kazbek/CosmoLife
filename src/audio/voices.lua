-- The catalogue: one function per sound.
--
-- Each returns a buffer from synth.lua, so "what a laser sounds like" is a
-- dozen lines in one place and nothing else in the game has an opinion about
-- it. Nothing here touches `love` either -- these can be built and checked
-- head-less.
--
-- Voices marked `loop = true` are short seamless loops the runtime plays
-- continuously and re-pitches; the rest are one-shots.

local synth = require("src.audio.synth")

local voices = {}

local sin, exp, max, min = math.sin, math.exp, math.max, math.min

-- ---------------------------------------------------------------------------
-- Weapons and damage
-- ---------------------------------------------------------------------------

--- A pulse laser: a falling squeal with a click on the front.
voices.laser = function()
    local b = synth.buffer(0.30)
    synth.layer(b, 0.7, synth.sine(function(t) return 900 * exp(-t * 7) + 180 end))
    synth.layer(b, 0.25, synth.square(function(t) return 450 * exp(-t * 7) + 90 end, 0.35))
    synth.layer(b, 0.20, synth.noise(11))
    synth.lowpass(b, function(t) return 5200 * exp(-t * 9) + 400 end)
    synth.shape(b, synth.ad(0.004, 0.26, 6))
    return synth.clip(synth.normalise(b, 0.75))
end

--- The mining laser: lower, rougher, and it sounds like work rather than a
--- weapon. Same family so the two read as the same hardpoint.
voices.mining = function()
    local b = synth.buffer(0.36)
    synth.layer(b, 0.6, synth.saw(function(t) return 240 * exp(-t * 3) + 70 end))
    synth.layer(b, 0.35, synth.noise(23))
    synth.layer(b, 0.2, synth.sine(function(t) return 60 + 25 * sin(t * 40) end))
    synth.lowpass(b, 1400)
    synth.shape(b, synth.ad(0.02, 0.32, 4))
    return synth.clip(synth.normalise(b, 0.7))
end

--- A hit on a hull or a rock: a short filtered thump with grit on it.
voices.hit = function()
    local b = synth.buffer(0.20)
    synth.layer(b, 0.8, synth.noise(37))
    synth.layer(b, 0.5, synth.sine(function(t) return 320 * exp(-t * 22) + 70 end))
    synth.lowpass(b, function(t) return 2600 * exp(-t * 16) + 200 end)
    synth.shape(b, synth.ad(0.002, 0.17, 7))
    return synth.clip(synth.normalise(b, 0.8))
end

--- A ship coming apart: a long noise tail under a falling body.
voices.explosion = function()
    local b = synth.buffer(1.30)
    synth.layer(b, 1.0, synth.noise(53))
    synth.layer(b, 0.45, synth.sine(function(t) return 150 * exp(-t * 2.4) + 28 end))
    synth.layer(b, 0.25, synth.saw(function(t) return 70 * exp(-t * 1.8) + 20 end))
    synth.lowpass(b, function(t) return 3000 * exp(-t * 2.2) + 90 end)
    synth.shape(b, synth.ad(0.006, 1.25, 3.2))
    return synth.clip(synth.normalise(b, 0.95))
end

--- A missile leaving the rail: a rising hiss.
voices.missile = function()
    local b = synth.buffer(0.55)
    synth.layer(b, 0.9, synth.noise(67))
    synth.layer(b, 0.35, synth.sine(function(t) return 120 + 380 * t end))
    synth.lowpass(b, function(t) return 700 + 3600 * t end)
    synth.shape(b, synth.ad(0.03, 0.5, 2.6))
    return synth.clip(synth.normalise(b, 0.8))
end

--- A shield cell going in: a swell that arrives rather than strikes.
voices.shieldCell = function()
    local b = synth.buffer(0.75)
    synth.layer(b, 0.6, synth.sine(function(t) return 220 + 300 * t end))
    synth.layer(b, 0.4, synth.sine(function(t) return 330 + 450 * t end))
    synth.layer(b, 0.15, synth.noise(71))
    synth.lowpass(b, function(t) return 900 + 2200 * t end)
    synth.shape(b, synth.ahr(0.20, 0.24, 0.30))
    return synth.clip(synth.normalise(b, 0.7))
end

-- ---------------------------------------------------------------------------
-- Ship and port
-- ---------------------------------------------------------------------------

--- Clamps engaging: a heavy, damped clunk.
voices.dock = function()
    local b = synth.buffer(0.60)
    synth.layer(b, 0.8, synth.sine(function(t) return 110 * exp(-t * 5) + 42 end))
    synth.layer(b, 0.5, synth.noise(83))
    synth.layer(b, 0.3, synth.square(function(t) return 70 * exp(-t * 4) + 30 end, 0.5))
    synth.lowpass(b, function(t) return 1100 * exp(-t * 6) + 120 end)
    synth.shape(b, synth.ad(0.005, 0.55, 4.5))
    return synth.clip(synth.normalise(b, 0.85))
end

--- The hatch: air, then a mechanism.
voices.hatch = function()
    local b = synth.buffer(0.85)
    synth.layer(b, 0.9, synth.noise(97))
    synth.layer(b, 0.25, synth.sine(function(t) return 180 * exp(-t * 2) + 60 end))
    synth.lowpass(b, function(t) return 2400 * exp(-t * 3.5) + 260 end)
    synth.shape(b, synth.ahr(0.05, 0.25, 0.5))
    return synth.clip(synth.normalise(b, 0.6))
end

--- Cargo pulled aboard: a short suck with a latch at the end of it.
voices.scoop = function()
    local b = synth.buffer(0.45)
    synth.layer(b, 0.7, synth.noise(103))
    synth.layer(b, 0.4, synth.sine(function(t) return 90 + 260 * t end))
    synth.lowpass(b, function(t) return 600 + 2600 * t end)
    synth.shape(b, synth.ad(0.02, 0.40, 3))
    return synth.clip(synth.normalise(b, 0.65))
end

--- The main drive, as a loop.
--
-- Two saws a hair apart so they beat against each other, which is what stops a
-- steady tone sounding like a test signal, plus noise for the exhaust. The
-- runtime re-pitches this by thrust, so the written pitch is only a reference.
voices.engine = function()
    local b = synth.buffer(0.60)
    synth.layer(b, 0.5, synth.saw(58))
    synth.layer(b, 0.45, synth.saw(58.7))
    synth.layer(b, 0.30, synth.sine(29))
    synth.layer(b, 0.22, synth.noise(127))
    synth.lowpass(b, 900)
    synth.seamless(b, 0.06)
    local out = synth.clip(synth.normalise(b, 0.55))
    out.loop = true
    return out
end

--- Frame shift: the same idea an octave down with a slow sweep over it, so
--- cruise is recognisably the same drive working differently.
voices.cruise = function()
    local b = synth.buffer(0.80)
    synth.layer(b, 0.5, synth.saw(31))
    synth.layer(b, 0.35, synth.sine(function(t) return 46 + 8 * sin(t * 3.2) end))
    synth.layer(b, 0.35, synth.noise(131))
    synth.lowpass(b, function(t) return 500 + 220 * sin(t * 2.1) end)
    synth.seamless(b, 0.08)
    local out = synth.clip(synth.normalise(b, 0.6))
    out.loop = true
    return out
end

-- ---------------------------------------------------------------------------
-- The world
-- ---------------------------------------------------------------------------

--- Wind, as a loop. Filtered noise with a slow swell in it; the runtime sets
--- the gain from the weather and the air density.
voices.wind = function()
    local b = synth.buffer(1.60)
    synth.layer(b, 1.0, synth.noise(149))
    synth.lowpass(b, 700)
    synth.highpass(b, 90)
    synth.shape(b, function(t) return 0.55 + 0.45 * sin(t * 1.7) end)
    synth.seamless(b, 0.12)
    local out = synth.clip(synth.normalise(b, 0.5))
    out.loop = true
    return out
end

--- A boot on the ground. Short, dry, and quiet enough to hear a hundred times.
voices.step = function()
    local b = synth.buffer(0.16)
    synth.layer(b, 0.9, synth.noise(151))
    synth.layer(b, 0.3, synth.sine(function(t) return 140 * exp(-t * 30) + 45 end))
    synth.lowpass(b, function(t) return 1800 * exp(-t * 20) + 180 end)
    synth.shape(b, synth.ad(0.002, 0.13, 9))
    return synth.clip(synth.normalise(b, 0.45))
end

-- ---------------------------------------------------------------------------
-- Interface
-- ---------------------------------------------------------------------------

--- Moving the cursor. Deliberately tiny: this one plays more than any other.
voices.uiMove = function()
    local b = synth.buffer(0.05)
    synth.layer(b, 0.8, synth.sine(1400))
    synth.layer(b, 0.2, synth.sine(2100))
    synth.shape(b, synth.ad(0.002, 0.04, 8))
    return synth.clip(synth.normalise(b, 0.30))
end

--- Choosing something: the same bleep with a step up in it, so confirmation
--- and movement are told apart without looking.
voices.uiSelect = function()
    local b = synth.buffer(0.12)
    synth.layer(b, 0.7, synth.sine(function(t) return t < 0.05 and 900 or 1350 end))
    synth.layer(b, 0.25, synth.sine(function(t) return t < 0.05 and 1800 or 2700 end))
    synth.shape(b, synth.ad(0.003, 0.10, 6))
    return synth.clip(synth.normalise(b, 0.40))
end

--- A warning: two tones a fourth apart, the shape every alarm in the world has.
voices.warn = function()
    local b = synth.buffer(0.42)
    synth.layer(b, 0.7, synth.square(function(t) return t < 0.18 and 620 or 466 end, 0.5))
    synth.lowpass(b, 2200)
    synth.shape(b, synth.ahr(0.01, 0.34, 0.07))
    return synth.clip(synth.normalise(b, 0.5))
end

--- An alert: lower, longer, and it does not resolve.
voices.alert = function()
    local b = synth.buffer(0.60)
    synth.layer(b, 0.7, synth.square(function(t) return 330 + 40 * sin(t * 26) end, 0.4))
    synth.layer(b, 0.25, synth.sine(165))
    synth.lowpass(b, 1600)
    synth.shape(b, synth.ahr(0.02, 0.46, 0.12))
    return synth.clip(synth.normalise(b, 0.55))
end

--- Names in a fixed order, so the tests and the bench can walk the catalogue
--- without depending on `pairs`.
voices.order = {
    "laser", "mining", "hit", "explosion", "missile", "shieldCell",
    "dock", "hatch", "scoop", "engine", "cruise",
    "wind", "step",
    "uiMove", "uiSelect", "warn", "alert",
}

return voices

-- Sound synthesis, in plain Lua.
--
-- Everything else in this game is generated -- the galaxy, the hulls, the
-- towns, the ground -- and the sound is generated too. There are no audio
-- files in the repository and there is not going to be any.
--
-- Nothing here touches `love`. A voice is a flat array of samples in -1..1
-- plus a sample rate, and turning that into something the speakers can play is
-- somebody else's job (src/audio/init.lua). That is the same boundary
-- MeshBuilder draws -- generators run head-less, `build()` is the one place
-- that knows about LOVE -- and it is what lets the shape of a laser be checked
-- by `luajit tests/run.lua` on a machine with no sound card.
--
-- Noise comes from Rng, not from math.random, for the same reason nothing else
-- in this project uses math.random: the same seed has to give the same sound
-- every run.

local Rng = require("src.lib.rng")

local synth = {}

-- 22.05 kHz is half of CD rate and plenty for what this makes: engine hum,
-- wind, impacts and short bleeps have nothing above 11 kHz worth keeping, and
-- it halves both the synthesis cost and the memory a cached voice holds.
synth.RATE = 22050

local sin, exp, floor, max, min, abs = math.sin, math.exp, math.floor, math.max, math.min, math.abs
local TAU = math.pi * 2

-- ---------------------------------------------------------------------------
-- Buffers
-- ---------------------------------------------------------------------------

--- A silent buffer of `seconds`, ready to be written into.
function synth.buffer(seconds, rate)
    rate = rate or synth.RATE
    local n = max(1, floor(seconds * rate))
    local b = { rate = rate, n = n }
    for i = 1, n do b[i] = 0 end
    return b
end

--- Adds `gain` times the value `f(t, i)` returns at every sample.
--
-- Layering by addition is the whole composition model here: a voice is a few
-- of these over one buffer. `t` is seconds from the start, which is what every
-- oscillator and envelope below wants.
function synth.layer(b, gain, f)
    local dt = 1 / b.rate
    for i = 1, b.n do
        b[i] = b[i] + gain * f((i - 1) * dt, i)
    end
    return b
end

--- Multiplies the whole buffer by `f(t)` -- an envelope, or a tremolo.
function synth.shape(b, f)
    local dt = 1 / b.rate
    for i = 1, b.n do
        b[i] = b[i] * f((i - 1) * dt)
    end
    return b
end

-- ---------------------------------------------------------------------------
-- Oscillators
-- ---------------------------------------------------------------------------

--- Sine at `hz`, or at `hz(t)` for a sweep.
function synth.sine(hz, phase)
    local p = phase or 0
    if type(hz) == "number" then
        return function(t) return sin(t * hz * TAU + p) end
    end
    -- A swept sine has to integrate its frequency: using hz(t) directly in the
    -- phase makes the pitch curve and the *rate of change* of pitch disagree,
    -- which is audible as a warble rather than a glide.
    local acc, last = 0, 0
    return function(t)
        acc = acc + hz(t) * (t - last)
        last = t
        return sin(acc * TAU + p)
    end
end

--- Sawtooth: bright, buzzy, what an engine is built from.
function synth.saw(hz)
    local f = type(hz) == "number" and function() return hz end or hz
    local acc, last = 0, 0
    return function(t)
        acc = acc + f(t) * (t - last)
        last = t
        return (acc % 1) * 2 - 1
    end
end

--- Square, with a duty cycle. Duty away from 0.5 thins it towards a pulse.
function synth.square(hz, duty)
    duty = duty or 0.5
    local f = type(hz) == "number" and function() return hz end or hz
    local acc, last = 0, 0
    return function(t)
        acc = acc + f(t) * (t - last)
        last = t
        return ((acc % 1) < duty) and 1 or -1
    end
end

--- White noise from a seeded generator, so a given voice sounds the same every
--- time the game is started.
function synth.noise(seed)
    local rng = Rng.new(seed or 1, "synth")
    return function() return rng:float() * 2 - 1 end
end

-- ---------------------------------------------------------------------------
-- Envelopes and filters
-- ---------------------------------------------------------------------------

--- Attack/decay envelope with an exponential tail, as a function of t.
--
-- Exponential rather than linear because that is what impacts do, and a linear
-- decay reads as a synthesiser rather than as an event.
function synth.ad(attack, decay, curve)
    curve = curve or 5
    return function(t)
        if t < attack then return attack > 0 and (t / attack) or 1 end
        local d = (t - attack) / max(decay, 1e-5)
        if d >= 1 then return 0 end
        return exp(-d * curve)
    end
end

--- Attack, hold, release -- for anything with a body, like a klaxon.
function synth.ahr(attack, hold, release)
    return function(t)
        if t < attack then return attack > 0 and (t / attack) or 1 end
        if t < attack + hold then return 1 end
        local r = (t - attack - hold) / max(release, 1e-5)
        return r >= 1 and 0 or (1 - r)
    end
end

--- One-pole low pass, in place. `cutoff` in Hz, or a function of t for a sweep.
--
-- One pole is a gentle slope, which is the point: this is here to take the
-- fizz off noise and to make a hard edge sound like it happened behind
-- something, not to build a synth voice out of resonance.
function synth.lowpass(b, cutoff)
    local f = type(cutoff) == "number" and function() return cutoff end or cutoff
    local dt = 1 / b.rate
    local y = 0
    for i = 1, b.n do
        local hz = max(f((i - 1) * dt), 1)
        local a = 1 - exp(-TAU * hz * dt)
        y = y + a * (b[i] - y)
        b[i] = y
    end
    return b
end

--- One-pole high pass, in place: the signal minus its own low pass.
function synth.highpass(b, cutoff)
    local f = type(cutoff) == "number" and function() return cutoff end or cutoff
    local dt = 1 / b.rate
    local y = 0
    for i = 1, b.n do
        local hz = max(f((i - 1) * dt), 1)
        local a = 1 - exp(-TAU * hz * dt)
        y = y + a * (b[i] - y)
        b[i] = b[i] - y
    end
    return b
end

-- ---------------------------------------------------------------------------
-- Finishing
-- ---------------------------------------------------------------------------

--- Scales the buffer so its loudest sample is `peak`.
--
-- Every voice ends with this. Without it the catalogue's relative volumes come
-- out of whatever the layer gains happened to add up to, and balancing sounds
-- against each other turns into balancing arithmetic.
function synth.normalise(b, peak)
    peak = peak or 0.9
    local hi = 0
    for i = 1, b.n do
        local v = abs(b[i])
        if v > hi then hi = v end
    end
    if hi < 1e-6 then return b end
    local k = peak / hi
    for i = 1, b.n do b[i] = b[i] * k end
    return b
end

--- Makes a buffer loop without a click.
--
-- A loop whose end does not meet its start pops once per cycle, and at the
-- length these loops are that is a rattle rather than a click. Cross-fading
-- the tail over the head costs a few milliseconds of the loop and removes it.
function synth.seamless(b, fade)
    local f = min(floor((fade or 0.05) * b.rate), floor(b.n / 3))
    if f < 2 then return b end
    for i = 0, f - 1 do
        local k = i / f
        local head = b[i + 1]
        local tail = b[b.n - f + i + 1]
        b[i + 1] = head * k + tail * (1 - k)
    end
    b.n = b.n - f
    for i = b.n + 1, b.n + f do b[i] = nil end
    return b
end

--- Clamps into -1..1, so a sum of layers cannot wrap round in the encoder.
function synth.clip(b)
    for i = 1, b.n do
        b[i] = max(-1, min(1, b[i]))
    end
    return b
end

return synth

-- The sound runtime: the one file here that knows LOVE exists.
--
-- src/audio/synth.lua and voices.lua are plain Lua that produce arrays of
-- samples. This turns those into SoundData and Sources, keeps a small pool so
-- overlapping shots do not cut each other off, holds the continuous voices --
-- the drive, the wind -- and applies the volumes from the settings screen.
--
-- Every voice is built on first use rather than at startup. The whole
-- catalogue is about 20 ms of synthesis, which is a visible hitch if it lands
-- in one frame at the title screen, and most of a session never fires a
-- missile or opens a hatch.
--
-- If there is no sound device -- a head-less run, a CI box, a machine with
-- audio disabled -- `available` goes false, every entry point becomes a no-op
-- and nothing else in the game has to care.

local voices = require("src.audio.voices")
local util = require("src.lib.util")

local audio = {}

-- How many copies of a one-shot can overlap. Four is enough for a burst of
-- laser fire; past that the fifth stealing the oldest source is inaudible.
local POOL = 4

audio.available = false
audio.reason = "not initialised"

audio.volume = { master = 0.8, effects = 1.0, ambience = 1.0 }

local cache = {}          -- name -> { data = SoundData, sources = { Source } }
local loops = {}          -- name -> { source, gain, target, pitch }

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function audio.init()
    if not (love and love.audio and love.sound) then
        audio.available, audio.reason = false, "love.audio is not available"
        return false
    end
    -- Creating a source is the only thing that actually reaches the driver, so
    -- it is the only honest test of whether there is one. A silent one-sample
    -- buffer costs nothing and answers the question.
    local ok, err = pcall(function()
        local probe = love.sound.newSoundData(8, 8000, 16, 1)
        local src = love.audio.newSource(probe, "static")
        src:release()
    end)
    if not ok then
        audio.available, audio.reason = false, tostring(err)
        return false
    end
    audio.available, audio.reason = true, nil
    return true
end

--- Pushes the settings screen's volumes in. Called from Game:applySettings.
function audio.setVolume(master, effects, ambience)
    audio.volume.master = util.clamp(master or 0.8, 0, 1)
    audio.volume.effects = util.clamp(effects or 1, 0, 1)
    audio.volume.ambience = util.clamp(ambience or 1, 0, 1)
    -- the continuous voices are already playing, so they have to be told now
    -- rather than at the next update
    for _, l in pairs(loops) do
        if l.source then
            l.source:setVolume(l.gain * audio.volume.master * audio.volume.ambience)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

local function toSoundData(buffer)
    local data = love.sound.newSoundData(buffer.n, buffer.rate, 16, 1)
    for i = 1, buffer.n do
        data:setSample(i - 1, buffer[i])
    end
    return data
end

--- Builds a voice on first use and keeps it.
local function entry(name)
    local e = cache[name]
    if e then return e end
    local make = voices[name]
    if not make then return nil end

    local ok, result = pcall(function()
        local buffer = make()
        local data = toSoundData(buffer)
        local first = love.audio.newSource(data, "static")
        first:setLooping(buffer.loop or false)
        return { data = data, loop = buffer.loop or false, sources = { first } }
    end)
    if not ok then
        audio.available, audio.reason = false, tostring(result)
        return nil
    end
    cache[name] = result
    return result
end

audio._entry = entry

--- A source for `name` that is not currently busy.
local function freeSource(e)
    for i = 1, #e.sources do
        if not e.sources[i]:isPlaying() then return e.sources[i] end
    end
    if #e.sources < POOL then
        local clone = e.sources[1]:clone()
        e.sources[#e.sources + 1] = clone
        return clone
    end
    -- all busy: take the oldest, which is the one that has been audible longest
    local oldest = e.sources[1]
    oldest:stop()
    return oldest
end

-- ---------------------------------------------------------------------------
-- Playing
-- ---------------------------------------------------------------------------

--- Fires a one-shot. `opts.volume` 0..1 and `opts.pitch` scale the voice.
function audio.play(name, opts)
    if not audio.available then return end
    local e = entry(name)
    if not e or e.loop then return end
    local src = freeSource(e)
    if not src then return end
    opts = opts or {}
    src:setVolume((opts.volume or 1) * audio.volume.effects * audio.volume.master)
    src:setPitch(util.clamp(opts.pitch or 1, 0.25, 4))
    src:stop()
    src:play()
end

--- Sets where a continuous voice should be. Gain 0 stops it.
--
-- The gain is a *target*: audio.update moves towards it, because a drive that
-- jumps to full the instant the throttle moves sounds like a switch rather
-- than an engine.
function audio.loop(name, gain, pitch)
    if not audio.available then return end
    local l = loops[name]
    if not l then
        l = { gain = 0, target = 0, pitch = 1 }
        loops[name] = l
    end
    l.target = util.clamp(gain or 0, 0, 1)
    l.pitch = util.clamp(pitch or 1, 0.25, 4)
end

--- Moves the continuous voices towards their targets. Call once a frame.
function audio.update(dt)
    if not audio.available then return end
    for name, l in pairs(loops) do
        -- fade in slower than out: an engine spools up and cuts off
        local rate = (l.target > l.gain) and 2.4 or 4.5
        l.gain = l.gain + (l.target - l.gain) * util.clamp(dt * rate, 0, 1)
        if l.gain < 0.004 and l.target <= 0 then
            l.gain = 0
            if l.source and l.source:isPlaying() then l.source:stop() end
        elseif l.gain > 0 then
            if not l.source then
                local e = entry(name)
                l.source = e and e.sources[1] or nil
            end
            if l.source then
                l.source:setVolume(l.gain * audio.volume.ambience * audio.volume.master)
                l.source:setPitch(l.pitch)
                if not l.source:isPlaying() then l.source:play() end
            end
        end
    end
end

--- Silences everything: used when a state that owns the soundscape goes away.
function audio.stopLoops()
    for _, l in pairs(loops) do
        l.target, l.gain = 0, 0
        if l.source and l.source:isPlaying() then l.source:stop() end
    end
end

--- Names of every voice, for tests and the bench.
function audio.names() return voices.order end

return audio

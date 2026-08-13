-- Player settings: input feel, graphics, and the key bindings themselves.
--
-- Settings are persisted separately from the save game, because they belong to
-- the person rather than to the commander: starting a new game must not reset
-- your mouse sensitivity.

local serialize = require("src.lib.serialize")
local util = require("src.lib.util")

local settings = {}

local FILE = "cosmolife-settings.lua"

--- The schema drives both the defaults and the settings screen, so adding an
--- option in one place makes it appear, persist and validate everywhere.
settings.schema = {
    {
        section = "Flight",
        items = {
            { id = "mouseFlight", name = "Mouse flight", type = "bool", default = true,
              help = "Mouse aims the nose. Off puts attitude on I/K/J/L." },
            { id = "mouseSensitivity", name = "Mouse sensitivity", type = "number",
              default = 0.055, min = 0.01, max = 0.20, step = 0.005, format = "%.3f" },
            { id = "invertY", name = "Invert pitch", type = "bool", default = false },
            { id = "flightAssist", name = "Flight assist", type = "bool", default = true,
              help = "Bleeds off sideways drift so the ship goes where it points." },
            { id = "autoLevel", name = "Auto-level near ground", type = "bool", default = true,
              help = "Rolls the ship upright when a horizon is available." },
            { id = "landingAssist", name = "Landing mode", type = "bool", default = true,
              help = "Gear down near the ground: holds level and hovers." },
            { id = "throttleWheel", name = "Wheel controls throttle", type = "bool", default = true },
        },
    },
    {
        section = "Camera",
        items = {
            { id = "defaultView", name = "Default view", type = "choice", default = "chase",
              choices = { "chase", "cockpit" } },
            { id = "fov", name = "Field of view", type = "number", default = 74,
              min = 55, max = 105, step = 1, format = "%.0f" },
            { id = "cameraShake", name = "Camera shake", type = "number", default = 1.0,
              min = 0, max = 2, step = 0.1, format = "%.1f" },
            { id = "horizonLock", name = "Horizon levelling", type = "number", default = 1.0,
              min = 0, max = 1, step = 0.1, format = "%.1f",
              help = "How strongly the view stays level with the ground." },
        },
    },
    {
        section = "Graphics",
        items = {
            { id = "lightingPreset", name = "Lighting", type = "choice", default = "cinematic",
              choices = { "classic", "cinematic", "noir", "sunset", "clinical" } },
            { id = "lightBands", name = "Light bands", type = "number", default = 5,
              min = 0, max = 12, step = 1, format = "%.0f",
              help = "0 is smooth shading; low values give hard retro banding." },
            { id = "post", name = "CRT filter", type = "bool", default = true },
            { id = "scanline", name = "Scanlines", type = "number", default = 0.35,
              min = 0, max = 1, step = 0.05, format = "%.2f" },
            { id = "vignette", name = "Vignette", type = "number", default = 0.55,
              min = 0, max = 1, step = 0.05, format = "%.2f" },
            { id = "aberration", name = "Chromatic aberration", type = "number", default = 0.6,
              min = 0, max = 2, step = 0.1, format = "%.1f" },
            { id = "terrainRings", name = "Terrain draw distance", type = "number", default = 6,
              min = 3, max = 10, step = 1, format = "%.0f" },
        },
    },
}

settings.values = {}

--- Flattens the schema into an id -> item lookup.
settings.items = {}
for _, group in ipairs(settings.schema) do
    for _, item in ipairs(group.items) do
        settings.items[item.id] = item
    end
end

function settings.reset()
    for id, item in pairs(settings.items) do
        settings.values[id] = item.default
    end
    settings.bindings = nil
end

--- Reads a setting, falling back to the default if it was never set.
function settings.get(id)
    local v = settings.values[id]
    if v == nil then
        local item = settings.items[id]
        return item and item.default
    end
    return v
end

--- Writes a setting, clamped and validated against its schema entry.
function settings.set(id, value)
    local item = settings.items[id]
    if not item then return false end
    if item.type == "number" then
        value = util.clamp(tonumber(value) or item.default, item.min, item.max)
    elseif item.type == "bool" then
        value = value and true or false
    elseif item.type == "choice" then
        local ok = false
        for _, c in ipairs(item.choices) do if c == value then ok = true end end
        if not ok then value = item.default end
    end
    settings.values[id] = value
    return true
end

--- Cycles an option: booleans flip, choices advance, numbers step by `dir`.
function settings.step(id, dir)
    local item = settings.items[id]
    if not item then return end
    if item.type == "bool" then
        settings.set(id, not settings.get(id))
    elseif item.type == "choice" then
        local cur = settings.get(id)
        local idx = 1
        for i, c in ipairs(item.choices) do if c == cur then idx = i end end
        idx = ((idx - 1 + dir) % #item.choices) + 1
        settings.set(id, item.choices[idx])
    else
        settings.set(id, settings.get(id) + item.step * dir)
    end
end

function settings.display(id)
    local item = settings.items[id]
    local v = settings.get(id)
    if item.type == "bool" then return v and "on" or "off" end
    if item.type == "number" then return string.format(item.format or "%.2f", v) end
    return tostring(v)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function settings.save()
    if not (love and love.filesystem) then return false end
    local data = { values = settings.values, bindings = settings.bindings }
    local ok, text = pcall(serialize.encode, data)
    if not ok then return false, text end
    return love.filesystem.write(FILE, text)
end

function settings.load()
    settings.reset()
    if not (love and love.filesystem) then return false end
    if not love.filesystem.getInfo(FILE) then return false end
    local data = serialize.decode(love.filesystem.read(FILE))
    if type(data) ~= "table" then return false end
    for id, v in pairs(data.values or {}) do settings.set(id, v) end
    settings.bindings = data.bindings
    return true
end

settings.reset()

return settings

-- Input.
--
-- Built on baton (lib/baton.lua), which gives us three things that are
-- tedious to get right by hand: one action can have several sources at once
-- (key, mouse button, gamepad button, analogue axis), analogue pairs come back
-- as a properly deadzoned and normalised vector, and a gamepad can be hot
-- plugged.  This module owns the binding table, so the settings screen edits
-- one place and everything downstream keeps working.
--
-- Actions are addressed by name everywhere in the game: `input.down("boost")`,
-- never `love.keyboard.isDown("lshift")`.

local baton = require("lib.baton")
local settings = require("src.settings")

local input = {}

--- The default bindings.  Each entry is a list of baton sources:
---   key:<name>   keyboard
---   sc:<name>    scancode (layout independent)
---   mouse:<n>    mouse button
---   button:<n>   gamepad button
---   axis:<name>  gamepad axis, suffixed + or -
input.defaults = {
    -- flight
    throttleUp   = { "key:w", "key:up", "axis:lefty-" },
    throttleDown = { "key:s", "key:down", "axis:lefty+" },
    rollLeft     = { "key:a", "key:left", "axis:leftx-" },
    rollRight    = { "key:d", "key:right", "axis:leftx+" },
    pitchUp      = { "key:k", "axis:righty+" },
    pitchDown    = { "key:i", "axis:righty-" },
    yawLeft      = { "key:j", "axis:triggerleft" },
    yawRight     = { "key:l", "axis:triggerright" },
    strafeLeft   = { "key:q", "button:leftshoulder" },
    strafeRight  = { "key:e", "button:rightshoulder" },
    thrustUp     = { "key:r", "button:y" },
    thrustDown   = { "key:f", "button:a" },
    throttleFull = { "key:z" },
    throttleZero = { "key:x" },
    boost        = { "key:lshift", "key:rshift", "button:leftstick" },
    warp         = { "key:lctrl", "key:rctrl", "button:x" },
    levelOut     = { "key:h" },
    autopilot    = { "key:tab", "button:dpup" },
    mouseFlight  = { "key:backspace" },

    -- combat and systems
    fire         = { "key:space", "mouse:1", "axis:triggerright" },
    missile      = { "key:2", "mouse:3" },
    target       = { "key:t", "button:dpright" },
    nextTarget   = { "key:y" },
    scan         = { "key:b", "button:dpleft" },
    landingGear  = { "key:g", "button:dpdown" },
    view         = { "key:v", "button:rightstick" },
    dock         = { "key:return", "button:start" },
    disembark    = { "key:u" },

    -- screens
    map          = { "key:m", "button:back" },
    missions     = { "key:n" },
    colony       = { "key:c" },
    ship         = { "key:o" },
    settings     = { "key:f10" },

    -- on foot
    interact     = { "key:e", "key:return", "button:a" },
    jump         = { "key:space", "button:a" },
    run          = { "key:lshift", "button:leftstick" },

    -- meta
    pause        = { "key:escape", "button:start" },
    help         = { "key:f1" },
    save         = { "key:f5" },
    load         = { "key:f9" },
}

--- Human readable order and labels for the rebinding screen.
input.actionOrder = {
    { "Flight", { "throttleUp", "throttleDown", "rollLeft", "rollRight",
                  "pitchUp", "pitchDown", "yawLeft", "yawRight",
                  "strafeLeft", "strafeRight", "thrustUp", "thrustDown",
                  "throttleFull", "throttleZero", "boost", "warp",
                  "levelOut", "mouseFlight", "autopilot" } },
    { "Combat", { "fire", "missile", "target", "nextTarget", "scan" } },
    { "Ship",   { "landingGear", "view", "dock", "disembark" } },
    { "Screens", { "map", "missions", "colony", "ship", "settings", "pause", "help" } },
    { "On foot", { "interact", "jump", "run" } },
}

input.labels = {
    throttleUp = "Throttle up", throttleDown = "Throttle down",
    rollLeft = "Roll left", rollRight = "Roll right",
    pitchUp = "Pitch up", pitchDown = "Pitch down",
    yawLeft = "Yaw left", yawRight = "Yaw right",
    strafeLeft = "Strafe left", strafeRight = "Strafe right",
    thrustUp = "Thrust up", thrustDown = "Thrust down",
    throttleFull = "Full throttle", throttleZero = "Cut throttle",
    boost = "Boost", warp = "Frame shift (hold)",
    levelOut = "Toggle auto-level", mouseFlight = "Toggle mouse flight",
    autopilot = "Autopilot to target",
    fire = "Fire", missile = "Missile", target = "Next target",
    nextTarget = "Next hostile", scan = "Scan target",
    landingGear = "Landing gear", view = "Change view",
    dock = "Dock / enter", disembark = "Disembark / board",
    map = "Galaxy map", missions = "Logbook", colony = "Colonies",
    ship = "Ship info", settings = "Settings", pause = "Pause",
    help = "Controls", interact = "Interact", jump = "Jump", run = "Run",
}

-- ---------------------------------------------------------------------------

--- Copies the defaults, overlaid with anything the player has rebound.
function input.buildControls()
    local controls = {}
    for action, sources in pairs(input.defaults) do
        local list = {}
        for i, src in ipairs(sources) do list[i] = src end
        controls[action] = list
    end
    for action, sources in pairs(settings.bindings or {}) do
        if controls[action] and type(sources) == "table" and #sources > 0 then
            controls[action] = sources
        end
    end
    return controls
end

--- (Re)creates the baton player.  Called at startup, after rebinding, and
--- whenever a gamepad is plugged in or pulled out.
function input.rebuild()
    local joystick
    if love and love.joystick then
        local sticks = love.joystick.getJoysticks()
        for _, j in ipairs(sticks) do
            if j:isGamepad() then joystick = j break end
        end
    end
    input.player = baton.new({
        controls = input.buildControls(),
        pairs = {
            -- analogue pairs come back deadzoned and length-clamped
            attitude = { "pitchDown", "pitchUp", "rollLeft", "rollRight" },
            translate = { "strafeLeft", "strafeRight", "thrustDown", "thrustUp" },
        },
        joystick = joystick,
        deadzone = 0.22,
        squareDeadzone = false,
    })
    input.joystick = joystick
    return input.player
end

function input.update()
    if not input.player then input.rebuild() end
    input.player:update()
end

function input.down(action)
    return input.player and input.player:down(action) or false
end

function input.pressed(action)
    return input.player and input.player:pressed(action) or false
end

--- Analogue value 0..1 for an action (1 for a held key).
function input.get(action)
    return input.player and input.player:get(action) or 0
end

--- Signed axis from a pair of opposing actions.
function input.axis(negative, positive)
    return input.get(positive) - input.get(negative)
end

function input.pair(name)
    if not input.player then return 0, 0 end
    return input.player:get(name)
end

--- True when `key` is bound to `action` -- used by the state machine, which
--- reacts to LOVE's keypressed rather than polling.
function input.is(action, key)
    if not key then return false end
    local controls = input.controls or input.buildControls()
    input.controls = controls
    local sources = controls[action]
    if not sources then return false end
    for _, src in ipairs(sources) do
        if src == "key:" .. key or src == "sc:" .. key then return true end
    end
    return false
end

--- What to print in the UI for an action, e.g. "W" or "LSHIFT".
function input.keyName(action)
    local controls = input.controls or input.buildControls()
    input.controls = controls
    local sources = controls[action]
    if not sources or #sources == 0 then return "--" end
    for _, src in ipairs(sources) do
        local key = src:match("^key:(.+)$") or src:match("^sc:(.+)$")
        if key then return key:upper() end
    end
    return (sources[1]:gsub("^%a+:", "")):upper()
end

--- All bindings for an action, formatted for the settings screen.
function input.bindingList(action)
    local controls = input.controls or input.buildControls()
    input.controls = controls
    local out = {}
    for _, src in ipairs(controls[action] or {}) do
        out[#out + 1] = (src:gsub("^key:", ""):gsub("^sc:", "")
                            :gsub("^mouse:", "MOUSE "):gsub("^button:", "PAD ")
                            :gsub("^axis:", "AXIS ")):upper()
    end
    return table.concat(out, "  ")
end

--- Rebinds an action to a single key, keeping its gamepad sources.
function input.rebind(action, key)
    local controls = input.buildControls()
    local kept = {}
    for _, src in ipairs(controls[action] or {}) do
        if not (src:match("^key:") or src:match("^sc:") or src:match("^mouse:")) then
            kept[#kept + 1] = src
        end
    end
    table.insert(kept, 1, "key:" .. key)
    settings.bindings = settings.bindings or {}
    settings.bindings[action] = kept
    input.controls = nil
    input.rebuild()
    return true
end

function input.resetBindings()
    settings.bindings = nil
    input.controls = nil
    input.rebuild()
end

function input.load()
    input.controls = nil
    input.rebuild()
end

return input

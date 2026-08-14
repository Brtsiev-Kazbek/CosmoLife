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
-- The scheme is deliberately small.  Everything a player needs is on twelve
-- keys plus the mouse (`input.CORE`); the rest still works, still rebinds, and
-- is kept out of every help panel (`input.ADVANCED`).  Three things make that
-- possible: one context key that does whatever the situation calls for, one
-- panel key instead of five screen keys, and automation for the toggles that
-- used to be chores -- gear, scanning, shield cells.
input.defaults = {
    -- ---- core: flight ----
    throttleUp   = { "key:w", "axis:lefty-" },
    throttleDown = { "key:s", "axis:lefty+" },
    rollLeft     = { "key:a", "axis:leftx-" },
    rollRight    = { "key:d", "axis:leftx+" },
    boost        = { "key:lshift", "key:rshift", "button:leftstick" },
    warp         = { "key:space", "key:lctrl", "key:rctrl", "button:x" },
    autopilot    = { "key:f", "button:dpup" },

    -- ---- core: combat ----
    fire         = { "mouse:1", "axis:triggerright" },
    missile      = { "mouse:2", "button:b" },
    target       = { "key:t", "button:dpright" },

    -- ---- core: everything else ----
    -- one key for docking, landing, boarding, entering, scooping and mining;
    -- what it does is whatever the HUD says it will do (see src/sim/context)
    interact     = { "key:e", "key:return", "button:a" },
    panel        = { "key:tab", "button:back" },
    utility      = { "key:q", "button:y" },
    view         = { "key:v", "button:rightstick" },
    jump         = { "key:space", "button:a" },
    run          = { "key:lshift", "button:leftstick" },

    -- ---- advanced: attitude and translation ----
    pitchUp      = { "key:k", "axis:righty+" },
    pitchDown    = { "key:i", "axis:righty-" },
    yawLeft      = { "key:j", "axis:triggerleft" },
    yawRight     = { "key:l", "axis:triggerright" },
    strafeLeft   = { "key:left", "button:leftshoulder" },
    strafeRight  = { "key:right", "button:rightshoulder" },
    thrustUp     = { "key:pageup" },
    thrustDown   = { "key:pagedown" },
    throttleFull = { "key:z" },
    throttleZero = { "key:x" },
    levelOut     = { "key:h" },
    mouseFlight  = { "key:backspace" },

    -- ---- advanced: systems with an automatic path ----
    scan         = { "key:b", "button:dpleft" },
    shieldCell   = { "key:4" },
    landingGear  = { "key:g", "button:dpdown" },
    nextTarget   = { "key:y" },
    dock         = { "key:return", "button:start" },
    disembark    = { "key:u" },

    -- ---- advanced: direct screen shortcuts (all of these are panel tabs) ----
    map          = { "key:m" },
    missions     = { "key:n" },
    colony       = { "key:c" },
    ship         = { "key:o" },
    settings     = { "key:f10" },

    -- on foot
    --
    -- Walking is bound by *scancode*, not by key.  `love.keyboard.isDown("w")`
    -- goes through the active keyboard layout, so with a Cyrillic layout
    -- selected the W key does not report as "w" and the player simply cannot
    -- move.  Scancodes are physical positions and do not care about the
    -- layout, which is what every shooter uses for movement.
    walkForward  = { "sc:w", "sc:up", "axis:lefty-" },
    walkBack     = { "sc:s", "sc:down", "axis:lefty+" },
    walkLeft     = { "sc:a", "sc:left", "axis:leftx-" },
    walkRight    = { "sc:d", "sc:right", "axis:leftx+" },

    -- meta
    pause        = { "key:escape", "button:start" },
    help         = { "key:f1" },
    save         = { "key:f5" },
    load         = { "key:f9" },
}

--- The twelve keys the game is actually played on.
--
-- Help panels, the tutorial and the title screen are all built from this list
-- and nothing else, so the scheme cannot quietly grow back into the thirty-odd
-- bindings it used to be. Anything not in here is reachable, rebindable and
-- deliberately out of sight.
input.CORE = {
    "throttleUp", "throttleDown", "rollLeft", "rollRight",
    "boost", "warp", "autopilot",
    "fire", "missile", "target",
    "interact", "panel", "utility", "view",
    "walkForward", "walkBack", "walkLeft", "walkRight", "run", "jump",
    "pause", "help",
}

input.isCore = {}
for _, a in ipairs(input.CORE) do input.isCore[a] = true end

--- Human readable order and labels for the rebinding screen.
input.actionOrder = {
    { "Basics", { "throttleUp", "throttleDown", "rollLeft", "rollRight",
                  "boost", "warp", "autopilot", "fire", "missile", "target",
                  "interact", "panel", "utility", "view" } },
    { "On foot", { "walkForward", "walkBack", "walkLeft", "walkRight",
                   "run", "jump" } },
    { "Advanced flight", { "pitchUp", "pitchDown", "yawLeft", "yawRight",
                  "strafeLeft", "strafeRight", "thrustUp", "thrustDown",
                  "throttleFull", "throttleZero", "levelOut", "mouseFlight" } },
    { "Advanced systems", { "landingGear", "scan", "shieldCell", "nextTarget",
                  "dock", "disembark" } },
    { "Screens", { "map", "missions", "colony", "ship", "settings", "pause",
                   "help", "save", "load" } },
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
    shieldCell = "Shield cell",
    landingGear = "Landing gear", view = "Change view",
    dock = "Dock / enter", disembark = "Disembark / board",
    map = "Galaxy map", missions = "Logbook", colony = "Colonies",
    ship = "Ship info", settings = "Settings", pause = "Pause",
    help = "Controls", interact = "Action", jump = "Jump", run = "Run",
    walkForward = "Walk forward", walkBack = "Walk back",
    walkLeft = "Step left", walkRight = "Step right",
    walk = "Move", look = "Look",
    panel = "Commander panel", utility = "Utility wheel (hold)",
    save = "Quick save", load = "Quick load",
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

-- Mouse buttons have names, not numbers.  Printing "1" next to "Fire" was
-- read as the 1 key, which is bound to nothing.
local MOUSE_NAME = { ["1"] = "LMB", ["2"] = "RMB", ["3"] = "MMB" }

--- What to print in the UI for an action, e.g. "W", "LSHIFT" or "LMB".
function input.keyName(action)
    local controls = input.controls or input.buildControls()
    input.controls = controls
    local sources = controls[action]
    if not sources or #sources == 0 then return "--" end
    for _, src in ipairs(sources) do
        local key = src:match("^key:(.+)$") or src:match("^sc:(.+)$")
        if key then return key:upper() end
    end
    for _, src in ipairs(sources) do
        local button = src:match("^mouse:(%d+)$")
        if button then return MOUSE_NAME[button] or ("MOUSE " .. button) end
    end
    return (sources[1]:gsub("^%a+:", "")):upper()
end

--- All bindings for an action, formatted for the settings screen.
function input.bindingList(action)
    local controls = input.controls or input.buildControls()
    input.controls = controls
    local out = {}
    for _, src in ipairs(controls[action] or {}) do
        local button = src:match("^mouse:(%d+)$")
        if button then
            out[#out + 1] = MOUSE_NAME[button] or ("MOUSE " .. button)
        else
            out[#out + 1] = (src:gsub("^key:", ""):gsub("^sc:", "")
                                :gsub("^button:", "PAD "):gsub("^axis:", "AXIS ")):upper()
        end
    end
    return table.concat(out, "  ")
end

--- Control rows for a help panel: { label, keys } built from the live
--- bindings.
--
-- Every help list in the game used to be a hand-written table, and they drifted
-- apart from the actual bindings -- the title screen still advertised a scheme
-- that had been replaced entirely. Generating them from `defaults` plus the
-- player's rebinds means a help panel cannot be wrong.
--
-- `spec` is a list of either an action name, or `{ "actionA", "actionB" }` to
-- print two opposing actions on one row ("Throttle   W / S").
function input.controlRows(spec)
    local rows = {}
    for _, entry in ipairs(spec) do
        if type(entry) == "table" then
            local keys = {}
            for _, action in ipairs(entry) do keys[#keys + 1] = input.keyName(action) end
            -- the label of a pair comes from a caption on the entry, falling
            -- back to the first action's own label
            rows[#rows + 1] = {
                entry.label or input.labels[entry[1]] or entry[1],
                table.concat(keys, " / "),
            }
        else
            rows[#rows + 1] = { input.labels[entry] or entry, input.keyName(entry) }
        end
    end
    return rows
end

--- The rows shown on the title screen and by F1 in flight.
--
-- Core only.  The old list was twenty-eight rows -- longer than the screen and
-- longer than anyone reads -- because it listed every binding that existed
-- rather than the ones the game is played on.
input.flightHelp = {
    { "throttleUp", "throttleDown", label = "Throttle" },
    { "rollLeft", "rollRight", label = "Roll" },
    "boost", "warp", "autopilot",
    "fire", "missile", "target",
    "interact", "panel", "utility", "view", "help",
}

--- The rows shown by F1 on foot.
input.footHelp = {
    { "walkForward", "walkBack", label = "Move" },
    { "walkLeft", "walkRight", label = "Step" },
    "run", "jump", "interact", "panel", "help",
}

--- Everything the core list leaves out, for the "advanced" help page.
input.advancedHelp = {
    { "pitchDown", "pitchUp", label = "Pitch" },
    { "yawLeft", "yawRight", label = "Yaw" },
    { "strafeLeft", "strafeRight", label = "Strafe" },
    { "thrustUp", "thrustDown", label = "Thrust" },
    { "throttleFull", "throttleZero", label = "Full / cut throttle" },
    "levelOut", "mouseFlight", "landingGear", "scan", "shieldCell",
    "nextTarget", "map", "missions", "colony", "ship", "settings",
    "save", "load",
}

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

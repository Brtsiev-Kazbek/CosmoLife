-- Contextual control hints in the corner of the screen.
--
-- The point is not to list every key -- F1 already does that. It is to show
-- the handful that matter *right now*, so a new pilot never has to stop and
-- open a menu to find out how to land or how to get out of the ship. Hints are
-- therefore built from live state: the dock prompt only appears when there is
-- something to dock with, the autopilot hint only when a target is selected.
--
-- Bindings are read from `input`, so a rebound key shows its new name here
-- without anything else changing.

local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local input = require("src.input")
local i18n = require("src.i18n")

local hints = {}
local C = palette.colors
local L = i18n.translate

--- Builds the flight hint list for the current situation.
-- `ctx` is the same table the HUD is given.
function hints.flight(ctx)
    local list = {}
    local function add(keys, label, highlight)
        list[#list + 1] = { keys = keys, label = L(label), highlight = highlight }
    end

    -- always relevant
    add("MOUSE", "Aim")
    add(input.keyName("throttleUp") .. "/" .. input.keyName("throttleDown"), "Throttle")
    add(input.keyName("rollLeft") .. "/" .. input.keyName("rollRight"), "Roll")

    if ctx.hoverMode then
        -- landing: translation is what matters, not attitude
        add(input.keyName("strafeLeft") .. "/" .. input.keyName("strafeRight"), "Strafe", true)
        add(input.keyName("thrustUp") .. "/" .. input.keyName("thrustDown"), "Thrust", true)
    else
        add(input.keyName("fire"), "Fire")
        add(input.keyName("target"), "Target")
    end

    -- situational
    if ctx.target and not ctx.hoverMode then
        add(input.keyName("autopilot"), "Autopilot to target", ctx.autopilot)
    end
    if not ctx.hoverMode and not ctx.landed then
        add(input.keyName("warp"), "Cruise", ctx.warpState == "cruise")
    end
    add(input.keyName("landingGear"), "Gear", ctx.gearDown)
    if ctx.dockPrompt then
        add(input.keyName("dock"), ctx.dockPromptIsPlace and "Enter" or "Dock", true)
    end
    if ctx.landed then
        add(input.keyName("disembark"), "Disembark", true)
    end
    add(input.keyName("map") .. "/" .. input.keyName("missions"), "Map")
    add("F1", "more")
    return list
end

function hints.onFoot(ctx)
    local list = {}
    local function add(keys, label, highlight)
        list[#list + 1] = { keys = keys, label = L(label), highlight = highlight }
    end
    add("WASD", "Move")
    add("MOUSE", "Look")
    add(input.keyName("run"), "Run")
    add(input.keyName("jump"), "Jump")
    if ctx.canInteract then add(input.keyName("interact"), "Interact", true) end
    if ctx.canBoard then add(input.keyName("disembark"), "Board", true) end
    add(input.keyName("colony"), "Colonies")
    add("F1", "more")
    return list
end

--- Draws a hint list in the bottom-left corner, above the gauges.
function hints.draw(list, x, y, maxLines)
    if not list or #list == 0 then return end
    local font = ui.font("small")
    local lineH = font:getHeight() + 3
    maxLines = maxLines or #list

    -- widest key column, so labels line up
    local keyW = 0
    for i = 1, math.min(#list, maxLines) do
        keyW = math.max(keyW, font:getWidth(list[i].keys))
    end

    local n = math.min(#list, maxLines)
    local h = n * lineH + 10
    local w = keyW + 14 + 108

    love.graphics.setColor(0, 0, 0, 0.42)
    love.graphics.rectangle("fill", x - 6, y - 5, w, h)
    ui.setColor(C.uiLine, 0.25)
    love.graphics.setLineWidth(1)
    love.graphics.line(x - 6, y - 5, x - 6, y - 5 + h)

    for i = 1, n do
        local hint = list[i]
        local yy = y + (i - 1) * lineH
        ui.text(hint.keys, x, yy, hint.highlight and C.uiWarn or C.uiPrimary, "small")
        ui.text(hint.label, x + keyW + 12, yy, hint.highlight and C.uiText or C.uiDim, "small")
    end
    love.graphics.setColor(1, 1, 1, 1)
end

return hints

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
        -- Landing: translation is what matters, not attitude -- and it is on
        -- the core keys, because roll, cruise and boost have nothing to do
        -- this close to the ground.
        add(input.keyName("rollLeft") .. "/" .. input.keyName("rollRight"), "Strafe", true)
        add(input.keyName("warp") .. "/" .. input.keyName("boost"), "Thrust", true)
    else
        add(input.keyName("fire"), "Fire")
        add(input.keyName("target"), "Target")
    end

    -- situational
    -- the autopilot line used to sit behind `ctx.target`, which before the
    -- targeting clamp was lifted could never be set at travel range
    if ctx.target and not ctx.hoverMode then
        add(input.keyName("autopilot"), "Autopilot to target", ctx.autopilot)
    end
    if not ctx.hoverMode and not ctx.landed then
        add(input.keyName("warp"), "Cruise", ctx.warpState == "cruise")
    end
    -- The context key: one line, and it names what the key would actually do
    -- rather than listing a key per situation.
    if ctx.contextVerb then
        add(input.keyName("interact"), ctx.contextVerb, true)
    end
    add(input.keyName("panel"), "Panel")
    add(input.keyName("utility"), "Systems")
    add("F1", "more")
    return list
end

function hints.onFoot(ctx)
    local list = {}
    local function add(keys, label, highlight)
        list[#list + 1] = { keys = keys, label = L(label), highlight = highlight }
    end
    add(input.keyName("walkForward") .. input.keyName("walkLeft")
        .. input.keyName("walkBack") .. input.keyName("walkRight"), "Move")
    add("MOUSE", "Look")
    add(input.keyName("run"), "Run")
    add(input.keyName("jump"), "Jump")
    if ctx.contextVerb then add(input.keyName("interact"), ctx.contextVerb, true) end
    add(input.keyName("panel"), "Panel")
    add("F1", "more")
    return list
end

--- Draws a hint list.
--
-- `x, y` is the top-left of the panel unless `opts.anchor` is "bottom", in
-- which case `y` is its *bottom* edge -- which is what a caller pinning the
-- box above the gauges actually knows.
--
-- Both columns are measured. The label column used to be a fixed 108px for
-- text that was never measured, so a longer label ("Автопилот к цели") simply
-- spilled past the background it was drawn on.
function hints.draw(list, x, y, opts)
    if not list or #list == 0 then return end
    opts = opts or {}
    local font = ui.font("small")
    local lineH = font:getHeight() + 3

    local maxLines = opts.maxLines or #list
    local n = math.min(#list, maxLines)
    local h = n * lineH + 10

    local keyW, labelW = 0, 0
    for i = 1, n do
        keyW = math.max(keyW, font:getWidth(list[i].keys))
        labelW = math.max(labelW, font:getWidth(list[i].label))
    end
    local w = keyW + 12 + labelW + 12

    local top = (opts.anchor == "bottom") and (y - h) or y

    love.graphics.setColor(0, 0, 0, 0.42)
    love.graphics.rectangle("fill", x - 6, top - 5, w, h)
    ui.setColor(C.uiLine, 0.25)
    love.graphics.setLineWidth(1)
    love.graphics.line(x - 6, top - 5, x - 6, top - 5 + h)

    for i = 1, n do
        local hint = list[i]
        local yy = top + (i - 1) * lineH
        ui.text(hint.keys, x, yy, hint.highlight and C.uiWarn or C.uiPrimary, "small")
        ui.text(hint.label, x + keyW + 12, yy, hint.highlight and C.uiText or C.uiDim, "small")
    end
    love.graphics.setColor(1, 1, 1, 1)
    return w, h
end

--- How many hint rows fit in `height`.
function hints.rowsFor(height)
    local lineH = ui.font("small"):getHeight() + 3
    return math.max(1, math.floor((height - 10) / lineH))
end

return hints

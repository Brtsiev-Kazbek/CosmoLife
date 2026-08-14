-- The utility wheel.
--
-- Landing gear, auto-level, mouse flight, full and cut throttle, target
-- scanning and the shield cell bank were seven keys for things a pilot touches
-- once in a while. Seven keys is how a control scheme becomes thirty. They
-- live here instead: hold one key, the wheel appears, point at what you want,
-- release.
--
-- Everything on it is still individually bindable for anyone who wants a
-- dedicated key -- the wheel is the discoverable path, not the only one.

local class = require("src.lib.class")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local hud = require("src.render.hud")
local i18n = require("src.i18n")

local Wheel = class("WheelState")

local C = palette.colors
local L = i18n.format
local cos, sin, atan2, pi = math.cos, math.sin, (math.atan2 or math.atan), math.pi
local TAU = pi * 2

--- Each slot: a label, a live state string, and what it does.
--
-- `state(f)` is what makes the wheel readable at a glance: a toggle shows
-- which way it is currently set, so the player never has to press it to find
-- out.
local SLOTS = {
    {
        id = "gear", label = "Landing gear",
        state = function(f) return f.gearDown and L("down") or L("up") end,
        run = function(f)
            f.gearDown = not f.gearDown
            hud.message(f.gearDown and L("Landing gear down") or L("Landing gear up"), "info")
        end,
    },
    {
        id = "scan", label = "Scan target",
        state = function(f) return f.target and f.target.name or L("no target") end,
        run = function(f) f:scanTarget() end,
    },
    {
        id = "shieldCell", label = "Shield cell",
        state = function(f) return tostring(f.player.shieldCells or 0) end,
        run = function(f) f:useShieldCell() end,
    },
    {
        id = "level", label = "Auto-level",
        state = function(f) return f.autoLevel and L("on") or L("off") end,
        run = function(f)
            f.autoLevel = not f.autoLevel
            hud.message(f.autoLevel and L("Auto-level on") or L("Auto-level off"), "info")
        end,
    },
    {
        id = "mouseFlight", label = "Mouse flight",
        state = function(f) return f.mouseSteer and L("on") or L("off") end,
        run = function(f)
            f:setMouseFlight(not f.mouseSteer)
            hud.message(f.mouseSteer and L("Mouse flight on") or L("Mouse flight off"), "info")
        end,
    },
    {
        id = "throttleFull", label = "Full throttle",
        state = function(f) return string.format("%d%%", math.floor((f.throttle or 0) * 100)) end,
        run = function(f) f.throttle = 1 end,
    },
    {
        id = "throttleZero", label = "Cut throttle",
        state = function(f) return string.format("%d%%", math.floor((f.throttle or 0) * 100)) end,
        run = function(f) f.throttle = 0 end,
    },
    {
        id = "save", label = "Save game",
        state = function() return "" end,
        run = function(f)
            local ok, err = f.game:saveGame()
            hud.message(ok and L("Game saved") or L("Save failed: {reason}", { reason = tostring(err) }),
                ok and "good" or "alert")
        end,
    },
}

Wheel.SLOTS = SLOTS

function Wheel:init()
    self.drawUnderlying = true
end

function Wheel:enter(flight, heldKey)
    self.flight = flight
    self.heldKey = heldKey
    self.selected = nil
    self.dx, self.dy = 0, 0
    love.mouse.setRelativeMode(true)
end

function Wheel:exit()
    love.mouse.setRelativeMode(false)
end

--- Which slot the pointer is over, or nil when it is near the centre.
--
-- A dead zone in the middle means letting go without having pointed anywhere
-- cancels, which is the behaviour every wheel in every game has and the reason
-- they are safe to open by accident.
function Wheel:pick()
    local r = math.sqrt(self.dx * self.dx + self.dy * self.dy)
    if r < 34 then return nil end
    local a = atan2(self.dx, -self.dy) % TAU
    local step = TAU / #SLOTS
    return math.floor((a + step * 0.5) / step) % #SLOTS + 1
end

function Wheel:mousemoved(x, y, dx, dy)
    -- clamped so the pointer cannot run off into a corner and stick there
    local lim = 150
    self.dx = math.max(-lim, math.min(lim, self.dx + dx))
    self.dy = math.max(-lim, math.min(lim, self.dy + dy))
    self.selected = self:pick()
end

function Wheel:choose()
    local slot = SLOTS[self.selected or 0]
    self.manager:pop()
    if slot then slot.run(self.flight) end
end

function Wheel:keyreleased(key)
    -- releasing the key that opened it commits: hold, point, release
    if key == self.heldKey then self:choose() end
end

function Wheel:keypressed(key)
    if config.is("pause", key) then self.manager:pop() return end
    -- number keys pick a slot outright, for anyone who would rather not aim
    local n = tonumber(key)
    if n and SLOTS[n] then self.selected = n self:choose() end
end

function Wheel:mousepressed() self:choose() end

function Wheel:update(dt) end

function Wheel:draw(background)
    if background then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local cx, cy = w * 0.5, h * 0.5
    local s = ui.scale or 1
    local radius = math.min(w, h) * 0.26

    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", 0, 0, w, h)

    local step = TAU / #SLOTS
    for i, slot in ipairs(SLOTS) do
        local a = (i - 1) * step
        local x = cx + sin(a) * radius
        local y = cy - cos(a) * radius
        local on = (i == self.selected)

        local bw, bh = 168 * s, 40 * s
        love.graphics.setColor(0.05, 0.06, 0.09, on and 0.96 or 0.80)
        love.graphics.rectangle("fill", x - bw * 0.5, y - bh * 0.5, bw, bh)
        ui.setColor(on and C.uiPrimary or C.uiDim, on and 0.9 or 0.35)
        love.graphics.rectangle("line", x - bw * 0.5, y - bh * 0.5, bw, bh)
        love.graphics.setColor(1, 1, 1, 1)

        ui.textCenter(L(slot.label), x, y - 13 * s, on and C.uiPrimary or C.uiText, "small")
        local st = slot.state(self.flight)
        if st and st ~= "" then
            ui.textCenter(st, x, y + 2 * s, C.uiDim, "small")
        end
    end

    -- the pointer
    ui.setColor(C.uiPrimary, 0.9)
    love.graphics.setLineWidth(2 * s)
    love.graphics.line(cx, cy, cx + self.dx, cy + self.dy)
    love.graphics.circle("line", cx, cy, 34)
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)

    ui.textCenter(L("Release to choose"), cx, cy + radius + 44 * s, C.uiDim, "small")
end

return Wheel

-- The commander panel.
--
-- The galaxy map, the logbook, the ship and the colony office were four
-- separate keys (M, N, O, C) that a player had to know about before they could
-- find any of them. They are the same thing -- "look at my situation" -- so
-- they are one key now, and this state hosts them as tabs.
--
-- It hosts rather than replaces: each tab is the existing state, entered with
-- the arguments it already expects, with its update, draw and input forwarded.
-- That keeps every screen exactly as it was, keeps the direct shortcuts
-- working for anybody who has them in their fingers, and means a screen that
-- pushes something on top of itself -- the map starting a jump, the colony
-- office opening a market -- still works, because the child holds the real
-- state manager.

local class = require("src.lib.class")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local i18n = require("src.i18n")

local Panel = class("PanelState")

local C = palette.colors
local L = i18n.format

local TABS = {
    -- The first page answers "what is my situation", which is the question a
    -- player has when they open this. It used to open onto the galaxy map,
    -- which answers "where could I go" before anybody asked.
    { id = "summary",  label = "Overview", action = nil,
      make = function() return require("src.states.summary").new() end,
      args = function(p) return p.flight end },
    { id = "map",      label = "Galaxy map", action = "map",
      make = function() return require("src.states.galaxymap").new() end,
      args = function(p) return p.flight end },
    { id = "missions", label = "Logbook", action = "missions",
      make = function() return require("src.states.logbook").new() end,
      args = function(p) return p.flight end },
    { id = "ship",     label = "Ship info", action = "ship",
      make = function() return require("src.states.shipinfo").new() end,
      args = function() return nil end },
    { id = "colony",   label = "Colonies", action = "colony",
      make = function() return require("src.states.colonies").new() end,
      args = function(p)
          local f = p.flight
          return f, (f and f.landedOn) and f.surface or nil, f and f.local_ or nil
      end },
}

Panel.TABS = TABS

-- The tab the player was last on, so re-opening the panel goes where they
-- left it rather than always back to the first page.
local lastTab = 1

function Panel:init()
    self.drawUnderlying = false
end

function Panel:enter(flight, tabId)
    self.flight = flight
    local index = lastTab
    if tabId then
        for i, t in ipairs(TABS) do if t.id == tabId then index = i end end
    end
    self:select(index)
end

function Panel:exit()
    if self.child and self.child.exit then self.child:exit() end
    self.child = nil
end

--- Swaps the hosted screen.
function Panel:select(index)
    index = ((index - 1) % #TABS) + 1
    if self.child and self.child.exit then self.child:exit() end
    lastTab = index
    self.tab = index
    local spec = TABS[index]
    local child = spec.make()
    child.game = self.game
    -- the child gets the *real* manager, so anything it pushes lands on the
    -- stack above this panel and draws over it as usual
    child.manager = self.manager
    self.child = child
    if child.enter then child:enter(spec.args(self)) end
end

-- ---------------------------------------------------------------------------

function Panel:update(dt, background)
    if self.child and self.child.update then self.child:update(dt, background) end
end

function Panel:pause() if self.child and self.child.pause then self.child:pause() end end
function Panel:resume() if self.child and self.child.resume then self.child:resume() end end

function Panel:keypressed(key)
    -- the panel key cycles tabs; that is the whole navigation model
    if config.is("panel", key) then
        self:select(self.tab + 1)
        return
    end
    for i, t in ipairs(TABS) do
        if t.action and config.is(t.action, key) then self:select(i) return end
    end
    if self.child and self.child.keypressed then self.child:keypressed(key) end
end

local FORWARD = { "keyreleased", "textinput", "mousepressed", "mousereleased",
                  "mousemoved", "wheelmoved", "resize" }
for _, name in ipairs(FORWARD) do
    Panel[name] = function(self, ...)
        if self.child and self.child[name] then return self.child[name](self.child, ...) end
    end
end

-- ---------------------------------------------------------------------------

function Panel:draw(background)
    if self.child and self.child.draw then self.child:draw(background) end
    if background then return end
    self:drawTabs()
end

--- A strip along the top naming the tabs and the key that cycles them.
function Panel:drawTabs()
    local w = love.graphics.getWidth()
    local s = ui.scale or 1
    local h = 26 * s
    local pad = 14 * s

    love.graphics.setColor(0.04, 0.05, 0.08, 0.88)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(C.uiPrimary[1], C.uiPrimary[2], C.uiPrimary[3], 0.35)
    love.graphics.rectangle("fill", 0, h - 1 * s, w, 1 * s)
    love.graphics.setColor(1, 1, 1, 1)

    local x = pad
    for i, t in ipairs(TABS) do
        local label = L(t.label)
        local wide = ui.font("small"):getWidth(label) + pad
        if i == self.tab then
            love.graphics.setColor(C.uiPrimary[1], C.uiPrimary[2], C.uiPrimary[3], 0.20)
            love.graphics.rectangle("fill", x - pad * 0.5, 0, wide, h)
            love.graphics.setColor(1, 1, 1, 1)
        end
        ui.text(label, x, (h - 12 * s) * 0.5, i == self.tab and C.uiPrimary or C.uiDim, "small")
        x = x + wide
    end

    local hint = L("{key} switches  -  ESC closes", { key = config.keyName("panel") })
    ui.textRight(hint, w - pad, (h - 12 * s) * 0.5, C.uiDim, "small")
end

return Panel

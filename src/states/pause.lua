-- Pause overlay: save, load, settings, quit to title.

local class = require("src.lib.class")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local hud = require("src.render.hud")
local i18n = require("src.i18n")

local Pause = class("PauseState")

local C = palette.colors
local L = i18n.format

function Pause:init()
    self.drawUnderlying = true
end

function Pause:enter(caller)
    self.caller = caller
    self.world = self.game.world
    self:rebuild()
end

function Pause:rebuild()
    local r = self.game.renderer
    local items = {
        { label = L("Resume"), action = function() self.manager:pop() end },
        { label = L("Save game"), action = function()
            local ok, err = self.game:saveGame()
            self.status = ok and L("Saved.")
                or L("Save failed: {reason}", { reason = tostring(err) })
        end },
        { label = L("Load game"), action = function()
            local ok, err = self.game:loadGame()
            if ok then
                local Flight = require("src.states.flight")
                self.manager:switch(Flight.new())
            else
                self.status = L("Load failed: {reason}", { reason = tostring(err) })
            end
        end },
        { label = L("CRT filter"), value = r.settings.post and L("on") or L("off"), action = function()
            r.settings.post = not r.settings.post
            self:rebuild()
        end },
        { label = L("Light bands"), value = r.env.bands > 0 and tostring(r.env.bands) or L("smooth"), action = function()
            r.env.bands = (r.env.bands + 1) % 9
            self:rebuild()
        end },
        { label = L("Wireframe"), value = r.settings.wireframe and L("on") or L("off"), action = function()
            r.settings.wireframe = not r.settings.wireframe
            self:rebuild()
        end },
        { label = L("Quit to title"), action = function()
            local Menu = require("src.states.menu")
            hud.clear()
            self.manager:switch(Menu.new())
        end },
        { label = L("Quit to desktop"), action = function() love.event.quit() end },
    }
    local cursor = self.menu and self.menu.cursor or 1
    self.menu = ui.menu(items, { visible = #items, cursor = cursor })
end

function Pause:keypressed(key)
    if config.is("pause", key) then self.manager:pop() return end
    if self.menu then self.menu:keypressed(key) end
end

function Pause:update(dt)
    -- the world holds its breath while paused
end

function Pause:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(1, 1, 1, 1)

    -- sized to the items rather than a constant: eight rows of 28 from py+84
    -- reached py+308, and the status line was printed at py+306, on top of
    -- the last one
    local rows = self.menu and #self.menu.items or 8
    local pw = 380
    local ph = 84 + rows * 28 + 52
    local px, py = (w - pw) * 0.5, (h - ph) * 0.5
    ui.panel(px, py, pw, ph, L("PAUSED"))
    ui.text("COSMOLIFE", px + 28, py + 22, C.uiPrimary, "large")
    if self.world then
        ui.text(self.world.player.name .. "  -  " .. self.world:dateString(), px + 28, py + 52, C.uiDim, "small")
    end
    if self.menu then self.menu:draw(px + 44, py + 84, pw - 88, 28, "normal") end
    if self.status then
        ui.textCenter(self.status, px + pw * 0.5, py + ph - 30, C.uiPrimary, "small")
    end
end

return Pause

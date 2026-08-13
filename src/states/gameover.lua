-- Death.
--
-- Losing the ship is not the end of the save: insurance rebuilds the hull at
-- the last port for a share of its value, which keeps the long game (colonies,
-- reputation, a mapped region of the galaxy) intact while still making a bad
-- fight expensive.

local class = require("src.lib.class")
local util = require("src.lib.util")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local hud = require("src.render.hud")
local i18n = require("src.i18n")

local GameOver = class("GameOverState")

local C = palette.colors
local L = i18n.format
local floor = math.floor

function GameOver:init() self.drawUnderlying = true end

function GameOver:enter(reason, flight)
    self.reason = reason or L("destroyed")
    self.flight = flight
    self.world = self.game.world
    self.player = self.world.player
    self.timer = 0

    -- insurance: pay the excess, keep the ship class
    self.excess = floor(self.player.shipDef.stats.price * 0.12)
    self.canAfford = self.player.credits >= self.excess

    local items = {}
    items[#items + 1] = {
        label = self.canAfford
            and L("Claim insurance  -  {cash} cr excess", { cash = util.money(self.excess) })
            or L("Insurance excess: {cash} cr (cannot pay)", { cash = util.money(self.excess) }),
        disabled = not self.canAfford,
        action = function() self:respawn(false) end,
    }
    items[#items + 1] = {
        label = L("Declare bankruptcy  -  keep a basic hull, lose your cargo"),
        action = function() self:respawn(true) end,
    }
    items[#items + 1] = {
        label = L("Quit to title"),
        action = function()
            local Menu = require("src.states.menu")
            hud.clear()
            self.manager:switch(Menu.new())
        end,
    }
    self.menu = ui.menu(items, { visible = 4 })
end

function GameOver:respawn(bankrupt)
    local player = self.player
    if bankrupt then
        local ships = require("src.procgen.ships")
        player:setShip(ships.generate(player.seed, "shuttle"), false)
        player.cargo = {}
        player.credits = math.max(player.credits, 600)
    else
        player:spend(self.excess)
        player.cargo = {}
    end
    player.hull = player.stats.maxHull
    player.shield = player.stats.maxShield
    player.fuel = player.stats.fuel
    player:addLog(L("Ship lost: {reason}. Rebuilt under insurance.", { reason = self.reason }),
        self.world.day, "alert")
    self.world:addNews(L("Insurance claim filed by {name}.", { name = player.name }), "alert")

    -- back into space at the system we were in
    local Flight = require("src.states.flight")
    self.manager:switch(Flight.new())
end

function GameOver:update(dt)
    self.timer = self.timer + dt
end

function GameOver:keypressed(key)
    if self.timer < 1.2 then return end
    if self.menu then self.menu:keypressed(key) end
end

function GameOver:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local fade = math.min(self.timer / 1.6, 1)
    love.graphics.setColor(0, 0, 0, fade * 0.85)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(1, 1, 1, 1)

    if fade < 0.4 then return end

    ui.textCenter(L("SHIP DESTROYED"), w * 0.5, h * 0.32, C.uiDanger, "huge")
    ui.textCenter(self.reason, w * 0.5, h * 0.32 + 52, C.uiDim, "normal")

    local r = self.player.record
    ui.textCenter(L("{j} {j:jump}  -  {k} {k:kill}  -  {c} {c:contract}  -  {cash} cr", {
        j = r.jumps, k = r.kills, c = r.missionsDone, cash = util.money(self.player.credits),
    }), w * 0.5, h * 0.32 + 82, C.uiText, "small")

    if self.timer > 1.2 and self.menu then
        self.menu:draw(w * 0.5 - 260, h * 0.55, 520, 30, "normal")
    end
end

return GameOver

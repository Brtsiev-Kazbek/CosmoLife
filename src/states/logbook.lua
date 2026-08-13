-- Mission log, commander record and galactic news, on three tabs.

local class = require("src.lib.class")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local missionsMod = require("src.sim.missions")
local factions = require("src.sim.factions")
local i18n = require("src.i18n")

local Logbook = class("LogbookState")

local C = palette.colors
local L = i18n.format
local floor = math.floor

function Logbook:init() self.drawUnderlying = false end

function Logbook:enter(flight)
    self.flight = flight
    self.world = self.game.world
    self.player = self.world.player
    self.tab = 1
    self.tabs = { "CONTRACTS", "RECORD", "NEWS" }
    self.scroll = 0
end

function Logbook:keypressed(key)
    if config.is("missions", key) or config.is("pause", key) then
        self.manager:pop()
        return
    end
    if key == "left" or key == "q" then self.tab = ((self.tab - 2) % #self.tabs) + 1; self.scroll = 0 end
    if key == "right" or key == "e" then self.tab = (self.tab % #self.tabs) + 1; self.scroll = 0 end
    if key == "down" or key == "s" then self.scroll = self.scroll + 1 end
    if key == "up" or key == "w" then self.scroll = math.max(0, self.scroll - 1) end
end

function Logbook:wheelmoved(x, y)
    self.scroll = math.max(0, self.scroll - y)
end

function Logbook:update(dt) self.world:update(dt) end

function Logbook:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.clear(0.02, 0.025, 0.035, 1)

    ui.text(L("COMMANDER {name}", { name = self.player.name:upper() }), 40, 30, C.uiPrimary, "large")
    ui.textRight(self.world:dateString(), w - 40, 34, C.uiDim, "small")
    ui.textRight(util.money(self.player.credits) .. " " .. L("cr"), w - 40, 54, C.amber, "small")

    local tx = 40
    for i, t in ipairs(self.tabs) do
        local name = L(t)
        local tw = ui.font("small"):getWidth(name) + 26
        if i == self.tab then
            ui.setColor(C.uiPrimary, 0.22)
            love.graphics.rectangle("fill", tx, 74, tw, 24)
        end
        ui.text(name, tx + 13, 78, i == self.tab and C.uiPrimary or C.uiDim, "small")
        tx = tx + tw + 6
    end
    ui.rule(40, 102, w - 80, C.uiLine, 0.4)

    if self.tab == 1 then self:drawContracts(w, h)
    elseif self.tab == 2 then self:drawRecord(w, h)
    else self:drawNews(w, h) end

    ui.rule(40, h - 56, w - 80, C.uiLine, 0.4)
    ui.text(L("Q/E tabs   W/S scroll   {key} or ESC to close", { key = config.keyName("missions") }),
        40, h - 44, C.uiDim, "small")
end

function Logbook:drawContracts(w, h)
    local y = 126
    if #self.player.missions == 0 then
        ui.text(L("No active contracts. Take work at any station's contract board."), 60, y, C.uiDim, "small")
        return
    end
    for i, m in ipairs(self.player.missions) do
        if i > self.scroll then
            if y > h - 110 then break end
            local col = m.illegal and C.magenta or C.uiText
            local overdue = (m.expires - self.world.day) < 2
            ui.text(missionsMod.title(m), 60, y, col, "normal")
            ui.textRight(util.money(m.reward) .. " " .. L("cr"), w - 60, y, C.amber, "normal")
            y = y + 22
            ui.text(missionsMod.status(m, self.world.day), 76, y, overdue and C.uiDanger or C.uiDim, "small")
            ui.textRight(m.employer or "", w - 60, y, C.uiDim, "small")
            y = y + 20
            y = y + ui.paragraph(missionsMod.brief(m), 76, y, w - 200, C.uiDim, "small") + 14
            ui.rule(60, y - 6, w - 120, C.uiLine, 0.2)
        end
    end
end

function Logbook:drawRecord(w, h)
    local r = self.player.record
    local x, y = 60, 130
    local rows = {
        { L("Ship"), L(self.player.shipDef.roleName) .. "  \"" .. self.player.shipDef.name .. "\"" },
        { L("Credits"), util.money(self.player.credits) },
        { L("Systems visited"), tostring(util.count(self.player.knownSystems)) },
        { L("Hyperspace jumps"), tostring(r.jumps) },
        { L("Distance travelled"), string.format("%.1f ly", r.distanceLy) },
        { L("Landings"), tostring(r.landings) },
        { L("Trades"), tostring(r.trades) },
        { L("Trade revenue"), util.money(r.profit) .. " " .. L("cr") },
        { L("Ships destroyed"), tostring(r.kills) },
        { L("Ships lost"), tostring(r.deaths) },
        { L("Contracts completed"), tostring(r.missionsDone) },
        { L("Contracts failed"), tostring(r.missionsFailed) },
        { L("Colonies founded"), tostring(r.coloniesFounded) },
        { L("Bodies scanned"), tostring(r.scanned) },
    }
    for _, row in ipairs(rows) do
        ui.text(row[1], x, y, C.uiDim, "small")
        ui.text(row[2], x + 240, y, C.uiText, "small")
        y = y + 19
    end

    -- standings
    local sx, sy = w * 0.5 + 40, 130
    ui.text(L("STANDINGS"), sx, sy, C.uiPrimary, "small")
    sy = sy + 24
    for _, f in ipairs(factions.list) do
        local rep = self.player:reputation(f.id)
        ui.text(L(f.name), sx, sy, { f.color[1], f.color[2], f.color[3], 1 }, "small")
        ui.text(L(self.player:reputationName(f.id)), sx + 210, sy,
            rep < -0.1 and C.uiDanger or (rep > 0.1 and C.uiPrimary or C.uiDim), "small")
        ui.bar(sx + 320, sy + 3, 110, 8, (rep + 1) * 0.5, rep < 0 and C.uiDanger or C.uiPrimary)
        sy = sy + 20
        local bounty = self.player:bounty(f.id)
        if bounty > 0 then
            ui.text("   " .. L("wanted: {cash} cr", { cash = util.money(bounty) }), sx, sy, C.uiDanger, "small")
            sy = sy + 18
        end
    end

    sy = sy + 14
    ui.text(L("COLONIES"), sx, sy, C.uiPrimary, "small")
    sy = sy + 22
    if #self.player.colonies == 0 then
        ui.text(L("none founded"), sx, sy, C.uiDim, "small")
    else
        local colonyMod = require("src.sim.colony")
        for _, c in ipairs(self.player.colonies) do
            ui.text(c.name, sx, sy, C.uiText, "small")
            ui.text(L("{tier}, pop {pop}", { tier = L(colonyMod.tierName(c.tier)),
                pop = util.money(floor(c.population)) }), sx + 210, sy, C.uiDim, "small")
            sy = sy + 18
        end
    end
end

function Logbook:drawNews(w, h)
    local y = 130
    ui.text(L("GALACTIC NEWS"), 60, y, C.uiPrimary, "small")
    y = y + 26
    if #self.world.news == 0 then
        ui.text(L("The wires are quiet."), 60, y, C.uiDim, "small")
    end
    for i, n in ipairs(self.world.news) do
        if i > self.scroll then
            if y > h - 240 then break end
            local col = C.uiText
            if n.kind == "war" then col = C.uiDanger
            elseif n.kind == "good" then col = C.uiPrimary
            elseif n.kind == "colony" then col = C.cyan
            elseif n.kind == "alert" then col = C.uiWarn end
            ui.text(util.date(n.day), 60, y, C.uiDim, "small")
            y = y + ui.paragraph(n.text, 160, y, w - 260, col, "small")
            y = y + 6
        end
    end

    y = math.max(y + 16, h - 230)
    ui.rule(60, y, w - 120, C.uiLine, 0.3)
    y = y + 10
    ui.text(L("PERSONAL LOG"), 60, y, C.uiPrimary, "small")
    y = y + 22
    for i, l in ipairs(self.player.log) do
        if y > h - 70 then break end
        ui.text(util.date(l.day), 60, y, C.uiDim, "small")
        ui.text(l.text, 160, y, C.uiText, "small")
        y = y + 17
    end
end

return Logbook

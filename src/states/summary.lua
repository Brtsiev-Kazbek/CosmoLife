-- The commander panel's first page: where you stand, right now.
--
-- The panel opened straight onto the galaxy map, which answers "where could I
-- go" before anyone has asked it. The question a player actually has when they
-- open this is "what is my situation" -- how far off the next rank, what have I
-- promised anyone, who likes me, what just happened -- and every one of those
-- answers already existed in the simulation with no screen showing them
-- together.
--
-- It is a digest, not a fifth copy: contracts in full are the logbook's job,
-- the whole reputation table is the logbook's too. This is the page you read
-- in four seconds before deciding which of the other tabs you wanted.

local class = require("src.lib.class")
local util = require("src.lib.util")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local progression = require("src.sim.progression")
local factions = require("src.sim.factions")
local missionsMod = require("src.sim.missions")
local i18n = require("src.i18n")

local Summary = class("SummaryState")

local C = palette.colors
local L = i18n.format

-- The panel's tab strip owns the top of the screen.
local TOP = 58

function Summary:init() self.drawUnderlying = false end

function Summary:enter(flight)
    self.flight = flight
    self.world = self.game.world
    self.player = self.world and self.world.player
end

function Summary:update(dt) end
function Summary:keypressed(key) end

--- Contracts that are still owed, soonest deadline first.
function Summary:contracts()
    local out = {}
    for _, m in ipairs(self.player.missions or {}) do
        if m.state == "active" then out[#out + 1] = m end
    end
    table.sort(out, function(a, b) return (a.expires or 0) < (b.expires or 0) end)
    return out
end

--- Only the factions the player has actually moved, in either direction.
--
-- A list of every faction at Neutral says nothing; the ones worth a line are
-- the ones where something has happened.
function Summary:standings()
    local out = {}
    for id, value in pairs(self.player.reputations or {}) do
        if math.abs(value) > 0.02 then
            out[#out + 1] = { id = id, value = value }
        end
    end
    for id in pairs(self.player.bounties or {}) do
        local found = false
        for _, e in ipairs(out) do if e.id == id then found = true end end
        if not found and (self.player.bounties[id] or 0) > 0 then
            out[#out + 1] = { id = id, value = self.player:reputation(id) }
        end
    end
    table.sort(out, function(a, b) return a.value > b.value end)
    return out
end

function Summary:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local p = self.player
    if not p then return end

    love.graphics.setColor(0, 0, 0, 0.86)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(1, 1, 1, 1)

    local colW = math.floor((w - 140) * 0.5)
    local left, right = 60, 80 + colW

    -- ---- who you are ----------------------------------------------------
    local rank = progression.rank(p)
    ui.text(p.name or L("Commander"), left, TOP, C.uiText, "large")
    ui.text(L(rank.name), left, TOP + 30, C.uiPrimary, "normal")

    local nextRank = progression.next(p)
    if nextRank then
        local frac = progression.progress(p)
        ui.text(L("Next: {rank}", { rank = L(nextRank.name) }), left, TOP + 54, C.uiDim, "small")
        ui.bar(left, TOP + 72, colW - 40, 8, frac, C.uiPrimary)
        ui.textRight(string.format("%d%%", math.floor(frac * 100)),
            left + colW - 40, TOP + 54, C.uiDim, "small")
    else
        ui.text(L("Nothing left to prove"), left, TOP + 54, C.uiDim, "small")
    end

    local y = TOP + 100
    local rec = p.record or {}
    local stats = {
        { L("CREDITS"), util.money(p.credits), C.amber },
        { L("CARGO"), L("{a} / {b} t", { a = p:cargoUsed(), b = p:cargoCapacity() }), C.uiText },
        { L("JUMPS"), tostring(rec.jumps or 0), C.uiText },
        { L("TRADES"), tostring(rec.trades or 0), C.uiText },
        { L("KILLS"), tostring(rec.kills or 0), C.uiText },
    }
    for _, row in ipairs(stats) do
        ui.text(row[1], left, y, C.uiDim, "small")
        ui.textRight(row[2], left + colW - 40, y, row[3], "small")
        y = y + 18
    end

    -- ---- what you owe ---------------------------------------------------
    ui.text(L("OWED"), right, TOP, C.uiPrimary, "normal")
    ui.rule(right, TOP + 22, colW - 20, C.uiLine, 0.4)
    local cy = TOP + 32
    local contracts = self:contracts()
    if #contracts == 0 then
        ui.text(L("No contracts outstanding"), right, cy, C.uiDim, "small")
        cy = cy + 20
    else
        local day = self.world.day or 0
        for i = 1, math.min(#contracts, 4) do
            local m = contracts[i]
            local left_ = math.floor(math.max(0, (m.expires or day) - day))
            ui.textFit(missionsMod.title(m), right, cy, colW - 90, C.uiText, "small")
            ui.textRight(L("{n} {n:day}", { n = left_ }), right + colW - 20, cy,
                left_ <= 1 and C.uiWarn or C.uiDim, "small")
            ui.textFit(m.destName or "?", right + 10, cy + 14, colW - 40, C.uiDim, "small")
            cy = cy + 32
        end
        if #contracts > 4 then
            ui.text(L("and {n} more", { n = #contracts - 4 }), right, cy, C.uiDim, "small")
            cy = cy + 20
        end
    end

    -- ---- who you have dealt with ----------------------------------------
    cy = cy + 14
    ui.text(L("STANDINGS"), right, cy, C.uiPrimary, "normal")
    ui.rule(right, cy + 22, colW - 20, C.uiLine, 0.4)
    cy = cy + 32
    local standings = self:standings()
    if #standings == 0 then
        ui.text(L("Nobody has an opinion of you yet"), right, cy, C.uiDim, "small")
    else
        for i = 1, math.min(#standings, 5) do
            local e = standings[i]
            local faction = factions.get(e.id)
            local col = { faction.color[1], faction.color[2], faction.color[3], 1 }
            ui.textFit(L(faction.name), right, cy, colW - 130, col, "small")
            local bounty = (p.bounties and p.bounties[e.id]) or 0
            if bounty > 0 then
                ui.textRight(L("WANTED {cash}", { cash = util.money(bounty) }),
                    right + colW - 20, cy, C.uiDanger, "small")
            else
                ui.textRight(L(p:reputationName(e.id)), right + colW - 20, cy,
                    e.value < 0 and C.uiWarn or C.uiPrimary, "small")
            end
            cy = cy + 18
        end
    end

    -- ---- what just happened ---------------------------------------------
    local ly = h - 150
    ui.text(L("LATEST"), left, ly, C.uiPrimary, "normal")
    ui.rule(left, ly + 22, w - 120, C.uiLine, 0.4)
    ly = ly + 32
    local log = p.log or {}
    for i = 1, math.min(#log, 4) do
        local e = log[i]
        local col = C.uiText
        if e.kind == "alert" then col = C.uiDanger
        elseif e.kind == "good" then col = C.uiPrimary end
        ui.textFit(e.text, left, ly, w - 200, col, "small")
        ui.textRight(L("day {n}", { n = math.floor(e.day or 0) }), w - 60, ly, C.uiDim, "small")
        ly = ly + 18
    end
end

return Summary

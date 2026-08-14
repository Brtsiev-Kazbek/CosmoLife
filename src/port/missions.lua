-- The contract board.
--
-- Part of the docked screen (states/port.lua); the port state comes in as an
-- explicit first argument.

local util = require("src.lib.util")
local ui = require("src.ui.widgets")
local missionsMod = require("src.sim.missions")
local palette = require("src.render.palette")
local i18n = require("src.i18n")
local layout = require("src.port.layout")

local missions = {}

local C = palette.colors
local L = i18n.format

function missions.buildMissionMenu(p)
    local board = p.world:board(p.place)
    p.board = board
    local items = {}
    for _, m in ipairs(board) do
        local ok = missionsMod.canAccept(m, p.player)
        items[#items + 1] = {
            label = missionsMod.title(m),
            value = util.money(m.reward) .. " " .. L("cr"),
            mission = m,
            color = m.illegal and C.magenta or (m.warZone and C.uiWarn or nil),
            valueColor = ok and C.amber or C.uiDim,
        }
    end
    if #items == 0 then items[1] = { label = L("No contracts posted."), disabled = true } end
    p.menu = ui.menu(items, { visible = layout.rows() })
end

function missions.acceptMission(p)
    local item = p.menu:current()
    if not item or not item.mission then return end
    local ok, why = missionsMod.accept(item.mission, p.player, p.world.day)
    if ok then
        p:say(L("Contract accepted."))
        p.player:addLog(L("Accepted: {title}", { title = missionsMod.title(item.mission) }),
            p.world.day, "info")
        missions.buildMissionMenu(p)
    else
        p:say(L("Cannot accept: {reason}", { reason = L(tostring(why)) }), true)
    end
end

return missions

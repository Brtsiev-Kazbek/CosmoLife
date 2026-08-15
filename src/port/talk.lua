-- Local talk.
--
-- The one tab that is not a transaction: it is where the world tells you where
-- to go next. Pressing ENTER on a line that points somewhere notes it as a
-- lead, and the chart marks it -- so "they are short of medicine in Tirizaon"
-- stops being a sentence and becomes a destination.
--
-- Part of the docked screen (states/port.lua); the port state comes in as an
-- explicit first argument.

local ui = require("src.ui.widgets")
local palette = require("src.render.palette")
local rumoursMod = require("src.sim.rumours")
local i18n = require("src.i18n")
local layout = require("src.port.layout")

local talk = {}

local C = palette.colors
local L = i18n.format

local KIND_COLOR = {
    demand = C.uiPrimary, danger = C.uiDanger, war = C.uiWarn,
    colony = C.amber, market = C.cyan,
}

function talk.buildTalkMenu(p)
    p.rumours = p.world:rumours(p.place)
    local noted = {}
    for _, lead in ipairs(p.player.leads or {}) do noted[lead.systemId .. lead.text] = true end

    local items = {}
    for _, r in ipairs(p.rumours) do
        items[#items + 1] = {
            label = rumoursMod.line(r),
            -- only a rumour with a place in it can be followed up; the rest
            -- are worth reading and nothing more
            value = r.systemId and (noted[r.systemId .. r.text] and L("noted") or L("ENTER to note"))
                or nil,
            valueColor = noted[(r.systemId or "") .. r.text] and C.uiPrimary or C.uiDim,
            color = KIND_COLOR[r.kind],
            rumour = r,
        }
    end
    if #items == 0 then
        items[1] = { label = L("Nobody here has anything to say."), disabled = true }
    end
    p.menu = ui.menu(items, { visible = layout.rows() })
end

function talk.note(p)
    local item = p.menu:current()
    if not item or not item.rumour then return end
    local r = item.rumour
    if not r.systemId then
        p:say(L("That is talk, not a destination."), true)
        return
    end
    local ok = rumoursMod.note(p.player, r, p.world.day)
    if ok then
        p:say(L("Noted: {system}", { system = r.systemName or "?" }))
        p.player:addLog(rumoursMod.line(r), p.world.day, "info")
    else
        p:say(L("Already in your notes."))
    end
    talk.buildTalkMenu(p)
end

return talk

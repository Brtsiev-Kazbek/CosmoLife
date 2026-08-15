-- What people are saying, and where it points.
--
-- `rumours` has been declared as a service since interiors were written
-- (`procgen/interior.lua:24`) and there has never been anything behind it: the
-- terminal opened the overview tab and the player learned nothing. It is the
-- third thing in this project found written and unwired, after
-- `settlement.generateLod` and the objective marker.
--
-- The rule here is that a rumour is *true*. Every line below is read off the
-- simulation -- a neighbouring economy that eats what this one makes, a war
-- diplomacy is actually running, a system whose law level really is that low,
-- a colony that really is short -- so a player who flies out and checks finds
-- what they were told. Invented colour that pays off in nothing teaches people
-- to stop reading, and there is no cheaper way to make a world feel dead than
-- to fill its bars with noise.
--
-- Pure Lua on plain tables: the galaxy, diplomacy and player come in as
-- arguments, so what the bar knows can be checked head-lessly.

local Rng = require("src.lib.rng")
local commodities = require("src.sim.commodities")
local colonyMod = require("src.sim.colony")
local factions = require("src.sim.factions")
local i18n = require("src.i18n")

local rumours = {}

local floor, max = math.floor, math.max

-- How long a lead is worth acting on. Prices move, wars end, and a note in
-- the log that has quietly stopped being true is worse than no note.
rumours.LEAD_DAYS = 24

-- How far out the bar's gossip reaches. Beyond this nobody here has been.
local REACH = 42

--- Everything worth saying at this port today.
--
-- `opts`: seed, day, place, stub, galaxy, diplomacy, player, market.
-- Returns a list of { kind, text, args, systemId, systemName }.
function rumours.generate(opts)
    local out = {}
    local day = floor(opts.day or 0)
    local rng = Rng.new(opts.seed or 1, "rumours", day / 3)
    local stub, galaxy = opts.stub, opts.galaxy
    local place = opts.place or {}

    -- ---- who wants what this world makes ---------------------------------
    --
    -- The one rumour that is worth a hold of cargo. The local economy's
    -- exports against a neighbour's consumption: both tables already exist,
    -- and nobody had ever compared them.
    local neighbours = {}
    if galaxy and stub then
        for _, s in ipairs(galaxy:systemsNear(stub.x, stub.y, stub.z, REACH, 24)) do
            if s.id ~= stub.id then neighbours[#neighbours + 1] = s end
        end
    end

    local here = commodities.economy(place.economyId or "industrial")
    local pairsFound = {}
    for _, s in ipairs(neighbours) do
        local eco = commodities.economy(s.economyId)
        for id, made in pairs(here.produces) do
            local eaten = eco.consumes[id] or 0
            if made > 0.5 and eaten > 0.8 then
                pairsFound[#pairsFound + 1] = { s = s, id = id, weight = made * eaten }
            end
        end
    end
    -- sorted, because `pairs` over the produce table is not ordered the same
    -- way twice and a bar that says something different on every launch is
    -- exactly the bug this project spent a commit removing from the economy
    table.sort(pairsFound, function(a, b)
        if a.weight ~= b.weight then return a.weight > b.weight end
        if a.s.id ~= b.s.id then return a.s.id < b.s.id end
        return a.id < b.id
    end)
    for i = 1, math.min(2, #pairsFound) do
        local p = pairsFound[i]
        out[#out + 1] = {
            kind = "demand",
            text = "They are short of {cargo:gen:lc} in {system}",
            args = { cargo = commodities.get(p.id).name, system = p.s.name },
            terms = { "cargo" },
            -- carried so the claim can be checked, by a test or by the screen
            cargoId = p.id,
            systemId = p.s.id, systemName = p.s.name,
        }
    end

    -- ---- where the law is not ---------------------------------------------
    local lawless
    for _, s in ipairs(neighbours) do
        if (s.lawLevel or 1) < 0.25 and (not lawless or s.lawLevel < lawless.lawLevel) then
            lawless = s
        end
    end
    if lawless then
        out[#out + 1] = {
            kind = "danger",
            text = "Nobody flies into {system} unarmed these days",
            args = { system = lawless.name },
            systemId = lawless.id, systemName = lawless.name,
        }
    end

    -- ---- a war that is really running -------------------------------------
    if opts.diplomacy then
        local wars = opts.diplomacy:activeWars()
        if #wars > 0 then
            local w = wars[1 + (day % #wars)]
            out[#out + 1] = {
                kind = "war",
                text = "The war between {a} and {b} shows no sign of ending",
                args = { a = factions.get(w.a).name, b = factions.get(w.b).name },
                terms = { "a", "b" },
            }
        end
    end

    -- ---- what the local market is doing ------------------------------------
    if opts.market then
        local ids = {}
        for id in pairs(opts.market.events or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        local id = ids[1]
        if id then
            local ev = opts.market.events[id]
            out[#out + 1] = {
                kind = "market",
                text = ev.mul > 1 and "{cargo} is hard to come by here just now"
                    or "There is more {cargo:gen:lc} here than anyone can use",
                args = { cargo = commodities.get(id).name },
                terms = { "cargo" },
            }
        end
    end

    -- ---- your own affairs ---------------------------------------------------
    for _, c in ipairs((opts.player and opts.player.colonies) or {}) do
        local short = colonyMod.shortfall(c, 20)
        local worstId, worstN = nil, 0
        local keys = {}
        for id in pairs(short) do keys[#keys + 1] = id end
        table.sort(keys)
        for _, id in ipairs(keys) do
            if short[id] > worstN then worstId, worstN = id, short[id] end
        end
        if worstId then
            out[#out + 1] = {
                kind = "colony",
                text = "Word from {name}: they are down to their last {cargo:gen:lc}",
                args = { name = c.name, cargo = commodities.get(worstId).name },
                terms = { "cargo" },
                systemId = c.systemId,
            }
        end
    end

    -- ---- and something about this place -------------------------------------
    local flavour = {
        "Everyone here works for the same company, one way or another",
        "The dock crew will tell you the pay was better last year",
        "Half the bar is waiting on a ship that is late",
        "They say the last commander through here left owing money",
    }
    out[#out + 1] = {
        kind = "flavour",
        text = flavour[rng:int(1, #flavour)],
        args = {},
    }

    return out
end

--- One rumour as a finished line of text.
--
-- The declinable arguments are named per rumour rather than run over every
-- argument: a system called Grain is not a commodity, and the dictionary
-- cannot tell the difference.
function rumours.line(r)
    local args = {}
    for k, v in pairs(r.args or {}) do args[k] = v end
    for _, name in ipairs(r.terms or {}) do
        if args[name] then args[name] = i18n.term(args[name]) end
    end
    return i18n.format(r.text, args)
end

--- Notes a rumour in the player's log of leads.
--
-- A lead is what turns talk into navigation: the chart marks it, so a name
-- heard in a bar becomes somewhere to steer.
function rumours.note(player, r, day)
    if not r or not r.systemId then return false, "nothing to follow up" end
    player.leads = player.leads or {}
    for _, lead in ipairs(player.leads) do
        if lead.systemId == r.systemId and lead.text == r.text then
            lead.expires = day + rumours.LEAD_DAYS
            return false, "already noted"
        end
    end
    player.leads[#player.leads + 1] = {
        systemId = r.systemId, systemName = r.systemName,
        kind = r.kind, text = r.text, args = r.args,
        day = day, expires = day + rumours.LEAD_DAYS,
    }
    return true
end

--- Drops leads that have gone stale.  Returns how many went.
function rumours.expire(player, day)
    local list = player.leads
    if not list then return 0 end
    local gone = 0
    for i = #list, 1, -1 do
        if day > (list[i].expires or 0) then
            table.remove(list, i)
            gone = gone + 1
        end
    end
    return gone
end

--- Leads by system id, for the chart.
function rumours.bySystem(player)
    local out = {}
    for _, lead in ipairs(player.leads or {}) do
        local list = out[lead.systemId] or {}
        list[#list + 1] = lead
        out[lead.systemId] = list
    end
    return out
end

return rumours

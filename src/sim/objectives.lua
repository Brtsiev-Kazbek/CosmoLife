-- Objectives: what the player is supposed to be doing right now.
--
-- The game never told anyone. There was no objective line, no waypoint, and
-- the only thing resembling a goal -- founding a colony -- was reachable only
-- by pressing an unadvertised key to read a requirements list nothing pointed
-- at.
--
-- This is one mechanism for three sources: the tutorial chain, accepted
-- contracts and the next rank. They share a single line on the HUD and a
-- single world marker, because a player can only meaningfully chase one thing
-- at a time, and a screen with three competing arrows points at nothing.
--
-- An objective is data, not a coroutine:
--
--   { id, text, hint, done(ctx) -> bool, marker(ctx) -> x,y,z }
--
-- `done` is polled, so an objective cannot get stuck waiting for an event it
-- missed, and a save that reloads mid-objective simply re-evaluates.

local objectives = {}

local Tracker = {}
Tracker.__index = Tracker

function objectives.tracker()
    return setmetatable({ sources = {}, current = nil }, Tracker)
end

--- Registers a source of objectives. `priority` decides who wins when more
--- than one has something to say; lower is more important.
--
-- `fn(ctx)` returns an objective table or nil.
function Tracker:addSource(name, priority, fn)
    self.sources[#self.sources + 1] = { name = name, priority = priority, fn = fn }
    table.sort(self.sources, function(a, b) return a.priority < b.priority end)
end

--- Re-evaluates and returns the objective to show, or nil.
function Tracker:update(ctx)
    for _, source in ipairs(self.sources) do
        local ok, obj = pcall(source.fn, ctx)
        if ok and obj then
            obj.source = source.name
            self.current = obj
            return obj
        end
    end
    self.current = nil
    return nil
end

function Tracker:get() return self.current end

--- Where to point, in world coordinates, or nil.
function Tracker:markerPos(ctx)
    local obj = self.current
    if not obj or not obj.marker then return nil end
    local ok, x, y, z = pcall(obj.marker, ctx)
    if ok and x then return x, y, z end
    return nil
end

-- ---------------------------------------------------------------------------
-- Built-in sources
-- ---------------------------------------------------------------------------

--- Accepted contracts: point at the destination system, or at the port when
--- it is in this system.
function objectives.contractSource(ctx)
    local player = ctx.player
    if not player or #player.missions == 0 then return nil end
    local missions = require("src.sim.missions")

    -- prefer one that can be progressed here
    local here = ctx.systemId
    local best
    for _, m in ipairs(player.missions) do
        if m.state == "active" then
            if m.destSystemId == here then best = m break end
            best = best or m
        end
    end
    if not best then return nil end

    local sameSystem = best.destSystemId == here
    return {
        id = "contract:" .. tostring(best.destSystemId) .. ":" .. tostring(best.titleText),
        text = missions.title(best),
        hint = sameSystem and "Deliver it at {dest}" or "Jump to {dest}",
        hintArgs = { dest = best.destName or "?" },
        done = function() return best.state ~= "active" end,
        marker = sameSystem and function(c)
            local port = c.findPort and c.findPort(best.destName)
            if port then return port.pos.x, port.pos.y, port.pos.z end
            return nil
        end or nil,
    }
end

--- The next rank, once nothing more urgent is pending.
function objectives.rankSource(ctx)
    local progression = require("src.sim.progression")
    local player = ctx.player
    if not player then return nil end
    local nextRank = progression.next(player)
    if not nextRank then return nil end
    local need, amount = progression.requirement(player)
    if need ~= "credits" then return nil end
    return {
        id = "rank:" .. nextRank.id,
        text = "Reach {rank}",
        textArgs = { rank = nextRank.name },
        hint = "{cash} cr more",
        hintArgs = { cash = amount },
        done = function() return progression.rank(player).id == nextRank.id end,
    }
end

return objectives

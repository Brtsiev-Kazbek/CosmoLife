-- The tutorial.
--
-- There was none. A new commander appeared in empty space with 1,400 credits,
-- an empty hold, no target and no prompt, and the title screen's control list
-- described a key scheme that no longer existed. The fastest route to money
-- was to be attacked by a pirate and win.
--
-- This is a chain of small steps, each of which is a thing the player has to
-- do once. It is data rather than script: a step declares how to tell that it
-- is finished, and the chain polls. That means nothing gets stuck because an
-- event fired while a menu was open, a save resumes exactly where it left off,
-- and skipping a step by doing it early is automatically handled -- if you
-- have already docked, the "dock" step is complete the moment it is reached.
--
-- Steps deliberately teach in the order the game needs them: look, target,
-- travel, dock, trade, jump. Landing and walking come after, because they are
-- optional to the trading loop.

local tutorial = {}

--- Each step:
---   id      stable key, stored in the save
---   text    the objective line
---   hint    a second line explaining how, with {key} placeholders
---   done(ctx) -> bool
---   keys    actions whose bound keys are substituted into `hint`
tutorial.STEPS = {
    {
        id = "look",
        text = "Get your bearings",
        hint = "Mouse aims. {throttleUp}/{throttleDown} set throttle.",
        keys = { "throttleUp", "throttleDown" },
        done = function(ctx) return (ctx.flight and ctx.flight.throttle or 0) > 0.15 end,
    },
    {
        id = "target",
        text = "Select the station",
        hint = "{target} cycles targets. Pick the station ahead.",
        keys = { "target" },
        done = function(ctx)
            local t = ctx.flight and ctx.flight.target
            return t ~= nil and (t.station ~= nil or t.place ~= nil)
        end,
    },
    {
        id = "autopilot",
        text = "Let the autopilot fly you there",
        hint = "{autopilot} engages it. {warp} is manual cruise.",
        keys = { "autopilot", "warp" },
        done = function(ctx)
            local f = ctx.flight
            if not f then return false end
            -- either the autopilot ran, or they closed the distance themselves
            if f.autopilot then return true end
            local t = f.target
            return t ~= nil and (t.distance or 1e12) < 12000
        end,
    },
    {
        id = "dock",
        text = "Dock at the station",
        hint = "Slow to under 120 m/s and fly into the lit mouth. {dock} to dock.",
        keys = { "dock" },
        done = function(ctx) return (ctx.player.record.dockings or 0) > 0 end,
    },
    {
        id = "buy",
        text = "Buy something to sell elsewhere",
        hint = "MARKET tab. B buys, N sells. Cheap here is dear somewhere else.",
        done = function(ctx) return ctx.player:cargoUsed() > 0 end,
    },
    {
        id = "map",
        text = "Open the galaxy map",
        hint = "{map} opens it. The ring is your jump range.",
        keys = { "map" },
        done = function(ctx) return ctx.player.record.jumps > 0 or ctx.sawMap == true end,
    },
    {
        id = "jump",
        text = "Jump to another system",
        hint = "Select a system inside the ring and press ENTER.",
        done = function(ctx) return ctx.player.record.jumps > 0 end,
    },
    {
        id = "sell",
        text = "Sell your cargo at a profit",
        hint = "Dock again and check the MARKET tab.",
        done = function(ctx) return (ctx.player.record.trades or 0) >= 2 end,
    },
    {
        id = "contract",
        text = "Take a contract",
        hint = "CONTRACTS tab at any station with a board.",
        done = function(ctx) return #ctx.player.missions > 0 or (ctx.player.record.missionsDone or 0) > 0 end,
    },
    {
        id = "land",
        text = "Land on a planet",
        hint = "{landingGear} lowers the gear. Approach slowly and level.",
        keys = { "landingGear" },
        done = function(ctx) return (ctx.player.record.landings or 0) > 0 end,
    },
    {
        id = "disembark",
        text = "Step outside",
        hint = "{disembark} leaves the ship once you are down.",
        keys = { "disembark" },
        done = function(ctx) return (ctx.player.record.walked or 0) > 0 end,
    },
}

tutorial.byId = {}
for i, s in ipairs(tutorial.STEPS) do
    s.index = i
    tutorial.byId[s.id] = s
end

--- The step the player is on, or nil when the chain is finished.
--
-- Completed steps are skipped rather than replayed, so a player who docked
-- before being told to does not get told to.
function tutorial.current(state, ctx)
    if not state or state.done then return nil end
    for i = (state.index or 1), #tutorial.STEPS do
        local step = tutorial.STEPS[i]
        local ok, finished = pcall(step.done, ctx)
        if not (ok and finished) then
            state.index = i
            return step
        end
    end
    state.done = true
    state.index = #tutorial.STEPS + 1
    return nil
end

--- Advances the chain, returning the step that was just completed, if any.
function tutorial.update(state, ctx)
    if not state or state.done then return nil end
    local before = state.index or 1
    local step = tutorial.current(state, ctx)
    if (state.index or 1) > before then
        return tutorial.STEPS[before]
    end
    if state.done and not state.announced then
        state.announced = true
        return tutorial.STEPS[#tutorial.STEPS]
    end
    return step and nil or nil
end

--- Fresh state for a new commander.
function tutorial.newState() return { index = 1 } end

--- Builds the hint line with the player's actual bindings substituted.
function tutorial.hintArgs(step, keyName)
    if not step.keys then return nil end
    local args = {}
    for _, action in ipairs(step.keys) do args[action] = keyName(action) end
    return args
end

--- Turns the chain into an objective source (see src/sim/objectives.lua).
function tutorial.source(state, keyName)
    return function(ctx)
        local step = tutorial.current(state, ctx)
        if not step then return nil end
        return {
            id = "tutorial:" .. step.id,
            text = step.text,
            hint = step.hint,
            hintArgs = tutorial.hintArgs(step, keyName),
            done = function(c) return step.done(c) end,
        }
    end
end

return tutorial

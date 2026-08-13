-- A stack of game states.
--
-- Pushing keeps the state below alive (so the market screen can draw the
-- docked hangar behind it); switching replaces the top of the stack.

local class = require("src.lib.class")

local Manager = class("StateManager")

function Manager:init(game)
    self.game = game
    self.stack = {}
end

function Manager:current() return self.stack[#self.stack] end

local function call(state, name, ...)
    if state and state[name] then return state[name](state, ...) end
end

function Manager:push(state, ...)
    local prev = self:current()
    call(prev, "pause")
    self.stack[#self.stack + 1] = state
    state.game = self.game
    state.manager = self
    call(state, "enter", ...)
    return state
end

function Manager:pop(...)
    local top = table.remove(self.stack)
    call(top, "exit", ...)
    local now = self:current()
    call(now, "resume", ...)
    return now
end

function Manager:switch(state, ...)
    while #self.stack > 0 do
        local top = table.remove(self.stack)
        call(top, "exit")
    end
    return self:push(state, ...)
end

--- Pops until `state` is on top (used to get back to flight from any depth).
function Manager:popTo(state)
    while #self.stack > 1 and self:current() ~= state do
        self:pop()
    end
    return self:current()
end

function Manager:clear()
    while #self.stack > 0 do
        local top = table.remove(self.stack)
        call(top, "exit")
    end
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

function Manager:update(dt)
    -- states below the top may opt in to background updates
    for i = 1, #self.stack - 1 do
        local s = self.stack[i]
        if s.updateInBackground then call(s, "update", dt, true) end
    end
    call(self:current(), "update", dt, false)
end

function Manager:draw()
    -- draw from the lowest state that wants to be visible under the top
    local first = #self.stack
    while first > 1 and self.stack[first].drawUnderlying do first = first - 1 end
    for i = first, #self.stack do
        call(self.stack[i], "draw", i < #self.stack)
    end
end

local FORWARD = {
    "keypressed", "keyreleased", "textinput", "mousepressed", "mousereleased",
    "mousemoved", "wheelmoved", "resize",
}

for _, name in ipairs(FORWARD) do
    Manager[name] = function(self, ...)
        return call(self:current(), name, ...)
    end
end

return Manager

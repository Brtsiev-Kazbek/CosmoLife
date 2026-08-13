-- Minimal single-inheritance class system.
--
--   local Ship = class("Ship")
--   function Ship:init(hp) self.hp = hp end
--   local Fighter = class("Fighter", Ship)
--   function Fighter:init(hp) Fighter.super.init(self, hp) end

local function class(name, parent)
    local cls = {}
    cls.__name = name
    cls.super = parent
    cls.__index = cls

    if parent then
        setmetatable(cls, { __index = parent, __call = function(c, ...) return c.new(...) end })
    else
        setmetatable(cls, { __call = function(c, ...) return c.new(...) end })
    end

    function cls.new(...)
        local obj = setmetatable({}, cls)
        if obj.init then obj:init(...) end
        return obj
    end

    function cls:isInstanceOf(other)
        local c = getmetatable(self)
        while c do
            if c == other then return true end
            c = c.super
        end
        return false
    end

    return cls
end

return class

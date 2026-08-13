-- Retires entities whose lifetime has run out (bolts, sparks, debris).

local tiny = require("lib.tiny")

return function()
    local system = tiny.processingSystem()
    system.filter = tiny.requireAll("lifetime")

    function system:process(e, dt)
        local l = e.lifetime
        l.remaining = l.remaining - dt
        if l.remaining <= 0 then
            if e.onExpire then e.onExpire(e, self.context) end
            tiny.removeEntity(self.world, e)
        end
    end

    return system
end

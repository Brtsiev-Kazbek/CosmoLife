-- Integrates transforms.
--
-- Ships steered by AI or by the player have their velocity set elsewhere; this
-- system only advances position, and applies the local gravity when an entity
-- opts in with a `gravity` component.

local tiny = require("lib.tiny")

return function()
    local system = tiny.processingSystem()
    system.filter = tiny.requireAll("transform", "velocity")

    function system:process(e, dt)
        local v = e.velocity
        if e.gravity and e.gravity ~= 0 then
            local up = self.context.up
            if up then
                v.x = v.x - up.x * e.gravity * dt
                v.y = v.y - up.y * e.gravity * dt
                v.z = v.z - up.z * e.gravity * dt
            end
        end
        if e.drag and e.drag > 0 then
            local k = math.exp(-e.drag * dt)
            v.x, v.y, v.z = v.x * k, v.y * k, v.z * k
        end
        local p = e.transform.pos
        p.x = p.x + v.x * dt
        p.y = p.y + v.y * dt
        p.z = p.z + v.z * dt
    end

    return system
end

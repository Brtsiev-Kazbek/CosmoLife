-- Shield recharge and slow hull repair, for anything with health.

local tiny = require("lib.tiny")

return function()
    local system = tiny.processingSystem()
    system.filter = tiny.requireAll("health")

    function system:process(e, dt)
        local h = e.health
        h.shieldTimer = math.max(0, (h.shieldTimer or 0) - dt)
        if h.shieldTimer <= 0 and h.shield < h.maxShield then
            h.shield = math.min(h.maxShield, h.shield + (e.shieldRecharge or 3) * dt)
        end
        if e.hullRepair and h.hull < h.maxHull and h.shieldTimer <= 0 then
            h.hull = math.min(h.maxHull, h.hull + e.hullRepair * dt)
        end
    end

    return system
end

-- Projectile hits.
--
-- A swept sphere test per projectile against every entity that has health.
-- The sweep matters: a laser bolt covers tens of metres per frame and a point
-- test would tunnel straight through a fighter.

local tiny = require("lib.tiny")
local util = require("src.lib.util")

return function()
    local system = tiny.system()
    system.filter = tiny.requireAll("projectile", "transform", "velocity")
    system.targetFilter = tiny.requireAll("health", "transform")

    function system:onAddToWorld(world)
        self.targets = tiny.filter and {} or {}
    end

    function system:update(dt)
        local ctx = self.context
        local world = self.world
        local entities = self.entities
        if #entities == 0 then return end

        -- gather targets once per frame rather than per projectile
        local targets = {}
        for _, e in ipairs(world.entities) do
            if e.health and e.transform then targets[#targets + 1] = e end
        end

        for i = #entities, 1, -1 do
            local p = entities[i]
            local from = p.transform.pos
            local v = p.velocity
            -- the position before this frame's movement system ran
            local px, py, pz = from.x - v.x * dt, from.y - v.y * dt, from.z - v.z * dt
            local dx, dy, dz = from.x - px, from.y - py, from.z - pz
            local len2 = dx * dx + dy * dy + dz * dz

            for _, t in ipairs(targets) do
                if t ~= p.projectile.owner and t.health.hull > 0 then
                    local r = (t.radius or 10) * 1.15 + p.projectile.radius
                    local sx = t.transform.pos.x - px
                    local sy = t.transform.pos.y - py
                    local sz = t.transform.pos.z - pz
                    local tt = 0
                    if len2 > 1e-9 then
                        tt = util.clamp((sx * dx + sy * dy + sz * dz) / len2, 0, 1)
                    end
                    local cx = px + dx * tt - t.transform.pos.x
                    local cy = py + dy * tt - t.transform.pos.y
                    local cz = pz + dz * tt - t.transform.pos.z
                    if cx * cx + cy * cy + cz * cz <= r * r then
                        self:hit(p, t, px + dx * tt, py + dy * tt, pz + dz * tt)
                        break
                    end
                end
            end
        end
    end

    --- Applies damage: shields soak first, kinetic rounds bleed through.
    function system:hit(p, target, x, y, z)
        local ctx = self.context
        local h = target.health
        local remaining = p.projectile.damage

        if h.shield > 0 then
            local bleed = p.projectile.kinetic and 0.35 or 0
            local absorbed = math.min(h.shield, remaining * (1 - bleed))
            h.shield = h.shield - absorbed
            remaining = remaining - absorbed
        end
        if remaining > 0 then h.hull = h.hull - remaining end
        h.shieldTimer = 6.0

        if ctx.onImpact then ctx.onImpact(x, y, z, p.projectile.color, target) end
        if h.hull <= 0 and ctx.onKill then
            ctx.onKill(target, p.projectile.owner)
        end
        tiny.removeEntity(self.world, p)
    end

    return system
end

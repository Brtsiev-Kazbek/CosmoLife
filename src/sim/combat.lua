-- Weapons, projectiles and damage.
--
-- Projectiles live in a fixed pool of plain tables that is compacted in place
-- each frame; nothing is allocated during a firefight.  Damage resolution is
-- deliberately simple and readable: shields soak first (kinetic rounds bleed
-- through), then hull, then the target dies and tells the caller who killed it
-- so bounties, missions and reputation can all react from one place.

local vec3 = require("src.lib.vec3")
local util = require("src.lib.util")
local config = require("src.config")
local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")

local combat = {}

local CFG = config.combat
local sqrt, min, max = math.sqrt, math.min, math.max

-- ---------------------------------------------------------------------------
-- Shared bolt / debris meshes (built once, drawn many times)
-- ---------------------------------------------------------------------------

local meshCache = {}

local function boltMesh(color)
    local key = string.format("%0.2f,%0.2f,%0.2f", color[1], color[2], color[3])
    if meshCache[key] then return meshCache[key] end
    local b = MeshBuilder.new()
    -- a stretched octahedron reads as a tracer at any distance
    b:push():scale(1, 1, 6)
    geometry.sphere(b, 1.0, 6, 4, color)
    b:pop()
    local m = b:build()
    meshCache[key] = m
    return m
end
combat.boltMesh = boltMesh

local function debrisMesh()
    if meshCache.debris then return meshCache.debris end
    local b = MeshBuilder.new()
    geometry.sphere(b, 1.0, 6, 4, { 1.0, 0.72, 0.35, 1 })
    meshCache.debris = b:build()
    return meshCache.debris
end
combat.debrisMesh = debrisMesh

-- ---------------------------------------------------------------------------
-- Arena: the mutable combat state the flight scene owns
-- ---------------------------------------------------------------------------

function combat.newArena()
    return {
        projectiles = {},
        nProjectiles = 0,
        effects = {},
        nEffects = 0,
    }
end

--- Fires one shot from `owner` at an aim direction.
function combat.fire(arena, owner, weapon, dirx, diry, dirz, muzzleIndex)
    local w = weapon.weapon or weapon
    local hp = owner.hardpoints and owner.hardpoints[((muzzleIndex or 0) % math.max(#owner.hardpoints, 1)) + 1]
    local ox, oy, oz = owner.pos.x, owner.pos.y, owner.pos.z
    if hp then
        ox = ox + owner.right.x * hp.x + owner.up.x * hp.y - owner.fwd.x * hp.z
        oy = oy + owner.right.y * hp.x + owner.up.y * hp.y - owner.fwd.y * hp.z
        oz = oz + owner.right.z * hp.x + owner.up.z * hp.y - owner.fwd.z * hp.z
    end

    local speed = w.speed or CFG.laserSpeed
    local n = arena.nProjectiles + 1
    arena.nProjectiles = n
    local p = arena.projectiles[n]
    if not p then
        p = { pos = vec3(), vel = vec3() }
        arena.projectiles[n] = p
    end
    p.pos:set(ox, oy, oz)
    -- inherit the shooter's velocity so shots do not lag a fast ship
    p.vel:set(dirx * speed + (owner.vel and owner.vel.x or 0),
              diry * speed + (owner.vel and owner.vel.y or 0),
              dirz * speed + (owner.vel and owner.vel.z or 0))
    p.dir = p.dir or vec3()
    p.dir:set(dirx, diry, dirz)
    p.life = CFG.laserLifetime * (w.beam and 0.6 or 1)
    p.damage = w.damage
    p.kinetic = w.kinetic or false
    p.mining = w.mining or false
    p.color = w.color or { 1, 0.6, 0.3 }
    p.owner = owner
    p.faction = owner.faction
    p.hostileToPlayer = owner.isPlayer ~= true
    p.scale = w.beam and 2.2 or 1.4
    return p
end

--- Spawns an explosion / impact effect.
function combat.effect(arena, x, y, z, size, kind, color)
    local n = arena.nEffects + 1
    arena.nEffects = n
    local e = arena.effects[n]
    if not e then
        e = { pos = vec3() }
        arena.effects[n] = e
    end
    e.pos:set(x, y, z)
    e.size = size or 6
    e.life = kind == "explosion" and 1.4 or 0.28
    e.maxLife = e.life
    e.kind = kind or "hit"
    e.color = color or { 1, 0.7, 0.35 }
    e.shards = nil
    if kind == "explosion" then
        e.shards = {}
        for i = 1, 10 do
            local dx, dy, dz = (i * 37 % 13 - 6) / 6, (i * 53 % 11 - 5) / 5, (i * 71 % 17 - 8) / 8
            local l = sqrt(dx * dx + dy * dy + dz * dz) + 1e-6
            e.shards[i] = { dx / l, dy / l, dz / l, (i % 5 + 3) * size * 0.12 }
        end
    end
    return e
end

-- ---------------------------------------------------------------------------
-- Damage
-- ---------------------------------------------------------------------------

--- Applies damage to an entity.  Returns "dead" when it was destroyed.
function combat.damage(target, amount, kinetic, source)
    if target.dead then return nil end
    target.lastHitBy = source
    target.lastHitTime = 0

    local remaining = amount
    if (target.shield or 0) > 0 then
        -- kinetic rounds punch a fraction straight through the bubble
        local bleed = kinetic and 0.35 or 0
        local toShield = remaining * (1 - bleed)
        local absorbed = min(target.shield, toShield)
        target.shield = target.shield - absorbed
        remaining = remaining - absorbed
        if not kinetic then remaining = max(remaining, 0) end
    end
    if remaining > 0 then
        target.hull = (target.hull or 0) - remaining
    end
    target.shieldTimer = CFG.shieldRegenDelay

    if target.hull <= 0 then
        target.dead = true
        return "dead"
    end
    return "hit"
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

--- Advances every projectile and effect.
-- `ctx` supplies the collidable entities and callbacks:
--   ctx.entities   array of ships (player included)
--   ctx.onKill(victim, killer)
--   ctx.terrainHeight(x, y, z) -> ground altitude, or nil in space
function combat.update(arena, dt, ctx)
    local projectiles = arena.projectiles
    local write = 0
    for i = 1, arena.nProjectiles do
        local p = projectiles[i]
        p.life = p.life - dt
        local alive = p.life > 0
        if alive then
            local px, py, pz = p.pos.x, p.pos.y, p.pos.z
            local nx = px + p.vel.x * dt
            local ny = py + p.vel.y * dt
            local nz = pz + p.vel.z * dt

            -- swept sphere test against every ship
            local entities = ctx.entities
            for e = 1, #entities do
                local t = entities[e]
                if t ~= p.owner and not t.dead and t.hull then
                    local r = (t.radius or 10) * 1.15
                    -- closest approach of the segment to the target centre
                    local sx, sy, sz = t.pos.x - px, t.pos.y - py, t.pos.z - pz
                    local dx, dy, dz = nx - px, ny - py, nz - pz
                    local len2 = dx * dx + dy * dy + dz * dz
                    local tt = 0
                    if len2 > 1e-9 then
                        tt = util.clamp((sx * dx + sy * dy + sz * dz) / len2, 0, 1)
                    end
                    local cx = px + dx * tt - t.pos.x
                    local cy = py + dy * tt - t.pos.y
                    local cz = pz + dz * tt - t.pos.z
                    if cx * cx + cy * cy + cz * cz <= r * r then
                        local result = combat.damage(t, p.damage, p.kinetic, p.owner)
                        combat.effect(arena, px + dx * tt, py + dy * tt, pz + dz * tt,
                            (t.radius or 10) * 0.4, "hit", p.color)
                        if result == "dead" then
                            combat.effect(arena, t.pos.x, t.pos.y, t.pos.z, (t.radius or 10) * 2.2, "explosion")
                            if ctx.onKill then ctx.onKill(t, p.owner) end
                        end
                        alive = false
                        break
                    end
                end
            end

            if alive and ctx.groundHeight then
                local h = ctx.groundHeight(nx, ny, nz)
                if h and h < 0 then
                    combat.effect(arena, nx, ny, nz, 4, "hit", p.color)
                    alive = false
                end
            end

            if alive then p.pos:set(nx, ny, nz) end
        end
        if alive then
            write = write + 1
            if write ~= i then
                projectiles[write], projectiles[i] = projectiles[i], projectiles[write]
            end
        end
    end
    arena.nProjectiles = write

    local effects = arena.effects
    write = 0
    for i = 1, arena.nEffects do
        local e = effects[i]
        e.life = e.life - dt
        if e.life > 0 then
            write = write + 1
            if write ~= i then
                effects[write], effects[i] = effects[i], effects[write]
            end
        end
    end
    arena.nEffects = write
end

--- Regenerates shields and repairs hull for one ship.
function combat.regenerate(e, dt, stats)
    e.shieldTimer = max(0, (e.shieldTimer or 0) - dt)
    local maxShield = stats.maxShield or 0
    if e.shieldTimer <= 0 and (e.shield or 0) < maxShield then
        e.shield = min(maxShield, (e.shield or 0) + (stats.shieldRecharge or 3) * dt)
    end
    if stats.hullRepair and e.hull and e.hull < stats.maxHull and (e.shieldTimer or 0) <= 0 then
        e.hull = min(stats.maxHull, e.hull + stats.hullRepair * dt)
    end
end

--- Lead-pursuit aim point: where to shoot so a bolt and a moving target meet.
function combat.leadTarget(shooter, target, projectileSpeed)
    local dx = target.pos.x - shooter.pos.x
    local dy = target.pos.y - shooter.pos.y
    local dz = target.pos.z - shooter.pos.z
    local rvx = (target.vel and target.vel.x or 0) - (shooter.vel and shooter.vel.x or 0)
    local rvy = (target.vel and target.vel.y or 0) - (shooter.vel and shooter.vel.y or 0)
    local rvz = (target.vel and target.vel.z or 0) - (shooter.vel and shooter.vel.z or 0)
    local dist = sqrt(dx * dx + dy * dy + dz * dz)
    local t = dist / max(projectileSpeed, 1)
    -- one refinement pass is plenty at these speeds
    for _ = 1, 2 do
        local ax = dx + rvx * t
        local ay = dy + rvy * t
        local az = dz + rvz * t
        t = sqrt(ax * ax + ay * ay + az * az) / max(projectileSpeed, 1)
    end
    return shooter.pos.x + dx + rvx * t,
           shooter.pos.y + dy + rvy * t,
           shooter.pos.z + dz + rvz * t,
           dist
end

return combat

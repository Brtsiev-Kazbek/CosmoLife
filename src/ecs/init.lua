-- The entity-component-system layer, built on tiny-ecs (lib/tiny.lua).
--
-- Scope, deliberately: the ECS runs the things a *scene* is made of and that
-- come and go in numbers -- ships, projectiles, impact effects, debris. It
-- does not run the economy, the galaxy or the UI. Those are not entity-shaped:
-- a market is one object with deep behaviour, not a thousand objects with
-- shallow behaviour, and forcing them through components would cost clarity
-- and buy nothing.
--
-- Entities are plain tables. A component is a field. A system declares the
-- fields it needs with a filter, and tiny sorts entities into the systems that
-- match, so adding a behaviour is adding a file here and registering it, and
-- adding a capability to an entity is adding a field.

local tiny = require("lib.tiny")

local ecs = {}

ecs.tiny = tiny

--- Component constructors.
--
-- These exist so that a component's shape is written down once. Nothing stops
-- you writing the fields by hand, but going through here keeps the field names
-- honest and gives one place to look for "what does a ship entity carry?".
ecs.components = {}

local vec3 = require("src.lib.vec3")

function ecs.components.transform(x, y, z)
    return {
        pos = vec3(x or 0, y or 0, z or 0),
        right = vec3(1, 0, 0),
        up = vec3(0, 1, 0),
        fwd = vec3(0, 0, -1),
    }
end

function ecs.components.velocity(x, y, z)
    return vec3(x or 0, y or 0, z or 0)
end

function ecs.components.renderable(model, opts)
    opts = opts or {}
    return {
        model = model,
        scale = opts.scale or 1,
        emissive = opts.emissive or 0,
        alpha = opts.alpha or 1,
        additive = opts.additive or false,
        layer = opts.layer,
        tint = opts.tint,
    }
end

function ecs.components.health(hull, shield)
    return { hull = hull, maxHull = hull, shield = shield or 0, maxShield = shield or 0,
             shieldTimer = 0 }
end

function ecs.components.lifetime(seconds)
    return { remaining = seconds, total = seconds }
end

function ecs.components.projectile(damage, opts)
    opts = opts or {}
    return {
        damage = damage,
        kinetic = opts.kinetic or false,
        mining = opts.mining or false,
        owner = opts.owner,
        faction = opts.faction,
        color = opts.color or { 1, 0.6, 0.3 },
        radius = opts.radius or 1.4,
    }
end

-- ---------------------------------------------------------------------------
-- World
-- ---------------------------------------------------------------------------

--- Creates a tiny world with the standard system set already installed.
-- `context` is shared mutable state the systems need but do not own: the
-- renderer to submit to, the surface for ground queries, callbacks for kills.
function ecs.newWorld(context)
    local world = tiny.world()
    world.context = context or {}

    for _, name in ipairs(ecs.systemOrder) do
        local factory = require("src.ecs.systems." .. name)
        local system = factory()
        system.context = world.context
        tiny.addSystem(world, system)
    end
    return world
end

--- Systems run in this order every frame. Order matters: nothing should read
--- a position that a later system in the same frame is going to change.
ecs.systemOrder = {
    "lifetime",     -- retire what has expired, before anything looks at it
    "movement",     -- integrate transforms
    "collision",    -- resolve projectile hits against health
    "regen",        -- shields and hull recover
    "render",       -- submit to the renderer (draw-time system)
}

--- Convenience: adds an entity and returns it.
function ecs.add(world, entity)
    tiny.addEntity(world, entity)
    return entity
end

function ecs.remove(world, entity)
    tiny.removeEntity(world, entity)
end

--- Runs the simulation systems. The render system is a separate pass so the
--- world can be drawn more than once (mirrors, or a paused scene) without
--- advancing time.
function ecs.update(world, dt)
    world.context.dt = dt
    tiny.update(world, dt, function(_, s) return not s.isDrawSystem end)
end

function ecs.draw(world)
    tiny.update(world, 0, function(_, s) return s.isDrawSystem end)
end

return ecs

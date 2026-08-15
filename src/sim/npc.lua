-- NPC ships and their behaviour.
--
-- Traffic is generated from the system's own facts: a rich industrial world
-- has freighters and police, a lawless frontier has pirates, a war zone has
-- both sides' patrols shooting at each other.  NPCs are spawned in a bubble
-- around the player and quietly retired when they leave it, so a system feels
-- populated without simulating a whole civilisation.
--
-- The AI is a small state machine per ship (`cruise`, `attack`, `flee`,
-- `mine`, `patrol`) driving one shared steering routine.

local Rng = require("src.lib.rng")
local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local util = require("src.lib.util")
local config = require("src.config")
local ships = require("src.procgen.ships")
local equipment = require("src.sim.equipment")
local factions = require("src.sim.factions")
local combat = require("src.sim.combat")
local names = require("src.procgen.names")

local npc = {}

local sqrt, min, max, abs = math.sqrt, math.min, math.max, math.abs
local CFG = config.combat

local SPAWN_RADIUS = 7000
local DESPAWN_RADIUS = 26000
local settings = require("src.settings")
local MAX_NPCS = 14

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local ROLE_BY_KIND = {
    trader   = { "trader", "hauler", "freighter", "shuttle" },
    police   = { "fighter", "interceptor", "gunship" },
    pirate   = { "fighter", "interceptor", "shuttle", "gunship" },
    military = { "gunship", "interceptor", "fighter" },
    miner    = { "miner", "hauler" },
    hunter   = { "fighter", "gunship", "interceptor" },
    civilian = { "shuttle", "trader", "explorer" },
}

local LOADOUT_BY_KIND = {
    trader   = { "pulse1", "shield1", "rack2" },
    civilian = { "pulse1", "shield1" },
    miner    = { "mining", "shield1", "rack2" },
    police   = { "pulse2", "shield2", "thrust1" },
    military = { "cannon", "shield2", "thrust2", "armour" },
    pirate   = { "cannon", "shield1", "thrust1" },
    hunter   = { "beam", "shield2", "thrust2" },
}

--- Creates one NPC ship entity.
function npc.create(opts)
    local rng = Rng.new(opts.seed or 1, "npc")
    local kind = opts.kind or "trader"
    local role = opts.role or rng:pick(ROLE_BY_KIND[kind] or ROLE_BY_KIND.civilian)
    -- Hulls are drawn from a small per-system pool rather than being unique
    -- per spawn. A fleet sharing a handful of designs is what real traffic
    -- looks like, and it means the hull cache actually hits: uncached, this
    -- lofted a complete ship -- wings, greebles, gear -- every few seconds for
    -- the whole session, a periodic frame spike during ordinary flight.
    local HULL_VARIANTS = 6
    local variant = Rng.new(opts.seed or 1, "hull"):int(1, HULL_VARIANTS)
    local def = ships.generate(Rng.hash(opts.systemSeed or 0, role, variant), role)
    local stats = equipment.derive(def.stats, LOADOUT_BY_KIND[kind] or LOADOUT_BY_KIND.civilian)

    local e = {
        kind = "npc",
        aiKind = kind,
        name = names.ship(Rng.hash(opts.seed or 1, "name")),
        pilot = names.person(Rng.hash(opts.seed or 1, "pilot")),
        shipDef = def,
        stats = stats,
        radius = def.radius,
        faction = opts.faction or "independent",
        pos = vec3(opts.x or 0, opts.y or 0, opts.z or 0),
        vel = vec3(0, 0, 0),
        right = vec3(1, 0, 0),
        up = vec3(0, 1, 0),
        fwd = vec3(0, 0, -1),
        hull = stats.maxHull,
        shield = stats.maxShield,
        maxHull = stats.maxHull,
        throttle = 0.5,
        state = "cruise",
        target = nil,
        fireTimer = 0,
        muzzle = 0,
        seed = opts.seed or 1,
        hostileToPlayer = opts.hostile or false,
        cargoValue = math.floor(def.stats.cargo * rng:range(60, 700)),
        bounty = (kind == "pirate") and math.floor(rng:range(600, 5200)) or 0,
        scanned = false,
        weapon = equipment.get((LOADOUT_BY_KIND[kind] or LOADOUT_BY_KIND.civilian)[1]),
        aggression = rng:range(0.4, 1.0),
        skill = rng:range(0.35, 1.0),
        wanderPhase = rng:range(0, math.pi * 2),
        hardpoints = def.hardpoints,
        engines = def.engines,
    }

    -- random initial orientation
    local dx, dy, dz = rng:direction()
    e.fwd:set(dx, dy, dz)
    mat4.orthonormalize(e.right, e.up, e.fwd)
    return e
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

--- Decides the traffic mix for a system.
function npc.trafficProfile(sys, diplomacy, player)
    local law = sys.lawLevel or 0.5
    local pop = sys.population or 0
    local conflict = sys.conflict or 0

    local weights = {
        trader   = 2 + math.log(1 + pop / 1000) * 0.55,
        civilian = 1 + math.log(1 + pop / 5000) * 0.35,
        miner    = (#sys.belts > 0) and 2.0 or 0.4,
        police   = law * 3.2 * (pop > 5000 and 1 or 0.2),
        pirate   = (1 - law) * 3.4 + (sys.frontier or 0) * 1.5,
        military = conflict * 4.0 + (law > 0.7 and 0.5 or 0),
        hunter   = (player and player:totalBounty() > 4000) and 2.2 or 0.3,
    }
    local total = 0
    for _, w in pairs(weights) do total = total + w end
    return weights, total
end

--- Keeps the bubble around the player populated.
function npc.maintain(list, sys, player, diplomacy, day, camera, dt, state)
    state.spawnTimer = (state.spawnTimer or 0) - dt
    -- retire anything that has drifted out of the bubble
    for i = #list, 1, -1 do
        local e = list[i]
        local d = vec3.distance(e.pos, camera.pos)
        if e.dead or d > DESPAWN_RADIUS then
            table.remove(list, i)
        end
    end
    if #list >= math.min(MAX_NPCS, settings.q().maxNpcs) or state.spawnTimer > 0 then return nil end
    -- deterministic: the project avoids math.random so a seed replays exactly
    state.spawnTimer = 2.5 + Rng.new(sys.seed, "spawnTimer", math.floor(day * 997)):float() * 4

    local weights, total = npc.trafficProfile(sys, diplomacy, player)
    if total <= 0 then return nil end
    local rng = Rng.new(sys.seed, "traffic", math.floor(day * 97) + #list)
    local r = rng:float() * total
    local kind = "trader"
    for k, w in pairs(weights) do
        r = r - w
        if r <= 0 then kind = k break end
    end

    -- pick a faction for the newcomer
    local faction = sys.factionId
    if kind == "pirate" then
        faction = "pirates"
    elseif kind == "military" and diplomacy then
        -- a war zone gets both sides
        local enemy
        for _, w in ipairs(diplomacy:activeWars()) do
            if w.a == sys.factionId then enemy = w.b elseif w.b == sys.factionId then enemy = w.a end
        end
        if enemy and rng:bool(0.45) then faction = enemy end
    end

    -- place it somewhere ahead of the player but out of immediate view
    local dx, dy, dz = rng:direction()
    local dist = SPAWN_RADIUS * rng:range(0.55, 1.0)
    local e = npc.create({
        seed = Rng.hash(sys.seed, day, #list, kind),
        systemSeed = sys.seed,
        kind = kind,
        faction = faction,
        x = camera.pos.x + dx * dist,
        y = camera.pos.y + dy * dist,
        z = camera.pos.z + dz * dist,
    })

    -- initial hostility
    if kind == "pirate" then
        e.hostileToPlayer = rng:bool(0.55 + e.aggression * 0.3)
    elseif kind == "police" or kind == "military" then
        e.hostileToPlayer = player:isWanted(faction)
    elseif kind == "hunter" then
        e.hostileToPlayer = player:totalBounty() > 2000
    end
    if diplomacy and player then
        -- ships of a faction the player has wronged do not need much excuse
        if player:reputation(faction) < -0.65 then e.hostileToPlayer = true end
    end

    e.vel:copyFrom(e.fwd):scale(rng:range(60, 260))
    list[#list + 1] = e
    return e
end

-- ---------------------------------------------------------------------------
-- Steering
-- ---------------------------------------------------------------------------

--- Rotates a ship toward a world point and returns how well it is aligned.
local function steerTowards(e, tx, ty, tz, dt, rate)
    local dx, dy, dz = tx - e.pos.x, ty - e.pos.y, tz - e.pos.z
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return 1 end
    dx, dy, dz = dx / len, dy / len, dz / len

    local dot = dx * e.fwd.x + dy * e.fwd.y + dz * e.fwd.z
    dot = util.clamp(dot, -1, 1)

    -- decompose the error into pitch (up) and yaw (right) components
    local ex = dx * e.right.x + dy * e.right.y + dz * e.right.z
    local ey = dx * e.up.x + dy * e.up.y + dz * e.up.z

    local turn = rate * dt
    local yaw = util.clamp(ex * 2.2, -1, 1) * turn
    local pitch = util.clamp(ey * 2.2, -1, 1) * turn
    if dot < 0 then
        -- target is behind: commit to a full turn rather than dithering
        yaw = (ex >= 0 and 1 or -1) * turn
        pitch = (ey >= 0 and 1 or -1) * turn * 0.6
    end

    e.fwd:addScaled(e.right, yaw)
    e.fwd:addScaled(e.up, pitch)
    e.fwd:normalize()
    -- roll into the turn; it costs nothing and reads as piloting
    e.up:addScaled(e.right, -yaw * 0.7)
    mat4.orthonormalize(e.right, e.up, e.fwd)
    return dot
end

--- Applies thrust and drag toward the ship's throttle setting.
local function applyThrust(e, dt)
    local stats = e.stats
    local topSpeed = (stats.topSpeed or 500)
    local accel = config.flight.linearAccel * (stats.thrust or 1)
    local target = topSpeed * util.clamp(e.throttle, -0.4, 1)

    local vx, vy, vz = e.vel.x, e.vel.y, e.vel.z
    local forward = vx * e.fwd.x + vy * e.fwd.y + vz * e.fwd.z
    local delta = util.approach(forward, target, accel * dt)
    -- steer velocity toward the nose (flight assist), which is what makes
    -- NPC dogfights readable rather than Newtonian drifting
    local blend = 1 - math.exp(-2.4 * dt)
    e.vel.x = util.lerp(vx, e.fwd.x * delta, blend)
    e.vel.y = util.lerp(vy, e.fwd.y * delta, blend)
    e.vel.z = util.lerp(vz, e.fwd.z * delta, blend)

    e.pos.x = e.pos.x + e.vel.x * dt
    e.pos.y = e.pos.y + e.vel.y * dt
    e.pos.z = e.pos.z + e.vel.z * dt
end

-- ---------------------------------------------------------------------------
-- Behaviour
-- ---------------------------------------------------------------------------

local function pickTarget(e, ctx)
    local best, bestD = nil, CFG.aggroRange
    local player = ctx.playerShip
    if e.hostileToPlayer and player and not player.dead then
        local d = vec3.distance(e.pos, player.pos)
        if d < bestD then best, bestD = player, d end
    end
    for _, o in ipairs(ctx.npcs) do
        if o ~= e and not o.dead then
            local hostile = false
            if e.faction == "pirates" and o.faction ~= "pirates" then hostile = o.aiKind ~= "pirate"
            elseif o.faction == "pirates" and (e.aiKind == "police" or e.aiKind == "military" or e.aiKind == "hunter") then hostile = true
            elseif ctx.diplomacy and e.faction ~= o.faction then
                hostile = ctx.diplomacy:atWar(e.faction, o.faction)
            end
            if hostile then
                local d = vec3.distance(e.pos, o.pos)
                if d < bestD then best, bestD = o, d end
            end
        end
    end
    return best, bestD
end

local BEHAVIOUR = {}

BEHAVIOUR.cruise = function(e, dt, ctx)
    -- head for a destination, wandering a little so traffic is not a parade
    if not e.waypoint then
        local ports = ctx.ports
        if ports and #ports > 0 then
            -- A trader with a route, if the world can give it one.
            --
            -- This used to pick a port by the modulus of the ship's seed and
            -- fly there empty: traffic as scenery, with no effect on any
            -- price. `ctx.assignRun` hands back a real errand -- so much of
            -- that from here to there -- and arriving settles it against both
            -- markets, which is what makes a lane something a player can watch
            -- and something a pirate can cut.
            local p
            if e.aiKind == "trader" and ctx.assignRun then p = ctx.assignRun(e) end
            p = p or ports[(math.floor(e.seed) % #ports) + 1]
            e.waypoint = { x = p.pos.x, y = p.pos.y, z = p.pos.z }
            e.destPort = p
        else
            e.waypoint = { x = e.pos.x + e.fwd.x * 30000, y = e.pos.y + e.fwd.y * 30000, z = e.pos.z + e.fwd.z * 30000 }
            e.destPort = nil
        end
    end
    local t = ctx.time + e.wanderPhase
    local wob = 260
    steerTowards(e,
        e.waypoint.x + math.sin(t * 0.21) * wob,
        e.waypoint.y + math.sin(t * 0.17) * wob,
        e.waypoint.z + math.cos(t * 0.19) * wob, dt, 0.5)
    e.throttle = 0.75
    if vec3.distance(e.pos, e.waypoint) < 1200 then
        if e.destPort and ctx.arriveRun then ctx.arriveRun(e, e.destPort) end
        e.waypoint = nil
        e.destPort = nil
    end

    local target, dist = pickTarget(e, ctx)
    if target then
        if e.aiKind == "trader" or e.aiKind == "civilian" or e.aiKind == "miner" then
            e.target = target
            e.state = "flee"
        else
            e.target = target
            e.state = "attack"
        end
    end
end

BEHAVIOUR.patrol = BEHAVIOUR.cruise

BEHAVIOUR.attack = function(e, dt, ctx)
    local t = e.target
    if not t or t.dead then
        e.target, e.state = nil, "cruise"
        return
    end
    local ax, ay, az, dist = combat.leadTarget(e, t, (e.weapon and e.weapon.weapon.speed) or CFG.laserSpeed)
    if dist > CFG.aggroRange * 1.6 then
        e.target, e.state = nil, "cruise"
        return
    end

    -- break off when badly hurt
    if e.hull < e.maxHull * (0.22 + (1 - e.aggression) * 0.2) then
        e.state = "flee"
        return
    end

    local rate = 0.9 + e.skill * 0.9
    local alignment
    if dist < 340 then
        -- too close: slide past instead of grinding into the target
        alignment = steerTowards(e, t.pos.x + t.vel.x * 3, t.pos.y + t.vel.y * 3, t.pos.z + t.vel.z * 3, dt, rate)
        e.throttle = 1.0
    else
        alignment = steerTowards(e, ax, ay, az, dt, rate)
        e.throttle = util.clamp(0.35 + dist / 2600, 0.35, 1)
    end

    e.fireTimer = e.fireTimer - dt
    local w = e.weapon and e.weapon.weapon
    if w and alignment > (0.985 - e.skill * 0.02) and dist < CFG.laserRange and e.fireTimer <= 0 then
        e.fireTimer = 1 / (w.rate * (0.6 + e.skill * 0.5))
        local dx, dy, dz = ax - e.pos.x, ay - e.pos.y, az - e.pos.z
        local l = sqrt(dx * dx + dy * dy + dz * dz)
        if l > 1e-6 then
            -- imperfect aim, scaled by skill
            local spread = (1 - e.skill) * 0.02
            local jitter = Rng.new(e.seed or 1, "jitter", math.floor(ctx.time or 0))
            local rx = (jitter:float() - 0.5) * spread
            local ry = (jitter:float() - 0.5) * spread
            local fx = dx / l + e.right.x * rx + e.up.x * ry
            local fy = dy / l + e.right.y * rx + e.up.y * ry
            local fz = dz / l + e.right.z * rx + e.up.z * ry
            local fl = sqrt(fx * fx + fy * fy + fz * fz)
            combat.fire(ctx.arena, e, e.weapon, fx / fl, fy / fl, fz / fl, e.muzzle)
            e.muzzle = e.muzzle + 1
            if ctx.onFire then ctx.onFire(e) end
        end
    end
end

BEHAVIOUR.flee = function(e, dt, ctx)
    local t = e.target
    if not t or t.dead or vec3.distance(e.pos, t.pos) > CFG.aggroRange * 1.8 then
        e.target, e.state = nil, "cruise"
        return
    end
    steerTowards(e, e.pos.x * 2 - t.pos.x, e.pos.y * 2 - t.pos.y, e.pos.z * 2 - t.pos.z, dt, 0.9)
    e.throttle = 1.0
    -- a cornered trader will still shoot back
    local roll = Rng.new(e.seed or 1, "aggression", math.floor((ctx.time or 0) * 4)):float()
    if e.aiKind ~= "civilian" and e.hull > e.maxHull * 0.5 and roll < dt * 0.2 then
        e.state = "attack"
    end
end

BEHAVIOUR.mine = function(e, dt, ctx)
    -- `e.rock` was never assigned by anything, so this branch bailed out on its
    -- first line and every miner simply cruised. Miners now pick a rock out of
    -- the belt they are in and work it until it is spent.
    if not e.rock or (e.rock.health or 1) <= 0 then
        e.rock = ctx.pickRock and ctx.pickRock(e) or nil
        if not e.rock then
            e.state = "cruise"
            return
        end
    end
    steerTowards(e, e.rock.x, e.rock.y, e.rock.z, dt, 0.6)
    local d = sqrt((e.rock.x - e.pos.x) ^ 2 + (e.rock.y - e.pos.y) ^ 2 + (e.rock.z - e.pos.z) ^ 2)
    e.throttle = d > 400 and 0.6 or 0.05
    -- close enough to work: chip away, which is what makes a belt look busy
    if d < e.rock.radius * 3 and ctx.mineRock then
        e.mineTimer = (e.mineTimer or 0) - dt
        if e.mineTimer <= 0 then
            e.mineTimer = 0.6
            ctx.mineRock(e, e.rock)
        end
    end
end

-- ---------------------------------------------------------------------------

--- Advances every NPC.
function npc.update(list, dt, ctx)
    for i = 1, #list do
        local e = list[i]
        if not e.dead then
            local behaviour = BEHAVIOUR[e.state] or BEHAVIOUR.cruise
            behaviour(e, dt, ctx)
            applyThrust(e, dt)
            combat.regenerate(e, dt, e.stats)
            -- keep ships out of the ground when they are flying low
            if ctx.groundHeight then
                local h = ctx.groundHeight(e.pos.x, e.pos.y, e.pos.z)
                if h and h < e.radius * 2 then
                    local ux, uy, uz = ctx.upAt(e.pos.x, e.pos.y, e.pos.z)
                    local lift = (e.radius * 2 - h)
                    e.pos.x = e.pos.x + ux * lift
                    e.pos.y = e.pos.y + uy * lift
                    e.pos.z = e.pos.z + uz * lift
                    steerTowards(e, e.pos.x + ux * 900, e.pos.y + uy * 900, e.pos.z + uz * 900, dt, 1.2)
                end
            end
        end
    end
end

--- Makes everyone nearby of a faction react to the player attacking one of
--- their ships -- the "you shot a policeman" rule.
function npc.alert(list, factionId, radiusFrom, radius)
    for _, e in ipairs(list) do
        if not e.dead and e.faction == factionId then
            if vec3.distance(e.pos, radiusFrom) < (radius or 12000) then
                e.hostileToPlayer = true
                if e.aiKind ~= "civilian" and e.aiKind ~= "trader" then
                    e.state = "attack"
                end
            end
        end
    end
end

npc.MAX = MAX_NPCS
npc.SPAWN_RADIUS = SPAWN_RADIUS

return npc

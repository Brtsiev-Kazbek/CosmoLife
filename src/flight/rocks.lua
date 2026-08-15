-- Asteroids: the ones near the ship, the ore a mining bolt frees, and drawing
-- them.
--
-- The three belong together because they share the state nothing else touches:
-- `f.rocks` is the working set streamed in around the ship, and `f.rockDamage`
-- is the persistent record of how far each one has been chipped -- an asteroid
-- has to stay chipped when you fly away and come back, so the damage table
-- outlives the working set.
--
-- Like the other flight modules these take the flight state explicitly rather
-- than being methods on it; `states/flight.lua` keeps forwarding methods.

local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local mining = require("src.sim.mining")
local combat = require("src.sim.combat")
local commodities = require("src.sim.commodities")
local bodies = require("src.render.bodies")
local hud = require("src.render.hud")
local i18n = require("src.i18n")

local rocks = {}

local min, max = math.min, math.max
local L = i18n.format

--- The rock closest to a point, out of the ones currently streamed in.
--
-- This uses its own list rather than `f.rocks`: it is called by NPC mining AI
-- for ships that may be nowhere near the player, and reusing the player's
-- working set would have every miner in the system converge on whatever
-- asteroid happens to be next to the camera.
function rocks.near(f, pos)
    f.rockDamage = f.rockDamage or {}
    local list = mining.near(f.world.system, pos.x, pos.y, pos.z, f.rockDamage, f._npcRocks)
    f._npcRocks = list
    local best, bestD = nil, math.huge
    for _, r in ipairs(list) do
        local d = (r.x - pos.x) ^ 2 + (r.y - pos.y) ^ 2 + (r.z - pos.z) ^ 2
        if d < bestD then best, bestD = r, d end
    end
    return best
end

--- Mining bolts that reach a rock free ore into the hold.
--
-- combat.lua has tagged projectiles `p.mining` since the mining laser was
-- added; nothing read the tag, so the laser was a weapon that did less damage
-- than the cheapest gun and nothing else.
function rocks.updateMining(f)
    local list = f.rocks
    if not list or #list == 0 then return end
    local arena = f.arena
    for i = 1, arena.nProjectiles do
        local p = arena.projectiles[i]
        if p and p.life > 0 and p.mining and p.owner == f.ship then
            for _, r in ipairs(list) do
                local dx, dy, dz = p.pos.x - r.x, p.pos.y - r.y, p.pos.z - r.z
                if dx * dx + dy * dy + dz * dz < r.radius * r.radius then
                    local ore, tonnes = mining.hit(r, p.damage or 8, f.rockDamage)
                    -- expire the bolt; combat.update compacts the array
                    p.life = 0
                    combat.effect(arena, p.pos.x, p.pos.y, p.pos.z, r.radius * 0.12, "hit",
                        r.ore == "gems" and { 0.8, 0.9, 1.0 } or { 0.9, 0.75, 0.5 })
                    if ore and tonnes then
                        local free = f.player:cargoFree()
                        local taken = min(tonnes, free)
                        if taken > 0 then
                            f.player:addCargo(ore, taken)
                            local rec = f.player.record
                            rec.mined = (rec.mined or 0) + taken
                            hud.message(L("Mined {n} {n:t} of {cargo:gen:lc}", {
                                n = taken, cargo = i18n.term(commodities.get(ore).name) }), "good")
                        else
                            hud.message(L("Hold is full."), "warn")
                        end
                    end
                    break
                end
            end
        end
    end
end

--- Draws the asteroid field when the ship is inside a belt.
--
-- Belts have existed since the system generator was written and were never
-- rendered, so a "belt" was an invisible annulus that only affected which
-- NPCs spawned. bodies.asteroids() had no callers at all.
function rocks.submit(f, renderer)
    f.rockDamage = f.rockDamage or {}
    f.rocks = f.rocks or {}
    local ship = f.ship
    mining.near(f.world.system, ship.pos.x, ship.pos.y, ship.pos.z, f.rockDamage, f.rocks)
    if #f.rocks == 0 then return end

    local set = bodies.asteroids(f.world.system.seed)
    local basis = f._rockBasis or { right = vec3(), up = vec3(0, 1, 0), fwd = vec3() }
    f._rockBasis = basis
    local pos = f._rockPos or vec3()
    f._rockPos = pos

    for _, r in ipairs(f.rocks) do
        local a = r.phase + f.time * r.spin
        basis.right:set(math.cos(a), 0, -math.sin(a))
        basis.up:set(0, 1, 0)
        basis.fwd:set(-math.sin(a), 0, -math.cos(a))
        mat4.orthonormalize(basis.right, basis.up, basis.fwd)
        pos:set(r.x, r.y, r.z)
        -- a chipped rock is visibly smaller
        local wear = 0.55 + 0.45 * (r.health / max(r.maxHealth, 1))
        renderer:draw(set[r.variant], pos, basis, { scale = r.radius * wear })
    end
end

return rocks

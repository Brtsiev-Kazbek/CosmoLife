-- Cargo canisters.
--
-- A destroyed ship used to pay a bounty and leave nothing behind, so a fight
-- with a fat trader was worth less than the ammunition, and the "cargo ~4,200
-- cr" line the scanner printed about a target was a number that could never be
-- collected. Kills now spill their hold: a few canisters that drift away from
-- the wreck and can be scooped into yours.
--
-- Canisters are ordinary simulation objects, not a special case of anything.
-- They have a position, a drift, a lifetime, and a commodity with a tonnage,
-- which means the ordinary market sells them and the ordinary contraband rules
-- apply to what is inside.

local Rng = require("src.lib.rng")
local vec3 = require("src.lib.vec3")
local commodities = require("src.sim.commodities")

local salvage = {}

local sqrt, min, max, floor = math.sqrt, math.min, math.max, math.floor

--- How long a canister survives before it is lost, in seconds.  Long enough to
--- finish the fight and come back, short enough that a battlefield does not
--- accumulate forever.
salvage.LIFETIME = 240

--- How close the ship has to be to scoop, in metres.
salvage.SCOOP_RANGE = 260

--- Radius of a canister for drawing and for the pickup test.
salvage.RADIUS = 9

-- What a given class of ship is likely to be carrying.  A pirate is holding
-- what it took off somebody else, which is why its spread is the widest.
local MANIFEST = {
    trader    = { "grain", "provisions", "textiles", "medicine", "alloys",
                  "machinery", "computers", "luxuries" },
    hauler    = { "water", "grain", "ore", "minerals", "alloys", "hydrogen" },
    miner     = { "ore", "minerals", "raremetals", "gems" },
    pirate    = { "weapons", "narcotics", "luxuries", "medicine", "raremetals",
                  "computers", "artwork" },
    patrol    = { "weapons", "machinery", "medicine" },
    civilian  = { "provisions", "textiles", "water" },
}

--- Picks the commodities a wreck spills, deterministically from its seed.
function salvage.manifest(entity)
    local pool = MANIFEST[entity.aiKind] or MANIFEST.civilian
    local rng = Rng.new(entity.seed or 1, "salvage")
    -- value carried translates into tonnage: a rich hold is a heavy one, but
    -- an expensive commodity means fewer tonnes of it
    local value = max(entity.cargoValue or 0, 0)
    if value <= 0 then return {} end

    local out = {}
    local count = rng:int(1, 3)
    local share = value / count
    for _ = 1, count do
        local id = rng:pick(pool)
        local def = commodities.get(id)
        local base = (def and def.base) or 100
        -- only a fraction survives the explosion
        local tonnes = floor(share * rng:range(0.25, 0.55) / base)
        if tonnes >= 1 then
            out[#out + 1] = { id = id, tonnes = min(tonnes, 12) }
        end
    end
    return out
end

--- Spills a destroyed ship's hold into `list`.
function salvage.fromWreck(list, entity)
    local manifest = salvage.manifest(entity)
    local rng = Rng.new(entity.seed or 1, "salvage-throw")
    for _, item in ipairs(manifest) do
        local dx, dy, dz = rng:direction()
        local speed = rng:range(6, 26)
        list[#list + 1] = {
            id = item.id,
            tonnes = item.tonnes,
            pos = vec3(entity.pos.x + dx * entity.radius,
                       entity.pos.y + dy * entity.radius,
                       entity.pos.z + dz * entity.radius),
            vel = vec3((entity.vel and entity.vel.x or 0) + dx * speed,
                       (entity.vel and entity.vel.y or 0) + dy * speed,
                       (entity.vel and entity.vel.z or 0) + dz * speed),
            life = salvage.LIFETIME,
            spin = rng:range(0, math.pi * 2),
            spinRate = rng:range(-1.1, 1.1),
            radius = salvage.RADIUS,
        }
    end
    return #manifest
end

--- Drifts canisters and retires the ones that have timed out.
function salvage.update(list, dt)
    local n = #list
    local w = 0
    for i = 1, n do
        local c = list[i]
        c.life = c.life - dt
        if c.life > 0 then
            c.pos.x = c.pos.x + c.vel.x * dt
            c.pos.y = c.pos.y + c.vel.y * dt
            c.pos.z = c.pos.z + c.vel.z * dt
            c.spin = c.spin + c.spinRate * dt
            w = w + 1
            list[w] = c
        end
    end
    for i = n, w + 1, -1 do list[i] = nil end
    return w
end

--- The nearest canister within `maxDist`, and its distance.
function salvage.nearest(list, x, y, z, maxDist)
    maxDist = maxDist or salvage.SCOOP_RANGE
    local best, bestD = nil, maxDist * maxDist
    for i = 1, #list do
        local c = list[i]
        local dx, dy, dz = c.pos.x - x, c.pos.y - y, c.pos.z - z
        local d = dx * dx + dy * dy + dz * dz
        if d < bestD then best, bestD = c, d end
    end
    if not best then return nil end
    return best, sqrt(bestD)
end

--- Moves a canister into the hold.
--
-- Returns the commodity id and the tonnes taken, or nil plus a reason. A
-- partial scoop is allowed: taking six of the eight tonnes on offer leaves the
-- canister there with two in it, which is better than refusing outright.
function salvage.scoop(list, canister, player)
    local free = player:cargoFree()
    if free <= 0 then return nil, "full" end
    local taken = min(canister.tonnes, free)
    player:addCargo(canister.id, taken)
    canister.tonnes = canister.tonnes - taken
    if canister.tonnes <= 0 then
        for i = 1, #list do
            if list[i] == canister then table.remove(list, i) break end
        end
    end
    return canister.id, taken
end

return salvage

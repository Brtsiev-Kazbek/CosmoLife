-- Outfitting.
--
-- Modules are pure data with a `apply(stats)` hook, so adding a new piece of
-- kit never means touching the flight or combat code: it just edits the
-- derived stat block the ship is flown with.

local equipment = {}

equipment.slots = { "weapon", "shield", "engine", "utility", "cargo" }

equipment.list = {
    -- weapons ------------------------------------------------------------
    { id = "pulse1", slot = "weapon", name = "Pulse Laser I", tech = 1, price = 4200,
      blurb = "Cheap, reliable, unimpressive.",
      weapon = { damage = 9, rate = 4.2, energy = 1.6, speed = 2600, color = { 1.0, 0.55, 0.25 } } },
    { id = "pulse2", slot = "weapon", name = "Pulse Laser II", tech = 4, price = 13500,
      blurb = "The same gun after somebody competent tuned it.",
      weapon = { damage = 16, rate = 4.6, energy = 2.2, speed = 2900, color = { 1.0, 0.62, 0.3 } } },
    { id = "beam", slot = "weapon", name = "Beam Laser", tech = 7, price = 46000,
      blurb = "Continuous fire, brutal on the power plant.",
      weapon = { damage = 34, rate = 1.6, energy = 5.5, speed = 3600, beam = true, color = { 0.5, 0.9, 1.0 } } },
    { id = "cannon", slot = "weapon", name = "Multi-Cannon", tech = 5, price = 28000,
      blurb = "Kinetic rounds. Shrugs off shield resistance.",
      weapon = { damage = 21, rate = 6.5, energy = 0.9, speed = 2200, kinetic = true, color = { 1.0, 0.9, 0.6 } } },
    { id = "plasma", slot = "weapon", name = "Plasma Accelerator", tech = 10, price = 138000,
      blurb = "One shot, one very large hole.",
      weapon = { damage = 92, rate = 0.8, energy = 9, speed = 1700, color = { 0.8, 0.5, 1.0 } } },
    { id = "mining", slot = "weapon", name = "Mining Laser", tech = 2, price = 8600,
      blurb = "Cracks ore out of rock. Poor against hulls.",
      weapon = { damage = 5, rate = 3, energy = 1.4, speed = 1800, mining = true, color = { 1.0, 0.75, 0.2 } } },

    -- shields ------------------------------------------------------------
    { id = "shield1", slot = "shield", name = "Deflector I", tech = 1, price = 6500,
      blurb = "Standard issue bubble.", apply = function(s) s.maxShield = s.maxShield + 60 end },
    { id = "shield2", slot = "shield", name = "Deflector II", tech = 5, price = 24000,
      blurb = "Twice the capacity, twice the mass.",
      apply = function(s) s.maxShield = s.maxShield + 180; s.mass = s.mass + 40 end },
    { id = "shield3", slot = "shield", name = "Prismatic Deflector", tech = 9, price = 96000,
      blurb = "Conclave design. Recharges while you are still being shot at.",
      apply = function(s) s.maxShield = s.maxShield + 380; s.shieldRecharge = s.shieldRecharge * 1.6; s.mass = s.mass + 70 end },
    { id = "armour", slot = "shield", name = "Composite Plating", tech = 3, price = 18000,
      blurb = "No field, just more ship between you and them.",
      apply = function(s) s.maxHull = s.maxHull * 1.45; s.mass = s.mass + 120; s.agility = s.agility * 0.9 end },

    -- engines ------------------------------------------------------------
    { id = "thrust1", slot = "engine", name = "Drive Tune", tech = 2, price = 9000,
      blurb = "More thrust, more heat.",
      apply = function(s) s.thrust = s.thrust * 1.25; s.heatCapacity = s.heatCapacity * 0.9 end },
    { id = "thrust2", slot = "engine", name = "Military Drives", tech = 6, price = 42000,
      blurb = "Dominion surplus. Loud.",
      apply = function(s) s.thrust = s.thrust * 1.55; s.agility = s.agility * 1.2; s.mass = s.mass + 30 end },
    { id = "fsd1", slot = "engine", name = "Extended Jump Coils", tech = 4, price = 31000,
      blurb = "Longer hyperspace reach.",
      apply = function(s) s.jumpRange = s.jumpRange * 1.35 end },
    { id = "fsd2", slot = "engine", name = "Frontier Jump Array", tech = 8, price = 128000,
      blurb = "For people who intend to leave the map.",
      apply = function(s) s.jumpRange = s.jumpRange * 1.85; s.mass = s.mass + 50 end },

    -- utility ------------------------------------------------------------
    { id = "scoop", slot = "utility", name = "Fuel Scoop", tech = 5, price = 22000,
      blurb = "Refuels from a star's corona. Watch the heat.",
      apply = function(s) s.fuelScoop = true end },
    { id = "scanner", slot = "utility", name = "Deep Scanner", tech = 4, price = 16000,
      blurb = "Doubles scan range and reveals cargo manifests.",
      apply = function(s) s.scanRange = (s.scanRange or 9000) * 2 end },
    { id = "cloak", slot = "utility", name = "Signal Dampener", tech = 10, price = 210000,
      blurb = "Syndicate hardware. Customs officers dislike it.",
      apply = function(s) s.stealth = 0.65 end, illegal = true },
    { id = "repairbot", slot = "utility", name = "Repair Drones", tech = 7, price = 58000,
      blurb = "Slowly rebuilds hull outside combat.",
      apply = function(s) s.hullRepair = 1.4 end },
    { id = "colonykit", slot = "utility", name = "Colony Foundation Kit", tech = 6, price = 74000,
      blurb = "Everything needed to plant a settlement, except the people.",
      apply = function(s) s.colonyKit = true end },
    { id = "shieldcell", slot = "utility", name = "Shield Cell Bank", tech = 6, price = 34000,
      blurb = "Emergency shield recharge, four charges.",
      apply = function(s) s.shieldCells = (s.shieldCells or 0) + 4 end },

    -- cargo --------------------------------------------------------------
    { id = "rack1", slot = "cargo", name = "Cargo Rack +8", tech = 1, price = 5200,
      blurb = "Eight more tonnes.", apply = function(s) s.cargo = s.cargo + 8 end },
    { id = "rack2", slot = "cargo", name = "Cargo Rack +24", tech = 4, price = 17500,
      blurb = "Serious hauling.", apply = function(s) s.cargo = s.cargo + 24; s.mass = s.mass + 40 end },
    { id = "rack3", slot = "cargo", name = "Cargo Rack +64", tech = 7, price = 52000,
      blurb = "You are a warehouse that moves.",
      apply = function(s) s.cargo = s.cargo + 64; s.mass = s.mass + 110; s.agility = s.agility * 0.92 end },
    { id = "hiddenhold", slot = "cargo", name = "Concealed Hold", tech = 6, price = 68000,
      blurb = "Twelve tonnes that a routine scan does not find.",
      apply = function(s) s.cargo = s.cargo + 12; s.smuggleSpace = 12 end, illegal = true },
}

equipment.byId = {}
for _, e in ipairs(equipment.list) do equipment.byId[e.id] = e end

function equipment.get(id) return equipment.byId[id] end

--- Everything a station of this tech level stocks.
function equipment.available(techLevel, allowIllegal)
    local out = {}
    for _, e in ipairs(equipment.list) do
        if e.tech <= (techLevel or 6) and (allowIllegal or not e.illegal) then
            out[#out + 1] = e
        end
    end
    return out
end

--- Applies a list of installed module ids to a base stat block.
-- Returns a new table; the base is never mutated.
function equipment.derive(baseStats, installed)
    local s = {}
    for k, v in pairs(baseStats) do s[k] = v end
    s.maxShield = s.maxShield or s.shield or 0
    s.maxHull = s.maxHull or s.hull or 100
    for _, id in ipairs(installed or {}) do
        local e = equipment.byId[id]
        if e and e.apply then e.apply(s) end
    end
    -- mass penalties feed back into handling
    local massFactor = 1 / (1 + math.max(0, s.mass - 400) / 4200)
    s.thrust = s.thrust * massFactor
    s.agility = s.agility * massFactor
    return s
end

--- The active weapon definition for a loadout (first weapon module fitted).
function equipment.activeWeapon(installed)
    for _, id in ipairs(installed or {}) do
        local e = equipment.byId[id]
        if e and e.slot == "weapon" then return e end
    end
    return equipment.byId.pulse1
end

return equipment

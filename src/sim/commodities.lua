-- The commodity table and the economy archetypes that consume and produce it.
--
-- Prices are never stored globally: a market computes its own price from local
-- stock versus local demand, so profit comes from knowing which archetype
-- needs what.  That is the whole game loop of the original, kept intact.

local commodities = {}

--- category   grouping for the market UI
--- base       reference price in credits per unit
--- volume     cargo space per unit
--- volatility how far the price wanders day to day
--- legality   "legal" | "restricted" (illegal in high-law systems) | "illegal"
--- perishable decays in the hold and in warehouses
commodities.list = {
    { id = "water",        name = "Water",            category = "food",     base = 18,   volume = 1, volatility = 0.05, legality = "legal" },
    { id = "grain",        name = "Grain",            category = "food",     base = 44,   volume = 1, volatility = 0.11, legality = "legal", perishable = 0.02 },
    { id = "provisions",   name = "Provisions",       category = "food",     base = 126,  volume = 1, volatility = 0.09, legality = "legal", perishable = 0.015 },
    { id = "livestock",    name = "Livestock",        category = "food",     base = 214,  volume = 1, volatility = 0.16, legality = "legal", perishable = 0.03 },
    { id = "textiles",     name = "Textiles",         category = "consumer", base = 98,   volume = 1, volatility = 0.08, legality = "legal" },
    { id = "medicine",     name = "Medicine",         category = "consumer", base = 486,  volume = 1, volatility = 0.14, legality = "legal", perishable = 0.01 },
    { id = "luxuries",     name = "Luxuries",         category = "consumer", base = 964,  volume = 1, volatility = 0.18, legality = "legal" },
    { id = "artwork",      name = "Artwork",          category = "consumer", base = 1620, volume = 1, volatility = 0.26, legality = "legal" },
    { id = "ore",          name = "Raw Ore",          category = "raw",      base = 56,   volume = 1, volatility = 0.10, legality = "legal" },
    { id = "minerals",     name = "Minerals",         category = "raw",      base = 132,  volume = 1, volatility = 0.12, legality = "legal" },
    { id = "raremetals",   name = "Rare Metals",      category = "raw",      base = 638,  volume = 1, volatility = 0.20, legality = "legal" },
    { id = "gems",         name = "Gemstones",        category = "raw",      base = 1810, volume = 1, volatility = 0.24, legality = "legal" },
    { id = "hydrogen",     name = "Hydrogen Fuel",    category = "energy",   base = 34,   volume = 1, volatility = 0.07, legality = "legal" },
    { id = "deuterium",    name = "Deuterium",        category = "energy",   base = 148,  volume = 1, volatility = 0.13, legality = "legal" },
    { id = "alloys",       name = "Structural Alloy", category = "industry", base = 268,  volume = 1, volatility = 0.09, legality = "legal" },
    { id = "machinery",    name = "Machinery",        category = "industry", base = 392,  volume = 1, volatility = 0.10, legality = "legal" },
    { id = "computers",    name = "Computers",        category = "tech",     base = 742,  volume = 1, volatility = 0.15, legality = "legal" },
    { id = "robotics",     name = "Robotics",         category = "tech",     base = 1180, volume = 1, volatility = 0.17, legality = "legal" },
    { id = "supercond",    name = "Superconductors",  category = "tech",     base = 1440, volume = 1, volatility = 0.19, legality = "legal" },
    { id = "terrakit",     name = "Terraform Kit",    category = "tech",     base = 2680, volume = 2, volatility = 0.12, legality = "legal" },
    { id = "colonists",    name = "Colonists",        category = "people",   base = 660,  volume = 1, volatility = 0.10, legality = "legal" },
    { id = "weapons",      name = "Small Arms",       category = "arms",     base = 1320, volume = 1, volatility = 0.22, legality = "restricted" },
    { id = "narcotics",    name = "Narcotics",        category = "illicit",  base = 2140, volume = 1, volatility = 0.32, legality = "illegal" },
    { id = "captives",     name = "Indentured",       category = "illicit",  base = 1880, volume = 1, volatility = 0.28, legality = "illegal" },
}

commodities.byId = {}
commodities.order = {}
for i, c in ipairs(commodities.list) do
    c.index = i
    commodities.byId[c.id] = c
    commodities.order[i] = c.id
end

function commodities.get(id)
    local c = commodities.byId[id]
    if not c then error("unknown commodity: " .. tostring(id), 2) end
    return c
end

commodities.categoryNames = {
    food = "Foodstuffs", consumer = "Consumer Goods", raw = "Raw Materials",
    energy = "Fuels", industry = "Industrial", tech = "Technology",
    people = "Passengers", arms = "Armaments", illicit = "Contraband",
}

-- ---------------------------------------------------------------------------
-- Economy archetypes.
--
-- `produces` and `consumes` are multipliers on the local baseline flow.  A
-- world that produces something has surplus stock and low prices; a world that
-- consumes it runs dry and pays well.
-- ---------------------------------------------------------------------------
commodities.economies = {
    {
        id = "agricultural", name = "Agricultural", tech = -0.2,
        produces = { grain = 3.0, provisions = 2.0, livestock = 2.4, water = 1.6, textiles = 1.4 },
        consumes = { machinery = 1.8, robotics = 1.2, medicine = 1.2, alloys = 1.1, computers = 0.9 },
    },
    {
        id = "extraction", name = "Extraction", tech = -0.1,
        produces = { ore = 3.2, minerals = 2.6, raremetals = 1.5, gems = 0.9, hydrogen = 1.2 },
        consumes = { machinery = 2.2, provisions = 2.0, medicine = 1.5, computers = 1.0, weapons = 0.8 },
    },
    {
        id = "refinery", name = "Refinery", tech = 0.05,
        produces = { alloys = 3.0, deuterium = 2.0, hydrogen = 2.2, machinery = 1.2 },
        consumes = { ore = 3.0, minerals = 2.2, provisions = 1.4, robotics = 1.1 },
    },
    {
        id = "industrial", name = "Industrial", tech = 0.15,
        produces = { machinery = 2.8, computers = 1.6, alloys = 1.8, robotics = 1.3, weapons = 1.2 },
        consumes = { ore = 2.4, alloys = 1.4, provisions = 2.0, grain = 1.4, raremetals = 1.6 },
    },
    {
        id = "hightech", name = "High Technology", tech = 0.45,
        produces = { computers = 2.8, robotics = 2.4, supercond = 2.2, medicine = 1.8, terrakit = 1.4 },
        consumes = { raremetals = 2.6, gems = 1.4, provisions = 1.8, grain = 1.6, alloys = 1.5 },
    },
    {
        id = "service", name = "Service", tech = 0.2,
        produces = { luxuries = 1.8, artwork = 1.5, medicine = 1.2 },
        consumes = { provisions = 2.2, livestock = 1.6, textiles = 1.6, computers = 1.2, water = 1.4 },
    },
    {
        id = "military", name = "Military", tech = 0.3,
        produces = { weapons = 2.6, alloys = 1.2 },
        consumes = { machinery = 1.8, computers = 1.6, provisions = 2.4, medicine = 1.8, supercond = 1.4 },
    },
    {
        id = "terraforming", name = "Terraforming", tech = 0.25,
        produces = { water = 1.6 },
        consumes = { terrakit = 3.0, machinery = 2.2, colonists = 2.0, robotics = 1.6, provisions = 1.8 },
    },
    {
        id = "colony", name = "Frontier Colony", tech = -0.3,
        produces = { ore = 1.4, minerals = 1.2 },
        consumes = { provisions = 2.6, machinery = 2.0, medicine = 2.0, colonists = 1.8, weapons = 1.2, textiles = 1.3 },
    },
    {
        id = "tourism", name = "Tourism", tech = 0.1,
        produces = { luxuries = 1.2, artwork = 1.1 },
        consumes = { provisions = 2.4, luxuries = 1.4, water = 1.8, livestock = 1.4 },
    },
}

commodities.economyById = {}
for _, e in ipairs(commodities.economies) do commodities.economyById[e.id] = e end

function commodities.economy(id)
    return commodities.economyById[id] or commodities.economies[1]
end

--- Legality of a commodity in a given system.
-- Returns "legal", "restricted" or "illegal" together with the fine multiplier.
function commodities.legalityIn(commodity, lawLevel)
    local c = type(commodity) == "table" and commodity or commodities.get(commodity)
    if c.legality == "legal" then return "legal", 0 end
    if c.legality == "restricted" then
        if lawLevel > 0.6 then return "illegal", 0.5 end
        return "legal", 0
    end
    if lawLevel < 0.25 then return "restricted", 0.2 end
    return "illegal", 1
end

return commodities

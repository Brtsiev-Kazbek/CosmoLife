-- Procedural naming.
--
-- Star systems use the trick the original Elite used: a table of two letter
-- digrams sampled by the system seed.  It produces pronounceable, faintly
-- alien names ("Lave", "Zaonce", "Tionisla") from almost no data.  Everything
-- else -- people, ships, corporations, settlements -- is assembled from small
-- word banks so that a name always carries a little information about what it
-- labels.

local Rng = require("src.lib.rng")

local names = {}

local DIGRAMS = {
    "ab", "ou", "se", "it", "ed", "or", "ve", "xe", "za", "ce", "bi", "so",
    "us", "es", "ar", "ma", "in", "di", "re", "a", "er", "at", "en", "be",
    "ra", "la", "vi", "ti", "qu", "on", "el", "an", "ge", "ne", "il", "ec",
    "te", "is", "ri", "on", "za", "le", "us", "sa", "ta", "ri", "ka", "on",
}

local SUFFIX = { "", "", "", "", " Prime", " Secundus", " Major", " Minor", " II", " III", " IV", " IX", " Reach", " Gate", " Rift" }

--- A star system name.  `length` is drawn from the seed so names vary.
function names.system(seed)
    local rng = Rng.new(seed, "system-name")
    local parts = rng:int(2, 4)
    local s = {}
    for _ = 1, parts do s[#s + 1] = rng:pick(DIGRAMS) end
    local name = table.concat(s)
    name = name:sub(1, 1):upper() .. name:sub(2)
    if rng:bool(0.16) then name = name .. rng:pick(SUFFIX) end
    return name
end

local GREEK = { "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Mu" }
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" }

--- Planets are named after their star, catalogue style.
function names.planet(systemName, index)
    return systemName .. " " .. (ROMAN[index] or tostring(index))
end

function names.moon(planetName, index)
    return planetName .. (index == 1 and "a" or string.char(96 + index))
end

function names.belt(systemName, index)
    return systemName .. " " .. (GREEK[index] or "Omega") .. " Belt"
end

local STATION_PREFIX = {
    "Port", "Station", "Terminal", "Depot", "Anchorage", "Waypoint", "Hub",
    "Outpost", "Dock", "Relay", "Keep", "Bastion",
}
local STATION_NAMES = {
    "Kepler", "Hakim", "Novak", "Oyelaran", "Bright", "Sorensen", "Ibarra",
    "Vaduva", "Amundsen", "Chen", "Okonkwo", "Reyes", "Lindqvist", "Farid",
    "Tsiolkovsky", "Mbeki", "Halden", "Vega", "Corvus", "Meridian", "Solace",
    "Ashfall", "Longhaul", "Ironside", "Quiet Harbour", "Last Light", "Coldstart",
}

function names.station(seed)
    local rng = Rng.new(seed, "station")
    if rng:bool(0.55) then
        return rng:pick(STATION_NAMES) .. " " .. rng:pick(STATION_PREFIX)
    end
    return rng:pick(STATION_PREFIX) .. " " .. rng:pick(STATION_NAMES)
end

local SETTLEMENT_ROOT = {
    "New", "Old", "Fort", "Camp", "Mount", "Port", "Cape", "Lower", "Upper", "North", "South",
}
local SETTLEMENT_BODY = {
    "Haven", "Landing", "Crossing", "Furnace", "Anvil", "Hollow", "Ridge", "Basin",
    "Prospect", "Quarry", "Terrace", "Beacon", "Refuge", "Foundry", "Garden",
    "Spire", "Cistern", "Threshold", "Verge", "Salvation", "Endeavour", "Redoubt",
}

function names.settlement(seed)
    local rng = Rng.new(seed, "settlement")
    if rng:bool(0.4) then
        return rng:pick(SETTLEMENT_ROOT) .. " " .. rng:pick(SETTLEMENT_BODY)
    end
    return rng:pick(SETTLEMENT_BODY) .. " " .. rng:pick({ "Station", "Colony", "Works", "Post", "Fields", "Yards", "Point" })
end

local FIRST = {
    "Ada", "Ines", "Kai", "Noor", "Rina", "Sol", "Tam", "Vela", "Yusuf", "Zora",
    "Bram", "Cato", "Dara", "Esen", "Faye", "Goran", "Halim", "Ivo", "Juno",
    "Kesi", "Lars", "Mira", "Nika", "Oren", "Pia", "Rhea", "Suri", "Teo", "Uma",
}
local LAST = {
    "Achebe", "Bardem", "Coelho", "Duarte", "Eriksen", "Fontaine", "Gustafsson",
    "Hollis", "Ivanova", "Jarrah", "Kovacs", "Lindholm", "Moreau", "Nakamura",
    "Okafor", "Petrov", "Quintero", "Rasmussen", "Sato", "Tanaka", "Ueda",
    "Volkov", "Weiss", "Xu", "Yilmaz", "Zeleny",
}

function names.person(seed)
    local rng = Rng.new(seed, "person")
    return rng:pick(FIRST) .. " " .. rng:pick(LAST)
end

local CORP_A = { "Vector", "Helios", "Onyx", "Kestrel", "Tessera", "Orbital", "Iron", "Meridian", "Cobalt", "Quartz", "Aster", "Halcyon" }
local CORP_B = { "Dynamics", "Combine", "Freight", "Holdings", "Industries", "Mining", "Logistics", "Foundry", "Salvage", "Shipwrights", "Agritech", "Sciences" }

function names.company(seed)
    local rng = Rng.new(seed, "company")
    return rng:pick(CORP_A) .. " " .. rng:pick(CORP_B)
end

local SHIP_A = { "Silent", "Iron", "Red", "Distant", "Broken", "Patient", "Wandering", "Cold", "Bright", "Second", "Blind", "Hollow" }
local SHIP_B = { "Vagrant", "Promise", "Meridian", "Answer", "Errand", "Custom", "Verdict", "Anchor", "Compass", "Lantern", "Debt", "Migration" }

function names.ship(seed)
    local rng = Rng.new(seed, "ship")
    return rng:pick(SHIP_A) .. " " .. rng:pick(SHIP_B)
end

return names

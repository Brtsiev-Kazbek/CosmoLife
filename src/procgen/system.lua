-- Star system contents.
--
-- A galaxy stub carries only the "front page" of a system.  This module
-- expands one into the actual bodies: the star, its planets and moons, belts,
-- orbital stations and the settlements scattered over habitable surfaces.
-- Everything derives from the stub's seed, so a system regenerates identically
-- every time it is entered and only mutable state (market stock, colony
-- growth, destroyed ships) has to be saved.
--
-- Orbits are computed analytically from the world clock rather than
-- integrated, which means a system can be entered at day 900 without having
-- simulated the 899 days before it.

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local config = require("src.config")
local names = require("src.procgen.names")
local commodities = require("src.sim.commodities")
local factions = require("src.sim.factions")

local system = {}

local S = config.scale
local TAU = math.pi * 2

local PLANET_TYPES = {
    { id = "rock",     name = "Rocky",           terrain = "barren",   atmos = 0.0,  weight = 22 },
    { id = "terran",   name = "Terrestrial",     terrain = "terran",   atmos = 1.0,  weight = 9, habitable = true },
    { id = "desert",   name = "Desert",          terrain = "desert",   atmos = 0.55, weight = 13, habitable = true },
    { id = "ocean",    name = "Ocean",           terrain = "ocean",    atmos = 1.1,  weight = 6, habitable = true },
    { id = "ice",      name = "Ice",             terrain = "ice",      atmos = 0.25, weight = 14 },
    { id = "volcanic", name = "Volcanic",        terrain = "volcanic", atmos = 0.7,  weight = 8 },
    { id = "toxic",    name = "Toxic Greenhouse", terrain = "toxic",   atmos = 1.6,  weight = 9 },
    { id = "gas",      name = "Gas Giant",       terrain = nil,        atmos = 3.0,  weight = 16, giant = true },
    { id = "ice_giant", name = "Ice Giant",      terrain = nil,        atmos = 2.4,  weight = 7, giant = true },
}

local STATION_KINDS = {
    { id = "coriolis", name = "Coriolis", weight = 30, pads = 8, size = 900 },
    { id = "torus",    name = "Ring",     weight = 18, pads = 12, size = 1500 },
    { id = "drum",     name = "Drum",     weight = 22, pads = 6, size = 700 },
    { id = "outpost",  name = "Outpost",  weight = 30, pads = 2, size = 220 },
}

-- ---------------------------------------------------------------------------

local function pickWeighted(rng, list, filter)
    local total = 0
    for _, e in ipairs(list) do
        if not filter or filter(e) then total = total + e.weight end
    end
    if total <= 0 then return list[1] end
    local r = rng:float() * total
    for _, e in ipairs(list) do
        if not filter or filter(e) then
            r = r - e.weight
            if r <= 0 then return e end
        end
    end
    return list[#list]
end

--- Rough surface temperature, used to bias planet types by orbit.
local function equilibriumTemp(luminosity, orbitM)
    local au = orbitM / S.au
    return 278 * (luminosity ^ 0.25) / math.sqrt(math.max(au, 0.01))
end

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

--- Expands a galaxy stub into a full system description.
-- `day` is the world clock; orbital phases are evaluated from it.
function system.build(stub, diplomacy, day)
    local rng = Rng.new(stub.seed, "system")
    local star = stub.star

    local conflict = 0
    if diplomacy then
        conflict = diplomacy:systemConflict(stub.factionId, stub.neighbourFactionId, stub.frontier)
    end

    local sys = {
        stub = stub,
        id = stub.id,
        seed = stub.seed,
        name = stub.name,
        factionId = stub.factionId,
        lawLevel = stub.lawLevel,
        techLevel = stub.techLevel,
        population = stub.population,
        economyId = stub.economyId,
        wealth = stub.wealth,
        conflict = conflict,
        bodies = {},
        stations = {},
        settlements = {},
        belts = {},
        day = day or 0,
    }

    -- ---- the star -------------------------------------------------------
    local starRadius = util.clamp(S.starRadiusMin * star.radius * rng:range(0.85, 1.2),
                                  4e7, 1.4e9)
    sys.star = {
        kind = "star",
        name = stub.name,
        class = star.class,
        color = star.color,
        radius = starRadius,
        luminosity = star.lum,
        temp = star.temp,
        pos = { x = 0, y = 0, z = 0 },
        mass = star.lum ^ 0.25,
    }
    sys.bodies[1] = sys.star

    -- ---- planets --------------------------------------------------------
    local planetCount = rng:int(0, 7)
    if star.brown or star.dwarf then planetCount = rng:int(0, 3) end
    if star.neutron then planetCount = rng:int(0, 2) end
    if stub.population > 100000 then planetCount = math.max(planetCount, 2) end

    local orbit = S.orbitMin * rng:range(0.8, 1.5) * (1 + star.lum * 0.05)
    local totalPop = stub.population
    local habitableIndex = nil

    for i = 1, planetCount do
        local prng = rng:derive("planet", i)
        local temp = equilibriumTemp(star.lum, orbit)

        local ptype = pickWeighted(prng, PLANET_TYPES, function(t)
            if t.giant then return orbit > S.orbitMin * 3 end
            if t.id == "ice" then return temp < 240 end
            if t.id == "volcanic" then return temp > 380 end
            if t.id == "ocean" or t.id == "terran" then return temp > 240 and temp < 330 end
            if t.id == "desert" then return temp > 250 and temp < 420 end
            if t.id == "toxic" then return temp > 300 end
            return true
        end)

        local radius
        if ptype.giant then
            radius = prng:range(S.planetRadiusMax * 2.2, S.planetRadiusMax * 5.5)
        else
            radius = prng:range(S.planetRadiusMin, S.planetRadiusMax)
        end

        local body = {
            kind = "planet",
            index = i,
            name = names.planet(stub.name, i),
            seed = Rng.hash(stub.seed, "planet", i),
            type = ptype.id,
            typeName = ptype.name,
            terrain = ptype.terrain,
            giant = ptype.giant or false,
            landable = (not ptype.giant),
            radius = radius,
            mass = radius / 6.37e6,                     -- Earth masses, roughly
            gravity = util.clamp(9.81 * (radius / 6.37e6) ^ 0.9, 0.4, 24),
            atmosphere = ptype.atmos * prng:range(0.7, 1.35),
            temperature = temp,
            orbitRadius = orbit,
            orbitPeriod = S.orbitPeriodBase * math.sqrt((orbit / S.orbitMin) ^ 3) * prng:range(0.85, 1.2),
            orbitPhase = prng:range(0, TAU),
            orbitInclination = prng:gauss(0, 0.05),
            dayLength = S.dayLengthBase * prng:range(0.7, 2.6),
            axialTilt = prng:range(-0.42, 0.42),
            rotationPhase = prng:range(0, TAU),
            hasRings = ptype.giant and prng:bool(0.45) or prng:bool(0.06),
            moons = {},
            pos = { x = 0, y = 0, z = 0 },
        }
        body.escapeVelocity = math.sqrt(2 * body.gravity * body.radius)

        -- ---- moons ------------------------------------------------------
        local moonCount = 0
        if ptype.giant then moonCount = prng:int(0, 5)
        elseif radius > S.planetRadiusMin * 2 then moonCount = prng:int(0, 2) end
        local morbit = body.radius * prng:range(6, 12)
        for m = 1, moonCount do
            local mrng = prng:derive("moon", m)
            local mradius = mrng:range(S.moonRadiusMin, math.min(S.moonRadiusMax, radius * 0.4))
            body.moons[m] = {
                kind = "moon",
                index = m,
                parent = body,
                name = names.moon(body.name, m),
                seed = Rng.hash(body.seed, "moon", m),
                type = mrng:bool(0.6) and "rock" or "ice",
                terrain = mrng:bool(0.6) and "barren" or "ice",
                landable = true,
                radius = mradius,
                gravity = util.clamp(9.81 * (mradius / 6.37e6) ^ 0.9, 0.15, 4),
                atmosphere = mrng:bool(0.15) and mrng:range(0.05, 0.3) or 0,
                temperature = temp,
                orbitRadius = morbit,
                orbitPeriod = S.orbitPeriodBase * 0.03 * math.sqrt((morbit / (body.radius * 6)) ^ 3) * mrng:range(0.8, 1.3),
                orbitPhase = mrng:range(0, TAU),
                orbitInclination = mrng:gauss(0, 0.12),
                dayLength = S.dayLengthBase * mrng:range(1.5, 6),
                axialTilt = mrng:range(-0.2, 0.2),
                rotationPhase = mrng:range(0, TAU),
                moons = {},
                pos = { x = 0, y = 0, z = 0 },
            }
            morbit = morbit * mrng:range(1.4, 2.1)
        end

        if ptype.habitable and not habitableIndex then habitableIndex = i end
        sys.bodies[#sys.bodies + 1] = body

        orbit = orbit * rng:range(1.5, 2.3)
        if orbit > S.orbitMax then break end
    end

    -- ---- asteroid belts -------------------------------------------------
    local beltCount = rng:int(0, 2)
    for i = 1, beltCount do
        local brng = rng:derive("belt", i)
        local r = brng:range(S.orbitMin * 1.5, S.orbitMax * 0.8)
        sys.belts[i] = {
            kind = "belt",
            name = names.belt(stub.name, i),
            seed = Rng.hash(stub.seed, "belt", i),
            radius = r,
            width = r * brng:range(0.04, 0.12),
            thickness = r * brng:range(0.004, 0.02),
            density = brng:range(0.4, 1.0),
            richness = brng:range(0.3, 1.0),
        }
    end

    system._placeStations(sys, rng, stub, day)
    system._placeSettlements(sys, rng, stub, day)
    system.updateOrbits(sys, day or 0)
    return sys
end

--- Orbital stations: the main docking points and the economic hubs.
function system._placeStations(sys, rng, stub, day)
    if stub.population <= 0 then
        -- even dead systems sometimes have a derelict or a smuggler's rock
        if rng:bool(0.18) then
            local host = system._pickHost(sys, rng)
            if host then
                sys.stations[1] = system._makeStation(sys, rng:derive("st", 1), stub, host, 1, true)
            end
        end
        return
    end

    local count = 1
    if stub.population > 500000 then count = 2 end
    if stub.population > 5e7 then count = 3 end
    if stub.population > 8e8 then count = 4 end

    for i = 1, count do
        local host = system._pickHost(sys, rng)
        sys.stations[i] = system._makeStation(sys, rng:derive("station", i), stub, host, i, false)
    end
end

function system._pickHost(sys, rng)
    local candidates = {}
    for _, b in ipairs(sys.bodies) do
        if b.kind == "planet" then candidates[#candidates + 1] = b end
    end
    if #candidates == 0 then return nil end
    return rng:pick(candidates)
end

function system._makeStation(sys, rng, stub, host, index, derelict)
    local kind = pickWeighted(rng, STATION_KINDS, function(k)
        if k.id == "outpost" then return true end
        return stub.population > 200000
    end)
    local seed = Rng.hash(stub.seed, "station", index)

    local eco = stub.economyId
    if index > 1 then
        eco = rng:pick({ "refinery", "industrial", "service", "hightech", "military", "extraction", "agricultural" })
    end

    local pop = math.max(120, math.floor(stub.population * rng:range(0.002, 0.05)))
    local faction = factions.get(stub.factionId)

    local st = {
        kind = "station",
        stationKind = kind.id,
        stationKindName = kind.name,
        name = derelict and (names.station(seed) .. " (derelict)") or names.station(seed),
        seed = seed,
        index = index,
        host = host,
        derelict = derelict or false,
        size = kind.size * rng:range(0.85, 1.25),
        pads = kind.pads,
        rotation = rng:range(0.004, 0.011) * (rng:bool() and 1 or -1),
        rotationPhase = rng:range(0, TAU),
        orbitRadius = host and host.radius * rng:range(2.4, 5.5) or S.orbitMin * rng:range(0.5, 1.5),
        orbitPeriod = S.stationOrbitPeriod * rng:range(0.7, 1.6),
        orbitPhase = rng:range(0, TAU),
        orbitInclination = rng:gauss(0, 0.25),
        population = derelict and 0 or pop,
        economyId = eco,
        techLevel = util.clamp(stub.techLevel + rng:int(-1, 1), 1, 12),
        lawLevel = derelict and 0 or util.clamp(stub.lawLevel + rng:range(-0.12, 0.12), 0, 1),
        factionId = stub.factionId,
        wealth = stub.wealth * rng:range(0.85, 1.2),
        blackMarket = derelict or (stub.lawLevel < 0.5 and rng:bool(0.6)) or faction.ethos == "criminal",
        services = {},
        pos = { x = 0, y = 0, z = 0 },
    }

    st.services.market = not derelict or rng:bool(0.5)
    st.services.missions = not derelict
    st.services.shipyard = (not derelict) and st.techLevel >= 5 and rng:bool(0.7)
    st.services.outfitting = not derelict
    st.services.refuel = true
    st.services.repair = not derelict or rng:bool(0.3)
    st.services.blackMarket = st.blackMarket

    return st
end

--- Ground settlements.  These are what the player lands at, walks around and
--- eventually competes with by founding colonies of their own.
function system._placeSettlements(sys, rng, stub, day)
    for _, body in ipairs(sys.bodies) do
        if body.kind == "planet" and body.landable then
            local hostable = body.atmosphere > 0.05 or body.radius < S.planetRadiusMax
            local base = 0
            if stub.population > 0 and hostable then
                base = util.clamp(math.log(1 + stub.population) / 22, 0, 1)
                if body.type == "terran" or body.type == "ocean" then base = base * 1.6 end
                if body.type == "desert" then base = base * 1.15 end
                if body.type == "toxic" or body.type == "volcanic" then base = base * 0.55 end
            end
            local count = 0
            local prng = rng:derive("settlements", body.index)
            for i = 1, 4 do
                if prng:float() < base then count = count + 1 end
            end
            if stub.population > 5e8 and body.type == "terran" then count = math.max(count, 3) end

            for i = 1, count do
                local s = system._makeSettlement(sys, prng:derive("s", i), stub, body, i)
                sys.settlements[#sys.settlements + 1] = s
                body.settlements = body.settlements or {}
                body.settlements[#body.settlements + 1] = s
            end

            -- also add moon outposts occasionally
            for _, moon in ipairs(body.moons) do
                if prng:bool(0.12) and stub.population > 20000 then
                    local s = system._makeSettlement(sys, prng:derive("m", moon.index), stub, moon, 1, true)
                    sys.settlements[#sys.settlements + 1] = s
                    moon.settlements = moon.settlements or {}
                    moon.settlements[#moon.settlements + 1] = s
                end
            end
        end
    end
end

function system._makeSettlement(sys, rng, stub, body, index, tiny)
    local seed = Rng.hash(body.seed, "settlement", index)
    local pop
    if tiny then
        pop = math.floor(rng:range(40, 900))
    else
        pop = math.floor(util.clamp(stub.population * rng:range(0.0005, 0.06), 120, 4.2e6))
    end

    local eco
    if pop < 1500 then
        eco = rng:pick({ "extraction", "colony", "extraction", "refinery" })
    elseif body.type == "terran" or body.type == "ocean" then
        eco = rng:pick({ "agricultural", "service", "industrial", "terraforming", "tourism" })
    elseif body.type == "desert" or body.type == "volcanic" then
        eco = rng:pick({ "extraction", "refinery", "industrial", "military" })
    else
        eco = rng:pick({ "extraction", "refinery", "colony", "military", "hightech" })
    end

    -- surface position in body-fixed spherical coordinates
    local lat = rng:gauss(0, 0.55)
    lat = util.clamp(lat, -1.35, 1.35)
    local lon = rng:range(-math.pi, math.pi)

    return {
        kind = "settlement",
        name = names.settlement(seed),
        seed = seed,
        index = index,
        body = body,
        bodyName = body.name,
        latitude = lat,
        longitude = lon,
        population = pop,
        tier = util.clamp(math.floor(math.log(1 + pop / 120) / math.log(6)) + 1, 1, 5),
        economyId = eco,
        techLevel = util.clamp(stub.techLevel + rng:int(-2, 1), 1, 12),
        lawLevel = util.clamp(stub.lawLevel + rng:range(-0.25, 0.1), 0, 1),
        factionId = stub.factionId,
        wealth = stub.wealth * rng:range(0.7, 1.15),
        blackMarket = rng:bool(0.35) or stub.lawLevel < 0.4,
        player = false,
        pads = math.max(1, math.min(6, math.floor(pop / 900) + 1)),
        services = {
            market = true,
            missions = pop > 400,
            refuel = true,
            repair = pop > 900,
            outfitting = pop > 6000,
            shipyard = pop > 90000,
            blackMarket = rng:bool(0.35),
        },
        pos = { x = 0, y = 0, z = 0 },        -- filled in by updateOrbits
    }
end

-- ---------------------------------------------------------------------------
-- Orbital state
-- ---------------------------------------------------------------------------

local function orbitPosition(radius, period, phase, inclination, t)
    local a = phase + (period > 0 and (t / period) * TAU or 0)
    local x = math.cos(a) * radius
    local z = math.sin(a) * radius
    local y = math.sin(a) * radius * math.sin(inclination or 0)
    return x, y * 0.4, z
end

--- Places every body for world-time `t` (in days).  Called on system entry and
--- then once per frame; it is pure trigonometry, so it costs nothing.
function system.updateOrbits(sys, t)
    sys.day = t
    for _, b in ipairs(sys.bodies) do
        if b.kind == "planet" then
            local x, y, z = orbitPosition(b.orbitRadius, b.orbitPeriod, b.orbitPhase, b.orbitInclination, t)
            b.pos.x, b.pos.y, b.pos.z = x, y, z
            b.spin = (b.rotationPhase + (t / b.dayLength) * TAU) % TAU
            for _, m in ipairs(b.moons) do
                local mx, my, mz = orbitPosition(m.orbitRadius, m.orbitPeriod, m.orbitPhase, m.orbitInclination, t)
                m.pos.x, m.pos.y, m.pos.z = x + mx, y + my, z + mz
                m.spin = (m.rotationPhase + (t / m.dayLength) * TAU) % TAU
            end
        end
    end
    for _, st in ipairs(sys.stations) do
        local host = st.host
        local hx, hy, hz = 0, 0, 0
        if host then hx, hy, hz = host.pos.x, host.pos.y, host.pos.z end
        local px, py, pz = st.pos.x, st.pos.y, st.pos.z
        local x, y, z = orbitPosition(st.orbitRadius, st.orbitPeriod, st.orbitPhase, st.orbitInclination, t)
        st.pos.x, st.pos.y, st.pos.z = hx + x, hy + y, hz + z
        st.spin = (st.rotationPhase + t * st.rotation * TAU * 40) % TAU
        -- Orbital velocity, in metres per real second.
        --
        -- A station moves at around 100 m/s, which is the same order as the
        -- docking speed limit -- so "how fast am I going" only means anything
        -- relative to the station. Without this, closing on one was a stern
        -- chase and the speed gate measured the wrong thing entirely.
        st.vel = st.vel or { 0, 0, 0 }
        local elapsed = (t - (st._velDay or t)) * config.economy.dayLength
        if elapsed > 1e-6 then
            local idt = 1 / elapsed
            local k = 0.25
            st.vel[1] = st.vel[1] + ((st.pos.x - px) * idt - st.vel[1]) * k
            st.vel[2] = st.vel[2] + ((st.pos.y - py) * idt - st.vel[2]) * k
            st.vel[3] = st.vel[3] + ((st.pos.z - pz) * idt - st.vel[3]) * k
        end
        st._velDay = t
    end
    for _, s in ipairs(sys.settlements) do
        local x, y, z = system.surfacePoint(s.body, s.latitude, s.longitude, 0)
        s.pos.x, s.pos.y, s.pos.z = x, y, z
    end
end

--- World position of a point on a body's surface, accounting for the body's
--- rotation and axial tilt.  `altitude` is metres above the reference radius.
function system.surfacePoint(body, lat, lon, altitude)
    local r = body.radius + (altitude or 0)
    local spin = body.spin or 0
    local a = lon + spin
    local cl = math.cos(lat)
    local lx = math.cos(a) * cl
    local ly = math.sin(lat)
    local lz = math.sin(a) * cl
    -- axial tilt about the X axis
    local tilt = body.axialTilt or 0
    local ct, st = math.cos(tilt), math.sin(tilt)
    local ty = ly * ct - lz * st
    local tz = ly * st + lz * ct
    return body.pos.x + lx * r, body.pos.y + ty * r, body.pos.z + tz * r, lx, ty, tz
end

--- Inverse of `surfacePoint`: latitude/longitude of a world position.
function system.surfaceCoords(body, x, y, z)
    local dx, dy, dz = x - body.pos.x, y - body.pos.y, z - body.pos.z
    local tilt = -(body.axialTilt or 0)
    local ct, st = math.cos(tilt), math.sin(tilt)
    local ry = dy * ct - dz * st
    local rz = dy * st + dz * ct
    local len = math.sqrt(dx * dx + ry * ry + rz * rz)
    if len < 1e-6 then return 0, 0, 0 end
    local lat = math.asin(util.clamp(ry / len, -1, 1))
    local lon = (math.atan2 or math.atan)(rz, dx) - (body.spin or 0)
    lon = (lon + math.pi) % TAU - math.pi
    return lat, lon, len - body.radius
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Every dockable location in the system, as a flat list.
function system.ports(sys)
    local out = {}
    for _, st in ipairs(sys.stations) do out[#out + 1] = st end
    for _, s in ipairs(sys.settlements) do out[#out + 1] = s end
    return out
end

--- Every body the ship can collide with or land on.
function system.landables(sys)
    local out = {}
    for _, b in ipairs(sys.bodies) do
        if b.kind == "planet" then
            out[#out + 1] = b
            for _, m in ipairs(b.moons) do out[#out + 1] = m end
        end
    end
    return out
end

--- The body whose sphere of influence contains a point (nil in deep space).
function system.dominantBody(sys, x, y, z)
    local best, bestScore = nil, math.huge
    for _, b in ipairs(system.landables(sys)) do
        local dx, dy, dz = x - b.pos.x, y - b.pos.y, z - b.pos.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        local soi = b.radius * 26
        if d < soi then
            local score = d / b.radius
            if score < bestScore then best, bestScore = b, score end
        end
    end
    return best
end

--- Altitude above a body's mean surface.
function system.altitude(body, x, y, z)
    local dx, dy, dz = x - body.pos.x, y - body.pos.y, z - body.pos.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) - body.radius
end

system.PLANET_TYPES = PLANET_TYPES
system.STATION_KINDS = STATION_KINDS

return system

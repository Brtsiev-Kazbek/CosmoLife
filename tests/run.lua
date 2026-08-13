-- Head-less test harness.
--
--     luajit tests/run.lua        (from the repository root)
--
-- Everything below the rendering layer is written so it can run without LOVE:
-- the mesh builder falls back to plain tables, and no simulation module ever
-- touches love.*.  That makes the generators testable in CI and makes a
-- balance question ("is trading actually profitable?") answerable without
-- launching the game.

package.path = "./?.lua;./?/init.lua;" .. package.path

local passed, failed = 0, 0
local failures = {}

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = name .. (detail and ("  -- " .. tostring(detail)) or "")
        io.write("FAIL  ", name, detail and ("  -- " .. tostring(detail)) or "", "\n")
    end
end

local function test(name, fn)
    local ok, err = pcall(fn, function(cond, detail) check(name, cond, detail) end)
    if not ok then
        failed = failed + 1
        failures[#failures + 1] = name .. "  -- error: " .. tostring(err)
        io.write("ERROR ", name, "  -- ", tostring(err), "\n")
    end
end

-- ---------------------------------------------------------------------------

local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local noise = require("src.lib.noise")
local serialize = require("src.lib.serialize")

test("rng is deterministic", function(assert_)
    local a = Rng.new(12345)
    local b = Rng.new(12345)
    local same = true
    for _ = 1, 500 do
        if a:float() ~= b:float() then same = false break end
    end
    assert_(same, "two generators with the same seed diverged")
end)

test("rng stays in range and is roughly uniform", function(assert_)
    local r = Rng.new(7)
    local sum, lo, hi = 0, 1, 0
    local buckets = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    for _ = 1, 20000 do
        local v = r:float()
        sum = sum + v
        lo = math.min(lo, v)
        hi = math.max(hi, v)
        local b = math.floor(v * 10) + 1
        buckets[b] = buckets[b] + 1
    end
    assert_(lo >= 0 and hi < 1, "out of range: " .. lo .. ".." .. hi)
    assert_(math.abs(sum / 20000 - 0.5) < 0.01, "mean drifted: " .. sum / 20000)
    local worst = 0
    for i = 1, 10 do worst = math.max(worst, math.abs(buckets[i] / 20000 - 0.1)) end
    assert_(worst < 0.012, "bucket skew " .. worst)
end)

test("rng int bounds are inclusive", function(assert_)
    local r = Rng.new(99)
    local seen = {}
    for _ = 1, 3000 do seen[r:int(1, 5)] = true end
    local all = true
    for i = 1, 5 do all = all and seen[i] end
    assert_(all, "not every value in 1..5 was produced")
    local outside = false
    for _ = 1, 3000 do
        local v = r:int(3, 4)
        if v < 3 or v > 4 then outside = true end
    end
    assert_(not outside, "int() left its bounds")
end)

test("vec3 basics", function(assert_)
    local a = vec3(1, 2, 3)
    local b = vec3(4, 5, 6)
    assert_(math.abs(vec3.dot(a, b) - 32) < 1e-9, "dot")
    local c = vec3.cross(vec3(1, 0, 0), vec3(0, 1, 0))
    assert_(c.x == 0 and c.y == 0 and c.z == 1, "cross handedness")
    assert_(math.abs(vec3(3, 4, 0):length() - 5) < 1e-9, "length")
end)

test("mat4 perspective and view", function(assert_)
    local p = mat4.perspective(math.rad(90), 1, 1, 100)
    assert_(math.abs(p[1] - 1) < 1e-6, "fov scale")
    assert_(p[12] == -1, "w = -z")

    -- a point 10 m in front of a camera looking down -Z should land on the axis
    local eye = vec3(0, 0, 0)
    local v = mat4.view(eye, vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, -1))
    local x, y, z = mat4.mulPoint(v, 0, 0, -10)
    assert_(math.abs(x) < 1e-9 and math.abs(y) < 1e-9 and math.abs(z + 10) < 1e-9,
        string.format("view mapped to %.3f %.3f %.3f", x, y, z))
end)

test("mat4 orthonormalize keeps a right handed frame", function(assert_)
    local right, up, fwd = vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, -1)
    -- perturb it the way accumulated rotations would
    up:set(0.02, 0.98, 0.05)
    fwd:set(0.03, 0.04, -0.99)
    mat4.orthonormalize(right, up, fwd)
    local c = vec3.cross(right, up)          -- should equal -fwd
    assert_(math.abs(c.x + fwd.x) < 1e-6 and math.abs(c.y + fwd.y) < 1e-6 and math.abs(c.z + fwd.z) < 1e-6,
        "right x up != -fwd, frame is left handed")
    assert_(math.abs(right:length() - 1) < 1e-9 and math.abs(up:length() - 1) < 1e-9, "not unit length")
end)

test("noise is bounded and continuous", function(assert_)
    local lo, hi = 10, -10
    for i = 0, 4000 do
        local v = noise.perlin3(11, i * 0.13, i * 0.07, i * 0.21)
        lo, hi = math.min(lo, v), math.max(hi, v)
    end
    assert_(lo > -2 and hi < 2, "range " .. lo .. ".." .. hi)
    local a = noise.perlin2(3, 10.0, 4.0)
    local b = noise.perlin2(3, 10.001, 4.0)
    assert_(math.abs(a - b) < 0.02, "discontinuous")
end)

test("serialize round trip", function(assert_)
    local data = { a = 1, b = "two", c = { 3, 4, 5 }, d = true, e = -0.5, ["odd key"] = { x = 1 } }
    local text = serialize.encode(data)
    local back, err = serialize.decode(text)
    assert_(back ~= nil, err)
    assert_(back and back.a == 1 and back.b == "two" and back.c[3] == 5 and back.d == true, "values lost")
    assert_(back and back["odd key"].x == 1, "non identifier key lost")
end)

-- ---------------------------------------------------------------------------

local Galaxy = require("src.procgen.galaxy")
local systemGen = require("src.procgen.system")
local factions = require("src.sim.factions")
local economy = require("src.sim.economy")
local commodities = require("src.sim.commodities")

test("galaxy generates stars and is stable", function(assert_)
    local g1 = Galaxy.new(42)
    local g2 = Galaxy.new(42)
    local a = g1:systemsNear(700, 0, 0, 60)
    local b = g2:systemsNear(700, 0, 0, 60)
    assert_(#a > 0, "no systems found near the arm")
    assert_(#a == #b, "regeneration produced a different count")
    local same = true
    for i = 1, #a do
        if a[i].id ~= b[i].id or a[i].name ~= b[i].name or math.abs(a[i].x - b[i].x) > 1e-9 then
            same = false
        end
    end
    assert_(same, "regeneration produced different systems")
end)

test("galaxy ids round trip", function(assert_)
    local g = Galaxy.new(7)
    local list = g:systemsNear(-620, 5, 300, 80)
    assert_(#list > 0, "no systems")
    local ok = true
    for i = 1, math.min(#list, 25) do
        local s = g:byId(list[i].id)
        if not s or s.name ~= list[i].name then ok = false end
    end
    assert_(ok, "byId did not return the same system")
end)

test("galaxy density makes arms denser than voids", function(assert_)
    local g = Galaxy.new(3)
    local samples, arm, void = 0, 0, 0
    for i = 0, 60 do
        local a = i / 60 * math.pi * 2
        local d = g:density(math.cos(a) * 700, 0, math.sin(a) * 700)
        arm = math.max(arm, d)
        void = math.min(void == 0 and 1 or void, d)
        samples = samples + 1
    end
    assert_(arm > void * 1.8, string.format("arm %.3f vs void %.3f", arm, void))
    assert_(g:density(700, 400, 0) < g:density(700, 0, 0), "the disc is not flattened")
end)

test("start system is habitable", function(assert_)
    local g = Galaxy.new(20250811)
    local s = g:findStartSystem()
    assert_(s ~= nil, "no start system found")
    assert_(s and s.population > 0, "start system is empty")
    assert_(s and s.lawLevel > 0.4, "start system is lawless")
end)

test("systems expand with bodies and ports", function(assert_)
    local g = Galaxy.new(11)
    local diplo = factions.Diplomacy.new(11)
    local list = g:systemsNear(680, 0, 120, 120)
    local withPorts, withPlanets, total = 0, 0, 0
    for i = 1, math.min(#list, 40) do
        local sys = systemGen.build(list[i], diplo, 3)
        total = total + 1
        if #systemGen.ports(sys) > 0 then withPorts = withPorts + 1 end
        if #sys.bodies > 1 then withPlanets = withPlanets + 1 end
    end
    assert_(total > 5, "not enough systems to sample")
    assert_(withPlanets > total * 0.5, "most systems have no planets")
    assert_(withPorts > total * 0.3, "hardly anywhere to dock: " .. withPorts .. "/" .. total)
end)

test("orbits move over time and surface coords invert", function(assert_)
    local g = Galaxy.new(5)
    local list = g:systemsNear(700, 0, 0, 200)
    local sys
    for _, stub in ipairs(list) do
        local s = systemGen.build(stub, nil, 0)
        if #s.bodies > 1 then sys = s break end
    end
    assert_(sys ~= nil, "no system with planets")
    if not sys then return end
    local p = sys.bodies[2]
    local x0 = p.pos.x
    systemGen.updateOrbits(sys, 40)
    assert_(math.abs(p.pos.x - x0) > 1, "planet did not move")

    local lat, lon = 0.4, -1.1
    local wx, wy, wz = systemGen.surfacePoint(p, lat, lon, 0)
    local blat, blon, alt = systemGen.surfaceCoords(p, wx, wy, wz)
    assert_(math.abs(blat - lat) < 1e-6, "latitude round trip: " .. blat)
    assert_(math.abs(blon - lon) < 1e-6, "longitude round trip: " .. blon)
    assert_(math.abs(alt) < 1, "altitude round trip: " .. alt)
end)

test("faction territory is coherent", function(assert_)
    local a = factions.territoryAt(10, 0, 10)
    local b = factions.territoryAt(10.05, 0, 10.05)
    assert_(a == b, "territory flips between adjacent points")
    local owners = {}
    for i = -30, 30, 3 do
        owners[factions.territoryAt(i, 0, i * 0.5)] = true
    end
    assert_(util.count(owners) > 2, "only one faction owns everything")
end)

test("markets price scarcity above surplus", function(assert_)
    local ag = economy.Market.new({ seed = 1, economyId = "agricultural", population = 90000, techLevel = 5 })
    local ht = economy.Market.new({ seed = 2, economyId = "hightech", population = 90000, techLevel = 10 })
    assert_(ag:trades("grain"), "an agricultural world does not trade grain")
    assert_(ht:trades("computers"), "a high tech world does not trade computers")
    assert_(ag:buyPrice("grain") < ht:sellPrice("grain") or not ht:trades("grain"),
        "grain is not worth hauling from a farm to a lab")
    if ag:trades("computers") then
        assert_(ht:buyPrice("computers") < ag:sellPrice("computers"),
            "computers are not worth hauling from a lab to a farm")
    end
end)

test("buying moves the price and cannot overdraw", function(assert_)
    local m = economy.Market.new({ seed = 3, economyId = "extraction", population = 40000 })
    local before = m:buyPrice("ore")
    local stock = m:available("ore")
    local n, cost = m:buy("ore", stock + 500)
    assert_(n == stock, "bought more than existed: " .. n .. " of " .. stock)
    assert_(cost > 0, "free goods")
    local after = m:buyPrice("ore")
    assert_(after > before, string.format("price did not rise: %d -> %d", before, after))
end)

test("quote does not mutate the market", function(assert_)
    local m = economy.Market.new({ seed = 4, economyId = "industrial", population = 200000 })
    local id = m:tradedIds()[1]
    local stock = m:available(id)
    m:quote(id, 20, false)
    m:quote(id, 20, true)
    assert_(m:available(id) == stock, "quote changed the stock")
end)

test("markets restock towards equilibrium", function(assert_)
    local m = economy.Market.new({ seed = 5, economyId = "agricultural", population = 60000, day = 0 })
    local id = "grain"
    m.stock[id] = 0
    m:update(60)
    assert_(m:available(id) > 0, "an empty farm never restocked grain")
    assert_(m:available(id) <= m.equilibrium[id] * 2.5, "restock overshot wildly")
end)

test("a full trade loop is profitable", function(assert_)
    -- the core promise of the genre: two complementary economies, one hold of
    -- cargo, one round trip, positive credits.
    local from = economy.Market.new({ seed = 6, economyId = "agricultural", population = 300000, techLevel = 4 })
    local to = economy.Market.new({ seed = 7, economyId = "hightech", population = 300000, techLevel = 10 })
    local best = economy.routeProfit(from, to, 16, 3000)
    assert_(best.id ~= nil, "no profitable cargo at all")
    assert_(best.profit > 0, "best route loses money")
end)

test("contraband legality follows local law", function(assert_)
    local narc = commodities.get("narcotics")
    local strict = select(1, commodities.legalityIn(narc, 0.9))
    local lawless = select(1, commodities.legalityIn(narc, 0.1))
    assert_(strict == "illegal", "narcotics legal under strict law")
    assert_(lawless ~= "illegal", "no market is ever loose enough")
    local arms = commodities.get("weapons")
    assert_(select(1, commodities.legalityIn(arms, 0.9)) == "illegal", "arms unrestricted under strict law")
    assert_(select(1, commodities.legalityIn(arms, 0.3)) == "legal", "arms restricted in a free port")
end)

test("diplomacy can start and end wars", function(assert_)
    local d = factions.Diplomacy.new(21)
    assert_(#d:activeWars() >= 1, "the galaxy starts at total peace")
    local sawEvent = false
    for day = 1, 600 do
        local ev = d:update(day)
        if ev then sawEvent = true end
    end
    assert_(sawEvent, "600 days passed with no diplomatic event")
end)

-- ---------------------------------------------------------------------------

local MeshBuilder = require("src.render.mesh")
local geometry = require("src.render.geometry")

test("mesh builder produces flat shaded triangles", function(assert_)
    local b = MeshBuilder.new()
    geometry.box(b, 2, 2, 2, { 1, 1, 1, 1 })
    assert_(b:triangleCount() == 12, "a box should be 12 triangles, got " .. b:triangleCount())
    -- every triangle carries one normal shared by its three vertices
    local flat = true
    for i = 1, b.n, 3 do
        local a, c = b.verts[i], b.verts[i + 2]
        if a[4] ~= c[4] or a[5] ~= c[5] or a[6] ~= c[6] then flat = false end
    end
    assert_(flat, "normals vary inside a triangle")
    assert_(math.abs(b:boundingRadius() - math.sqrt(3)) < 1e-6, "bounding radius " .. b:boundingRadius())
end)

test("mesh builder transform stack composes", function(assert_)
    local b = MeshBuilder.new()
    b:push():translate(10, 0, 0)
    geometry.box(b, 2, 2, 2, { 1, 1, 1, 1 })
    b:pop()
    local minx, _, _, maxx = b:bounds()
    assert_(math.abs(minx - 9) < 1e-6 and math.abs(maxx - 11) < 1e-6,
        string.format("box landed at %.2f..%.2f", minx, maxx))
    assert_(#b.stack == 0, "stack not balanced")
end)

test("primitives emit sane geometry", function(assert_)
    local cases = {
        { "cylinder", function(b) geometry.cylinder(b, 3, 8, 10, { 1, 1, 1, 1 }) end },
        { "sphere", function(b) geometry.sphere(b, 5, 12, 8, { 1, 1, 1, 1 }) end },
        { "dome", function(b) geometry.dome(b, 4, 4, 10, 4, { 1, 1, 1, 1 }) end },
        { "truss", function(b) geometry.truss(b, 4, 20, 5, 0.3, { 1, 1, 1, 1 }) end },
        { "torus", function(b) geometry.torus(b, 20, 4, 16, 6, { 1, 1, 1, 1 }) end },
        { "extrude", function(b) geometry.extrude(b, geometry.ngon(6, 5), 0, 9, { 1, 1, 1, 1 }) end },
    }
    for _, case in ipairs(cases) do
        local b = MeshBuilder.new()
        case[2](b)
        local finite = true
        for i = 1, b.n do
            local v = b.verts[i]
            for k = 1, 6 do
                if v[k] ~= v[k] or v[k] == math.huge or v[k] == -math.huge then finite = false end
            end
        end
        check("primitives emit sane geometry", b.n > 0, case[1] .. " produced nothing")
        check("primitives emit sane geometry", finite, case[1] .. " produced NaN/inf")
    end
end)

-- ---------------------------------------------------------------------------

local ships = require("src.procgen.ships")
local buildings = require("src.procgen.buildings")
local settlement = require("src.procgen.settlement")
local terrain = require("src.procgen.terrain")

test("ship generator covers every role", function(assert_)
    for _, role in ipairs(ships.roles) do
        local def = ships.generate(Rng.hash(role, 5), role)
        check("ship generator covers every role", def ~= nil, role .. " produced nothing")
        check("ship generator covers every role", def and def.model and def.model.triangles > 40,
            role .. " is too simple: " .. tostring(def and def.model and def.model.triangles))
        check("ship generator covers every role", def and def.stats.hull > 0 and def.stats.cargo >= 0,
            role .. " has broken stats")
    end
end)

test("buildings are detailed and stay on their footprint", function(assert_)
    local total = 0
    for i = 1, #buildings.kinds do
        local kind = buildings.kinds[i]
        local b = MeshBuilder.new()
        local info = buildings.build(b, kind.id, Rng.new(i * 77), { tier = 4, tech = 9 })
        check("buildings are detailed and stay on their footprint", b:triangleCount() > 30,
            kind.id .. " only has " .. b:triangleCount() .. " triangles")
        local minx, miny, minz, maxx, maxy, maxz = b:bounds()
        check("buildings are detailed and stay on their footprint", miny > -2.5,
            kind.id .. " sinks below the ground: " .. miny)
        check("buildings are detailed and stay on their footprint",
            maxy > 2 and maxy < 400, kind.id .. " height " .. maxy)
        check("buildings are detailed and stay on their footprint", info and info.radius > 0,
            kind.id .. " reported no radius")
        total = total + b:triangleCount()
    end
    assert_(total > 800, "the whole building catalogue is only " .. total .. " triangles")
end)

test("settlements lay out without overlapping buildings", function(assert_)
    local s = settlement.generate({
        seed = 4242, tier = 4, population = 40000, economyId = "industrial",
        techLevel = 8, factionId = "federation", pads = 3,
    })
    assert_(s.model ~= nil, "no mesh produced")
    assert_(#s.buildings >= 6, "only " .. #s.buildings .. " buildings")
    assert_(#s.pads >= 1, "no landing pads")
    local overlap = false
    for i = 1, #s.buildings do
        for j = i + 1, #s.buildings do
            local a, b = s.buildings[i], s.buildings[j]
            local dx, dz = a.x - b.x, a.z - b.z
            if math.sqrt(dx * dx + dz * dz) < (a.radius + b.radius) * 0.72 then overlap = true end
        end
    end
    assert_(not overlap, "buildings intersect")
    local padClear = true
    for _, p in ipairs(s.pads) do
        for _, bl in ipairs(s.buildings) do
            local dx, dz = p.x - bl.x, p.z - bl.z
            if math.sqrt(dx * dx + dz * dz) < bl.radius + p.radius then padClear = false end
        end
    end
    assert_(padClear, "a landing pad is inside a building")
    assert_(#s.interiors > 0, "no enterable buildings")
end)

test("terrain is deterministic and continuous", function(assert_)
    local body = { seed = 999, radius = 3.2e6, terrain = "terran", atmosphere = 1.0, type = "terran" }
    local field = terrain.field(body)
    local a = field:height(1000, 2000)
    local b = field:height(1000, 2000)
    assert_(a == b, "height field is not deterministic")
    local c = field:height(1001, 2000)
    assert_(math.abs(a - c) < 60, "height jumps " .. math.abs(a - c) .. " m over one metre")
    local nx, ny, nz = field:normal(1000, 2000)
    local len = math.sqrt(nx * nx + ny * ny + nz * nz)
    assert_(math.abs(len - 1) < 1e-6, "normal is not unit length")
    assert_(ny > 0.2, "terrain normal points sideways or down")
end)

test("terrain chunks build meshes", function(assert_)
    local body = { seed = 5, radius = 2.4e6, terrain = "desert", atmosphere = 0.5, type = "desert" }
    local field = terrain.field(body)
    local chunk = field:buildChunk(0, 0, 1200, 12)
    assert_(chunk ~= nil and chunk.model ~= nil, "no chunk mesh")
    assert_(chunk and chunk.model.triangles > 100, "chunk too coarse")
end)

-- ---------------------------------------------------------------------------

local missions = require("src.sim.missions")
local colony = require("src.sim.colony")
local Player = require("src.sim.player")

test("mission board generates valid, varied contracts", function(assert_)
    local g = Galaxy.new(31)
    local diplo = factions.Diplomacy.new(31)
    local stub = g:findStartSystem()
    local sys = systemGen.build(stub, diplo, 5)
    local port = systemGen.ports(sys)[1]
    assert_(port ~= nil, "start system has nowhere to dock")
    if not port then return end
    local board = missions.generate(port, sys, g, diplo, 5, 12)
    assert_(#board > 0, "empty mission board")
    local kinds = {}
    local ok = true
    for _, m in ipairs(board) do
        kinds[m.type] = true
        if not (m.reward > 0 and m.title and m.expires > 5) then ok = false end
    end
    assert_(ok, "a mission had no reward, title or deadline")
    assert_(util.count(kinds) >= 2, "mission board offers only one kind of job")
end)

test("colony founding and growth", function(assert_)
    local body = { seed = 3, name = "Test I", radius = 3e6, type = "desert", terrain = "desert",
                   atmosphere = 0.6, gravity = 8.5, pos = { x = 0, y = 0, z = 0 }, spin = 0, axialTilt = 0 }
    local c = colony.found({
        seed = 77, body = body, latitude = 0.2, longitude = 0.5,
        name = "Testville", factionId = "independent", day = 10,
    })
    assert_(c ~= nil and c.player, "colony not created")
    local pop0 = c.population
    colony.update(c, 10 + 120)
    assert_(c.population > pop0, "colony did not grow in 120 days")
    assert_(c.tier >= 1, "colony has no tier")
    local before = c.stockpile.provisions or 0
    colony.supply(c, "provisions", 40)
    assert_((c.stockpile.provisions or 0) > before, "supplying did not add stock")
end)

test("player cargo, credits and reputation behave", function(assert_)
    local p = Player.new({ seed = 1 })
    local cap = p:cargoCapacity()
    assert_(cap > 0, "no cargo capacity")
    local added = p:addCargo("grain", cap + 10)
    assert_(added == cap, "overfilled the hold: " .. added .. "/" .. cap)
    assert_(p:cargoUsed() == cap, "cargo accounting wrong")
    local removed = p:removeCargo("grain", 5)
    assert_(removed == 5 and p:cargoUsed() == cap - 5, "removal accounting wrong")
    p.credits = 100
    assert_(p:spend(50) and p.credits == 50, "spend failed")
    assert_(not p:spend(500), "spent credits it does not have")
    p:addReputation("federation", 0.3)
    assert_(p:reputation("federation") > 0, "reputation not recorded")
    p:addReputation("federation", -5)
    assert_(p:reputation("federation") >= -1, "reputation left its range")
end)

test("save round trip preserves the player", function(assert_)
    local p = Player.new({ seed = 2 })
    p.credits = 12345
    p:addCargo("medicine", 3)
    p:addReputation("dominion", -0.4)
    local data = p:save()
    local text = serialize.encode(data)
    local back = serialize.decode(text)
    local q = Player.new({ seed = 2 })
    q:load(back)
    assert_(q.credits == 12345, "credits lost")
    assert_(q.cargo.medicine == 3, "cargo lost")
    assert_(math.abs(q:reputation("dominion") + 0.4) < 1e-9, "reputation lost")
end)

-- ---------------------------------------------------------------------------

local World = require("src.sim.world")

test("world runs a full loop: enter, trade, contract, jump", function(assert_)
    local world = World.new({ seed = 776 })
    local start = world.galaxy:findStartSystem()
    assert_(start ~= nil, "no start system")
    if not start then return end
    world:enterSystem(start)
    assert_(world.system ~= nil, "system did not expand")

    local ports = systemGen.ports(world.system)
    assert_(#ports > 0, "start system has nowhere to dock")
    if #ports == 0 then return end
    local port = ports[1]

    local market = world:market(port)
    assert_(market ~= nil, "no market")
    local ids = market:tradedIds()
    assert_(#ids > 0, "market trades nothing")

    -- buy something and check the books balance
    local id = ids[1]
    local creditsBefore = world.player.credits
    local n, cost = market:buy(id, 3)
    world.player:spend(cost)
    world.player:addCargo(id, n)
    assert_(world.player.credits == creditsBefore - cost, "credits did not match the invoice")
    assert_(world.player:cargoCount(id) == n, "cargo did not arrive")

    local board = world:board(port)
    assert_(#board > 0, "no contracts offered")
    if #board > 0 then
        local m = board[1]
        local ok = missions.accept(m, world.player, world.day)
        if ok then assert_(#world.player.missions == 1, "accepted contract not logged") end
    end

    -- time passes, then jump somewhere
    world:update(600)
    assert_(world.day > 0, "the clock did not advance")

    local targets = world:jumpTargets()
    assert_(#targets > 0, "nothing in jump range")
    local reachable
    for _, t in ipairs(targets) do
        if t.reachable then reachable = t break end
    end
    assert_(reachable ~= nil, "no reachable system with a full tank")
    if reachable then
        local fuelBefore = world.player.fuel
        local jumped, msg = world:jump(reachable)
        assert_(jumped, tostring(msg))
        assert_(world.player.fuel < fuelBefore, "the jump was free")
        assert_(world.stub.id == reachable.id, "arrived somewhere else")
    end
end)

test("world save survives a round trip", function(assert_)
    local world = World.new({ seed = 991 })
    world:enterSystem(world.galaxy:findStartSystem())
    world.player.credits = 77777
    world.player:addCargo("medicine", 4)
    world:update(1500)
    local savedDay = world.day
    local savedSystem = world.stub.id

    local text = serialize.encode(world:save())
    local data, err = serialize.decode(text)
    assert_(data ~= nil, err)

    local restored = World.new({ seed = 1 })
    assert_(restored:loadFrom(data), "loadFrom failed")
    assert_(restored.player.credits == 77777, "credits lost")
    assert_(restored.player:cargoCount("medicine") == 4, "cargo lost")
    assert_(math.abs(restored.day - savedDay) < 1e-6, "clock lost")
    assert_(restored.stub.id == savedSystem, "landed in the wrong system")
end)

test("surface frame round trips and terrain agrees with orbit", function(assert_)
    local Surface = require("src.procgen.surface")
    local world = World.new({ seed = 315 })
    local sys
    for _ = 1, 40 do
        local stub = world.galaxy:findStartSystem()
        sys = systemGen.build(stub, world.diplomacy, 0)
        break
    end
    local body
    for _, b in ipairs(systemGen.landables(sys)) do
        if b.landable and not b.giant then body = b break end
    end
    assert_(body ~= nil, "no landable body in the start system")
    if not body then return end

    local surface = Surface.new(body)
    surface:setOrigin(0.3, -0.7, {})

    -- local -> world -> local must be the identity
    local wv = surface:toWorld(1200, 340, -900)
    local lx, ly, lz = surface:toLocal(wv.x, wv.y, wv.z)
    assert_(math.abs(lx - 1200) < 0.5 and math.abs(ly - 340) < 0.5 and math.abs(lz + 900) < 0.5,
        string.format("round trip drifted to %.2f %.2f %.2f", lx, ly, lz))

    -- the ground at the origin must match the sphere's own height field
    local field = require("src.procgen.terrain").field(body)
    local dx, dy, dz = field:directionAt(0, 0)
    local orbitH = field:heightDir(dx, dy, dz)
    local groundH = surface:groundHeight(0, 0)
    assert_(math.abs(orbitH - groundH) < 200,
        string.format("orbit says %.0f m, ground says %.0f m", orbitH, groundH))

    -- curvature must pull the far edge of a patch down, not up
    local far = surface:groundHeight(20000, 0)
    local flat = field:height(20000, 0)
    assert_(far < flat, "the patch does not follow the planet's curvature")
end)

test("every module loads", function(assert_)
    local modules = {
        "src.config", "src.game",
        "src.lib.class", "src.lib.mat4", "src.lib.noise", "src.lib.rng",
        "src.lib.serialize", "src.lib.util", "src.lib.vec3",
        "src.procgen.buildings", "src.procgen.galaxy", "src.procgen.interior",
        "src.procgen.names", "src.procgen.settlement", "src.procgen.ships",
        "src.procgen.stations", "src.procgen.surface", "src.procgen.system",
        "src.procgen.terrain",
        "src.render.bodies", "src.render.camera", "src.render.geometry",
        "src.render.hud", "src.render.mesh", "src.render.palette",
        "src.render.renderer", "src.render.shaders", "src.render.sky",
        "src.sim.colony", "src.sim.combat", "src.sim.commodities", "src.sim.economy",
        "src.sim.equipment", "src.sim.factions", "src.sim.missions", "src.sim.npc",
        "src.sim.player", "src.sim.world",
        "src.states.colonies", "src.states.flight", "src.states.galaxymap",
        "src.states.gameover", "src.states.logbook", "src.states.manager",
        "src.states.menu", "src.states.onfoot", "src.states.pause",
        "src.states.port", "src.states.room",
        "src.ui.widgets",
    }
    for _, name in ipairs(modules) do
        local ok, err = pcall(require, name)
        check("every module loads", ok, name .. ": " .. tostring(err))
    end
end)

test("NPC traffic spawns and flies", function(assert_)
    local npcMod = require("src.sim.npc")
    local combatMod = require("src.sim.combat")
    local vec = require("src.lib.vec3")
    local world = World.new({ seed = 61 })
    world:enterSystem(world.galaxy:findStartSystem())

    local camera = { pos = vec(0, 0, 0) }
    local list, state = {}, {}
    for _ = 1, 60 do
        npcMod.maintain(list, world.system, world.player, world.diplomacy, world.day, camera, 5, state)
    end
    assert_(#list > 0, "no traffic spawned in an inhabited system")

    local arena = combatMod.newArena()
    local before = {}
    for i, e in ipairs(list) do before[i] = { e.pos.x, e.pos.y, e.pos.z } end
    local ctx = {
        arena = arena, npcs = list, playerShip = nil,
        diplomacy = world.diplomacy, ports = systemGen.ports(world.system), time = 0,
    }
    for _ = 1, 120 do npcMod.update(list, 1 / 30, ctx) end

    local moved, finite = 0, true
    for i, e in ipairs(list) do
        local b = before[i]
        if math.abs(e.pos.x - b[1]) + math.abs(e.pos.y - b[2]) + math.abs(e.pos.z - b[3]) > 1 then
            moved = moved + 1
        end
        if e.pos.x ~= e.pos.x or e.pos.y ~= e.pos.y then finite = false end
    end
    assert_(moved > 0, "nothing moved in four seconds")
    assert_(finite, "an NPC's position went NaN")
end)

test("combat resolves damage and kills", function(assert_)
    local combatMod = require("src.sim.combat")
    local vec = require("src.lib.vec3")
    local arena = combatMod.newArena()

    local shooter = {
        pos = vec(0, 0, 0), vel = vec(0, 0, 0),
        right = vec(1, 0, 0), up = vec(0, 1, 0), fwd = vec(0, 0, -1),
        hull = 100, shield = 0, radius = 5, stats = { maxHull = 100, maxShield = 0 },
    }
    local target = {
        pos = vec(0, 0, -400), vel = vec(0, 0, 0), radius = 20,
        hull = 50, shield = 30, stats = { maxHull = 50, maxShield = 30 },
    }
    local weapon = { weapon = { damage = 20, rate = 4, energy = 1, speed = 2000, color = { 1, 1, 1 } } }
    combatMod.fire(arena, shooter, weapon, 0, 0, -1, 0)
    assert_(arena.nProjectiles == 1, "no projectile spawned")

    local killed = nil
    for _ = 1, 60 do
        combatMod.update(arena, 1 / 30, {
            entities = { shooter, target },
            onKill = function(v, k) killed = v end,
        })
    end
    assert_(target.shield < 30 or target.hull < 50, "the shot never landed")

    -- keep shooting until it dies
    for _ = 1, 20 do
        combatMod.fire(arena, shooter, weapon, 0, 0, -1, 0)
        for _ = 1, 20 do
            combatMod.update(arena, 1 / 30, {
                entities = { shooter, target },
                onKill = function(v) killed = v end,
            })
        end
    end
    assert_(killed == target, "the target survived twenty hits")
    assert_(arena.nProjectiles >= 0, "projectile pool went negative")
end)

test("lead targeting aims ahead of a crossing target", function(assert_)
    local combatMod = require("src.sim.combat")
    local vec = require("src.lib.vec3")
    local shooter = { pos = vec(0, 0, 0), vel = vec(0, 0, 0) }
    local target = { pos = vec(0, 0, -1000), vel = vec(200, 0, 0) }
    local ax, ay, az = combatMod.leadTarget(shooter, target, 2000)
    assert_(ax > 50, "aim point did not lead a target crossing at 200 m/s: " .. ax)
    assert_(math.abs(az + 1000) < 1, "aim point drifted in range")
end)

-- ---------------------------------------------------------------------------

io.write("\n", string.rep("-", 52), "\n")
io.write(string.format("%d passed, %d failed\n", passed, failed))
if failed > 0 then
    io.write("\nfailures:\n")
    for _, f in ipairs(failures) do io.write("  ", f, "\n") end
    os.exit(1)
end
os.exit(0)

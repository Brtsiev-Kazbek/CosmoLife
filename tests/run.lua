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

test("the same seed gives the same market in every process", function(assert_)
    -- `pairs` order over a hash table is not stable between processes, so any
    -- code that draws random numbers while walking one drifts from run to run.
    -- This did: before it was pinned, one seed gave grain stocks of 898, 862,
    -- 936, 925 and 1079 on five consecutive runs of the same script -- in a
    -- project whose whole premise is that a seed is a universe.
    --
    -- The fingerprints are the guard. A deliberate balance change moves them
    -- and they get updated; a fingerprint that moves on its own means someone
    -- is drawing from a table again.
    local m = economy.Market.new({ seed = 11, economyId = "agricultural", population = 120000 })
    m:update(120)
    local sum = 0
    for i, id in ipairs(m:tradedIds()) do sum = sum + i * math.floor(m.stock[id]) end
    assert_(sum == 22410, "market fingerprint moved: " .. sum)

    local d = factions.Diplomacy.new(21)
    for day = 1, 600 do d:update(day) end
    local keys = util.keys(d.relations)
    table.sort(keys)
    local acc = 0
    for i, k in ipairs(keys) do acc = acc + i * math.floor(d.relations[k] * 1000 + 0.5) end
    assert_(#keys == 15, "the galaxy grew or lost factions: " .. #keys)
    assert_(acc == 15027, "diplomacy fingerprint moved: " .. acc)
end)

test("a market's fill does not depend on what else it trades", function(assert_)
    -- The property that makes the fingerprint above hold: each commodity's
    -- draw is keyed on its own id, so it cannot matter where in the walk it
    -- came up -- which is also what stops adding a commodity from reshuffling
    -- every other one.
    local full = economy.Market.new({ seed = 12, economyId = "industrial", population = 90000 })
    local id = full:tradedIds()[1]
    local alone = economy.Market.new({ seed = 12, economyId = "industrial", population = 90000 })
    for k in pairs(alone.equilibrium) do
        if k ~= id then alone.equilibrium[k] = nil end
    end
    alone.stock = {}
    alone:_seedStock()
    assert_(alone.stock[id] == full.stock[id],
        string.format("%s filled to %d alone and %d in company",
            id, alone.stock[id] or -1, full.stock[id] or -1))
end)

test("a market assessment answers what is cheap here", function(assert_)
    local trade = require("src.sim.trade")
    -- the verdict band has to be wider than the drift, or every row is flagged
    assert_(trade.verdict(trade.ratio(50, 100)) == "cheap", "half price is not called cheap")
    assert_(trade.verdict(trade.ratio(200, 100)) == "dear", "double price is not called dear")
    assert_(trade.verdict(trade.ratio(129, 100)) == "fair",
        "the median row in the galaxy is flagged, which flags nothing")
    assert_(trade.ratio(10, 0) == nil, "a zero reference price produced a ratio")

    local m = economy.Market.new({ seed = 11, economyId = "agricultural", population = 120000 })
    local id = m:tradedIds()[1]
    local row = trade.assess(m, id, { credits = 1e6, free = 20 })
    assert_(row.buy == m:buyPrice(id), "assessment disagrees with the market on price")
    assert_(row.take <= 20, "the hold took more than it holds: " .. row.take)
    -- the whole point of the column: an agricultural world's own produce is
    -- under the galactic reference, not over it
    local cheap = false
    for _, cid in ipairs(m:tradedIds()) do
        local r = trade.assess(m, cid, { credits = 1e9, free = 100 })
        if r.verdict == "cheap" then cheap = true end
    end
    assert_(cheap, "a farm sells nothing below the galactic average")
end)

test("the hold, the purse and the shelf each cap a purchase", function(assert_)
    local trade = require("src.sim.trade")
    assert_(trade.take(10, 1, 1e6, 100, 999) == 10, "the hold did not cap the load")
    assert_(trade.take(999, 1, 550, 100, 999) == 5, "the purse did not cap the load")
    assert_(trade.take(999, 1, 1e6, 100, 7) == 7, "the shelf did not cap the load")
    assert_(trade.take(999, 2, 1e6, 100, 999) == 499, "volume was ignored")
    assert_(trade.take(0, 1, 0, 100, 0) == 0, "a broke pilot with no hold could still buy")

    -- the best row is the biggest bet that can actually be placed, so a
    -- bargain nobody can afford does not win
    local rows = {
        { id = "a", take = 10, upside = 200 },
        { id = "b", take = 0, upside = 9000 },
        { id = "c", take = 4, upside = 500 },
    }
    assert_(trade.best(rows).id == "c", "ranked the wrong row")
    assert_(trade.best({ { id = "a", take = 5, upside = -10 } }) == nil,
        "recommended a load that loses money")
end)

test("a colony's shortfall is what to put in the hold", function(assert_)
    local colonyMod = require("src.sim.colony")
    local trade = require("src.sim.trade")
    local c = colonyMod.found({ seed = 31, body = { type = "rock", landable = true }, day = 0 })
    c.population = 1000
    c.stockpile = { provisions = 0, water = 0, medicine = 0, machinery = 0 }
    local short = colonyMod.shortfall(c, 30)
    assert_((short.provisions or 0) > 0, "a starving colony asks for nothing")
    -- 0.9 t per 100 pop per day, 1000 pop, 30 days
    assert_(math.abs((short.provisions or 0) - 270) < 1, "shortfall: " .. tostring(short.provisions))
    c.stockpile.provisions = 1e6
    assert_(colonyMod.shortfall(c, 30).provisions == nil, "a full store still asks for more")
    assert_(trade.wanted({ c }, "water", 30) > 0, "the market cannot see the colony's needs")
    assert_(trade.wanted(nil, "water", 30) == 0, "a pilot with no colonies was asked to supply one")
end)

test("what a bar says is true and points somewhere", function(assert_)
    local rumoursMod = require("src.sim.rumours")
    local g = Galaxy.new(31)
    local stub = g:findStartSystem()
    local diplo = factions.Diplomacy.new(31)
    local place = { seed = 4242, economyId = "agricultural", population = 20000,
                    lawLevel = 0.6, techLevel = 5 }
    local player = { colonies = {}, cargo = {} }

    local list = rumoursMod.generate({
        seed = place.seed, day = 12, place = place, stub = stub,
        galaxy = g, diplomacy = diplo, player = player,
    })
    assert_(#list > 0, "the bar had nothing to say at all")

    -- the load-bearing claim: a rumour that names a system names a real one,
    -- and a demand rumour is true of that system's economy
    local commoditiesMod = require("src.sim.commodities")
    local pointed = 0
    for _, r in ipairs(list) do
        assert_(type(r.text) == "string" and #r.text > 0, "a rumour with no words")
        if r.systemId then
            pointed = pointed + 1
            local s = g:byId(r.systemId)
            assert_(s ~= nil, "a rumour points at a system that does not exist: " .. r.systemId)
            if r.kind == "demand" then
                -- the claim itself, not a proxy for it: that system's economy
                -- really does consume the thing the bar named
                local eaten = commoditiesMod.economy(s.economyId).consumes[r.cargoId] or 0
                assert_(eaten > 0, string.format(
                    "%s is said to want %s and its economy does not", s.name, r.cargoId))
                assert_(r.systemId ~= stub.id, "the bar sent the player where they stand")
            end
            if r.kind == "danger" then
                assert_((s.lawLevel or 1) < 0.25,
                    string.format("%s is called lawless at law %.2f", s.name, s.lawLevel or 1))
            end
        end
    end
    assert_(pointed > 0, "nothing said in the bar was worth steering by")

    -- the same day at the same port says the same thing
    local again = rumoursMod.generate({
        seed = place.seed, day = 12, place = place, stub = stub,
        galaxy = g, diplomacy = diplo, player = player,
    })
    assert_(#again == #list, "the bar changed its mind between two readings")
    for i = 1, #list do
        assert_(again[i].text == list[i].text, "rumour " .. i .. " differs between readings")
    end
end)

test("a noted lead lives in the log and then expires", function(assert_)
    local rumoursMod = require("src.sim.rumours")
    local player = { leads = {} }
    local r = { kind = "demand", text = "They are short of {cargo:gen:lc} in {system}",
                args = { cargo = "Grain", system = "Xeiton" }, terms = { "cargo" },
                systemId = "1.0.2.3", systemName = "Xeiton" }

    assert_(select(1, rumoursMod.note(player, r, 10)) == true, "the lead was not noted")
    assert_(#player.leads == 1, "noting produced " .. #player.leads .. " leads")
    assert_(select(1, rumoursMod.note(player, r, 12)) == false, "the same lead was noted twice")
    assert_(player.leads[1].expires == 12 + rumoursMod.LEAD_DAYS,
        "hearing it again did not refresh the note")

    local flavour = { kind = "flavour", text = "Half the bar is waiting", args = {} }
    assert_(select(1, rumoursMod.note(player, flavour, 12)) == false,
        "talk with no destination was noted as a lead")

    assert_(rumoursMod.bySystem(player)["1.0.2.3"] ~= nil, "the chart cannot find the lead")
    assert_(rumoursMod.expire(player, 20) == 0, "a fresh lead expired")
    assert_(rumoursMod.expire(player, 100) == 1, "a stale lead was kept")
    assert_(#player.leads == 0, "expiry left the lead in place")
end)

test("the mouse stick is calibrated in pixels, not in twitches", function(assert_)
    local stick = require("src.sim.stick")

    -- The defect, in one number. The stick inherited the sensitivity of the
    -- rate controller it replaced -- a fraction of full deflection per pixel,
    -- 0.0495 at its default -- so twenty pixels of hand movement put it on the
    -- rail. Sensitivity is pixels to full deflection now, and this is what
    -- that has to mean.
    local sx, sy = stick.move(0, 0, 20, 0, 320)
    assert_(sx < 0.08, string.format("20 px of mouse deflected the stick to %.2f", sx))
    sx, sy = stick.move(0, 0, 320, 0, 320)
    assert_(math.abs(sx - 1) < 1e-9, string.format("320 px gave %.3f, not full deflection", sx))

    -- clamped to a disc: a diagonal pull must not out-turn a straight one
    sx, sy = stick.move(0, 0, 900, 900, 320)
    assert_(math.abs(math.sqrt(sx * sx + sy * sy) - 1) < 1e-9,
        "the stick left the unit disc on a diagonal")

    -- dead zone snaps to zero, so hands off really is hands off
    local cx, cy, kx, ky = stick.command(0.02, 0.02)
    assert_(cx == 0 and cy == 0 and kx == 0 and ky == 0, "the dead zone leaks a command")

    -- and the curve spends the middle of the disc on small corrections
    local half = select(1, stick.command(0.5, 0))
    assert_(half < 0.5 * 0.8, string.format(
        "half deflection commands %.2f: the response curve is missing", half))
    local full = select(1, stick.command(1, 0))
    assert_(math.abs(full - 1) < 1e-9, "full deflection no longer commands a full turn")

    -- self-centring settles the ship when the hand stops
    local rx = select(1, stick.centre(1, 0, 3, stick.halfLife(3)))
    assert_(math.abs(rx - 0.5) < 1e-9, "the half-life of the self-centring is wrong")
    assert_(select(1, stick.centre(1, 0, 0, 1)) == 1, "a rate of zero still moved the stick")
end)

test("travel assist arrives instead of overshooting", function(assert_)
    local travel = require("src.sim.travel")
    local ceiling = 1e6

    -- far out it uses whatever the mass-lock ceiling allows
    local far = travel.plan(4e7, 2000, ceiling, 250)
    assert_(far.drop == false, "dropped out 40 000 km from the target")
    assert_(far.speed <= ceiling, "planned above the mass-lock ceiling")
    assert_(far.eta > 0, "no time to arrival")

    -- and the whole point: the speed falls with the distance, so the last
    -- stretch is flown at a speed the hull can actually shed
    local mid = travel.plan(1e6, 2000, ceiling, 250)
    local near = travel.plan(1e4, 2000, ceiling, 250)
    assert_(mid.speed < far.speed and near.speed < mid.speed,
        "the approach does not slow down")
    assert_(near.speed < 3000, "arriving at " .. math.floor(near.speed) .. " m/s")

    -- inside the standoff there is nothing left to do
    assert_(travel.plan(1500, 2000, ceiling, 250).drop == true, "flew past the standoff")

    -- and arriving is a band, not a point: speed proportional to distance is
    -- an exponential decay that reaches the standoff never, and a station
    -- orbiting at 100 m/s turns the last stretch into a stern chase
    assert_(travel.plan(2000 + 200, 2000, ceiling, 250).drop == true,
        "200 m short of a 2 km standoff is not counted as arrived")
    assert_(travel.plan(2000 + 4000, 2000, ceiling, 250).drop == false,
        "dropped out 4 km early")

    -- the floor stops the approach crawling, but not so close in that it
    -- becomes an overshoot: at one lookahead out, the floor is done applying
    local crawl = travel.plan(2000 + 250 * travel.LOOKAHEAD * 0.9, 2000, ceiling, 250)
    assert_(crawl.speed < 250, "the floor kept the ship fast right up to the target")

    -- A moving target is chased, not approached, unless its own speed is in
    -- the command: with a speed proportional to distance the gap settles at
    -- exactly `LOOKAHEAD` times the target's speed and stops closing.
    local chasing = travel.plan(1e5, 2000, ceiling, 250, 100)
    local still = travel.plan(1e5, 2000, ceiling, 250, 0)
    assert_(chasing.speed - still.speed > 99,
        "the target's own velocity is not in the commanded speed")

    -- and both approaches agree on where "arrived" is
    local ap = require("src.flight.autopilot")
    local contact = { station = { size = 900 } }
    assert_(ap.standoffFor(contact) == travel.standoff(contact),
        "the autopilot and the assist would drop the player in different places")
end)

test("a course is plotted through systems in range", function(assert_)
    local routeMod = require("src.sim.route")
    -- a line of stops 9 ly apart with a cloud of decoys 3 ly apart beside it:
    -- a search that counted fuel took the scenic route through the decoys to
    -- save half a percent of a tank, which is not a course anyone flies
    local all = {}
    for i = 0, 6 do all[#all + 1] = { id = "line" .. i, name = "L" .. i, x = i * 9, y = 0, z = 0 } end
    for i = 0, 20 do all[#all + 1] = { id = "dec" .. i, name = "D" .. i, x = i * 3, y = 0, z = 6 } end
    local fake = { systemsNear = function(_, x, y, z, r)
        local out = {}
        for _, v in ipairs(all) do
            local d = math.sqrt((v.x - x) ^ 2 + (v.y - y) ^ 2 + (v.z - z) ^ 2)
            if d <= r then v.distance = d; out[#out + 1] = v end
        end
        table.sort(out, function(a, b) return a.distance < b.distance end)
        return out
    end }
    local function fuel(d) return 0.6 + (d / 10) ^ 1.7 * 3.4 end

    local r = routeMod.plan({ galaxy = fake, from = all[1], to = all[7],
                              jumpRange = 10, fuelCost = fuel })
    assert_(r ~= nil, "no course over a line of systems 9 ly apart")
    assert_(r.jumps == 6, "took " .. tostring(r and r.jumps) .. " jumps where 6 would do")
    assert_(r.hops[#r.hops].id == all[7].id, "the course does not end at the destination")
    assert_(math.abs(r.fuel - 6 * fuel(9)) < 0.01, "fuel does not match the legs flown")

    -- a leg longer than the drive can manage is not a course at all
    local far = { id = "far", name = "F", x = 400, y = 0, z = 0 }
    all[#all + 1] = far
    local none, why = routeMod.plan({ galaxy = fake, from = all[1], to = far,
                                      jumpRange = 10, fuelCost = fuel })
    assert_(none == nil and why ~= nil, "plotted a course across an empty gulf")

    -- one hop when one hop does it, and no hops when you are already there
    local one = routeMod.plan({ galaxy = fake, from = all[1], to = all[2],
                                jumpRange = 10, fuelCost = fuel })
    assert_(one.jumps == 1, "a system within range took " .. one.jumps .. " jumps")
    local here = routeMod.plan({ galaxy = fake, from = all[1], to = all[1],
                                 jumpRange = 10, fuelCost = fuel })
    assert_(here.jumps == 0 and here.fuel == 0, "burned fuel going nowhere")
end)

test("a course through the real galaxy is plotted the same every time", function(assert_)
    local routeMod = require("src.sim.route")
    local g = Galaxy.new(7)
    local from = g:findStartSystem()
    local function fuel(d) return util.clamp(0.6 + (d / 10) ^ 1.7 * 3.4, 0.4, 24) end
    local near = g:systemsNear(from.x, from.y, from.z, 60, 44)
    local to = near[#near]
    local span = to.distance      -- read now: the next sweep overwrites it
    local first = routeMod.plan({ galaxy = g, from = from, to = to, jumpRange = 10, fuelCost = fuel })
    assert_(first ~= nil, "no course across 60 ly of populated space")
    assert_(first.jumps * 10 >= span * 0.9,
        "the course claims to cross " .. math.floor(span) .. " ly in " .. first.jumps .. " jumps")
    local again = routeMod.plan({ galaxy = g, from = from, to = to, jumpRange = 10, fuelCost = fuel })
    assert_(again.jumps == first.jumps and math.abs(again.fuel - first.fuel) < 1e-9,
        "the same course was plotted twice and came out different")
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

    -- The far stand-in has to be cheaper than the thing it stands in for, and
    -- has to cover the same ground: a silhouette that is not the town's shape
    -- is a different town appearing as you approach. Measured on this town:
    -- 204 triangles against 22728, and 158 m of footprint against 181.
    local lod = settlement.generateLod({ seed = 4242 }, s)
    assert_(lod ~= nil, "no silhouette mesh produced")
    assert_(lod.triangles < s.model.triangles * 0.5, string.format(
        "the silhouette is %d triangles against the town's %d -- no saving",
        lod.triangles, s.model.triangles))
    assert_(lod.radius > s.radius * 0.5, string.format(
        "the silhouette covers %.0f m against the town's %.0f", lod.radius, s.radius))
end)

test("standing water is its own mesh, and only where there is water", function(assert_)
    local Surface = require("src.procgen.surface")
    local vec3lib = require("src.lib.vec3")
    local body = {
        seed = 999, radius = 3.2e6, terrain = "ocean", atmosphere = 1.0, type = "ocean",
        pos = vec3lib(0, 0, 0), spin = 0, axialTilt = 0, gravity = 9.2, settlements = {},
    }

    local function survey(lat, lon)
        local surf = Surface.new(body)
        surf:setOrigin(lat, lon)
        for _ = 1, 150 do surf:update(0, 0, 1 / 60, 0) end
        local land, water, chunks = 0, 0, 0
        for _, c in pairs(surf.chunkCache) do
            chunks = chunks + 1
            land = land + ((c.model and c.model.triangles) or 0)
            water = water + ((c.water and c.water.triangles) or 0)
        end
        return land, water, chunks
    end

    -- inland: no water mesh at all, so a dry world pays nothing for the feature
    local dryLand, dryWater = survey(0.1, 0.3)
    assert_(dryWater == 0, "an inland patch built " .. dryWater .. " water triangles")
    assert_(dryLand > 1000, "the inland patch built no ground")

    -- open sea: nearly all water
    local seaLand, seaWater = survey(0.0, 0.0)
    assert_(seaWater > seaLand * 4, string.format(
        "open ocean came out as %d water triangles against %d of land", seaWater, seaLand))

    -- and the split moves geometry rather than adding it: water quads are
    -- *taken out* of the ground mesh, not laid over the top of it, which would
    -- z-fight with the facets it duplicated
    assert_(math.abs((dryLand + dryWater) - (seaLand + seaWater)) < (dryLand + dryWater) * 0.02,
        string.format("total geometry changed with the split: %d dry against %d wet",
            dryLand + dryWater, seaLand + seaWater))

    -- a world with no sea never even asks the question
    local barren = {
        seed = 7, radius = 3.2e6, terrain = "barren", atmosphere = 0, type = "barren",
        pos = vec3lib(0, 0, 0), spin = 0, axialTilt = 0, gravity = 5, settlements = {},
    }
    local surf = Surface.new(barren)
    assert_(surf._seaLevelMetres == nil, "a barren world reports a sea level")
end)

test("a city is the size of a city", function(assert_)
    local settlement = require("src.procgen.settlement")
    local function town(pop, tier)
        return settlement.generate({ seed = 4242, tier = tier, population = pop,
                                     economyId = "industrial", pads = 3 })
    end

    -- The defect: a world capital of four million people came out as 42 boxes
    -- in a 233 m circle -- 23 pixels from 10 km up and six from 40 km, which
    -- is why the player could not see their cities. Size follows population
    -- now, and this is the floor it has to clear.
    local city = town(4.2e6, 5)
    assert_(city.cityRadius > 750, string.format(
        "a four million city is %.0f m across", city.cityRadius * 2))
    assert_(#city.buildings > 150, "the city has only " .. #city.buildings .. " structures")
    assert_(city.districts == 4, "the largest city grew " .. city.districts .. " districts")

    -- and a hamlet is still a hamlet: this is not a global size increase
    local hamlet = town(120, 1)
    assert_(hamlet.districts == 0, "a hamlet of 120 people grew districts")
    assert_(hamlet.cityRadius < 200, "a hamlet is " .. math.floor(hamlet.cityRadius) .. " m")

    -- the budget, measured rather than hoped for
    assert_(city.triangles < 40000, string.format(
        "the city is %d triangles", city.triangles))
    local lod = settlement.generateLod({ seed = 4242 }, city)
    assert_(lod.triangles < city.triangles * 0.25, string.format(
        "the silhouette is %d against the city's %d", lod.triangles, city.triangles))
    assert_(lod.radius > city.cityRadius * 0.5, string.format(
        "the silhouette covers %.0f m of a %.0f m city", lod.radius, city.cityRadius))

    -- Districts stand on their own ground. The flattening plate only covers
    -- the core, so a city that ignored the terrain would turn a hillside into
    -- a table -- and a block on a 1-in-10 slope has to be a metre lower for
    -- every ten it stands out from the middle.
    local slope = settlement.generate({ seed = 4242, tier = 5, population = 4.2e6,
        economyId = "industrial", pads = 3,
        groundAt = function(x, z) return x * 0.1 end })
    local checked = 0
    for _, b in ipairs(slope.buildings) do
        if b.kind == "block" then
            assert_(math.abs(b.y - b.x * 0.1) < 1e-6, string.format(
                "a block at x=%.0f sits at y=%.1f on a slope that is %.1f there",
                b.x, b.y, b.x * 0.1))
            checked = checked + 1
        end
    end
    assert_(checked > 100, "only " .. checked .. " blocks were on the slope")
end)

test("the layout of a town does not depend on whether its mesh is built", function(assert_)
    -- What makes the two-stage build safe: a town in range gets its layout and
    -- silhouette (45 ms), and pays for its vertices only when the player is
    -- close (127 ms). That is only sound if both passes lay out the same town,
    -- which they do because it is the same code with the vertices thrown away.
    local settlement = require("src.procgen.settlement")
    local opts = { seed = 77, tier = 4, population = 800000, economyId = "hightech", pads = 4 }
    local full = settlement.generate(opts)
    opts.layoutOnly = true
    local layout = settlement.generate(opts)

    assert_(layout.model == nil, "the layout pass built a mesh anyway")
    assert_(#layout.buildings == #full.buildings, string.format(
        "%d buildings against %d", #layout.buildings, #full.buildings))
    assert_(math.abs(layout.cityRadius - full.cityRadius) < 1e-9, "the towns are different sizes")
    for i, b in ipairs(full.buildings) do
        local a = layout.buildings[i]
        assert_(a.x == b.x and a.z == b.z and a.kind == b.kind,
            "building " .. i .. " moved between the two passes")
    end
    -- The count is an upper bound, not an identity: a degenerate triangle is
    -- only detectable once it has been transformed, which is exactly the work
    -- the layout pass skips. Two out of thirty-two thousand, measured.
    assert_(layout.layoutTriangles >= full.triangles
        and layout.layoutTriangles < full.triangles * 1.001, string.format(
        "the layout counted %d triangles for a mesh of %d",
        layout.layoutTriangles, full.triangles))
end)

test("a walker stands on the ground that is drawn", function(assert_)
    -- The reported symptom was walking under the planet. The cause is that the
    -- ground has two heights: the analytic field, and the triangle mesh
    -- sampled from it every 108 m. Between vertices they disagree by whatever
    -- the field does in between, and a walker clamped to the analytic one ends
    -- up inside the hillside on screen.
    local Surface = require("src.procgen.surface")
    local vec3lib = require("src.lib.vec3")
    local body = {
        seed = 4242, radius = 3.2e6, terrain = "rock", atmosphere = 0.2, type = "rock",
        pos = vec3lib(0, 0, 0), spin = 0, axialTilt = 0, gravity = 6.4, settlements = {},
    }
    local surf = Surface.new(body)
    surf:setOrigin(0.2, 0.4)

    local cfg = require("src.config")
    local rng = Rng.new(11)
    local worstAnalytic, worstRendered, buried = 0, 0, 0
    local eye = cfg.walk.eyeHeight
    for _ = 1, 3000 do
        local x, z = rng:range(-4000, 4000), rng:range(-4000, 4000)
        local drawn = surf:renderedHeight(x, z)
        local gap = drawn - surf:groundHeight(x, z)
        if gap > worstAnalytic then worstAnalytic = gap end
        if gap > eye then buried = buried + 1 end
        -- the walker's own height against the mesh: this is the one that has
        -- to be zero, and it is what the fix makes true
        local err = math.abs(drawn - surf:renderedHeight(x, z))
        if err > worstRendered then worstRendered = err end
    end
    assert_(buried > 0, "the test terrain is too smooth to show the defect at all")
    assert_(worstAnalytic > eye, string.format(
        "the analytic height never sank below the mesh by more than %.1f m", worstAnalytic))
    assert_(worstRendered < 1e-6, "renderedHeight disagrees with itself")

    -- and the mesh height really is the mesh: at a vertex the two must agree
    -- exactly, because there the triangle passes through the sampled point
    -- the live resolution is the quality preset's, not the config fallback:
    -- reading the wrong one puts the "vertices" between the real ones
    local CH = cfg.render.terrainChunkSize
    local step = CH / (require("src.settings").q().terrainRes or cfg.render.terrainChunk)
    for i = 1, 20 do
        local x, z = i * step, (i * 3) * step
        assert_(math.abs(surf:renderedHeight(x, z) - surf:groundHeight(x, z)) < 1e-6,
            "the drawn height misses the vertex it is built from")
    end
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
        if not (m.reward > 0 and m.titleText and m.expires > 5) then ok = false end
        -- the rendered sentence must be complete: an unresolved {placeholder}
        -- means the template and its argument list disagree
        local title, brief = missions.title(m), missions.brief(m)
        check("mission board generates valid, varied contracts",
            #title > 0 and not title:find("{"),
            "unrendered title: " .. title)
        check("mission board generates valid, varied contracts",
            #brief > 0 and not brief:find("{"),
            "unrendered brief: " .. brief)
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
        "src.sim.player", "src.sim.stick", "src.sim.trade", "src.sim.world",
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

local settings = require("src.settings")
local lighting = require("src.render.lighting")

test("settings validate, clamp and round trip", function(assert_)
    settings.reset()
    assert_(settings.get("fov") == 74, "default missing")

    settings.set("fov", 500)
    assert_(settings.get("fov") == 105, "number not clamped high: " .. settings.get("fov"))
    settings.set("fov", -20)
    assert_(settings.get("fov") == 55, "number not clamped low")

    settings.set("lightingPreset", "nonsense")
    assert_(settings.get("lightingPreset") == "cinematic", "invalid choice accepted")

    settings.set("post", "yes")
    assert_(settings.get("post") == true, "bool not coerced")

    -- stepping wraps choices and moves numbers
    settings.set("lightingPreset", "classic")
    settings.step("lightingPreset", -1)
    assert_(settings.get("lightingPreset") == "clinical", "choice did not wrap backwards")
    local before = settings.get("scanline")
    settings.step("scanline", 1)
    assert_(settings.get("scanline") > before, "number step did nothing")

    local text = serialize.encode({ values = settings.values })
    local back = serialize.decode(text)
    assert_(back and back.values.fov == settings.get("fov"), "settings did not survive a round trip")
    settings.reset()
end)

test("every schema entry is well formed", function(assert_)
    local seen = {}
    for _, group in ipairs(settings.schema) do
        for _, item in ipairs(group.items) do
            check("every schema entry is well formed", not seen[item.id], "duplicate id " .. item.id)
            seen[item.id] = true
            check("every schema entry is well formed", item.default ~= nil, item.id .. " has no default")
            if item.type == "number" then
                check("every schema entry is well formed",
                    item.min and item.max and item.step, item.id .. " missing range")
                check("every schema entry is well formed",
                    item.default >= item.min and item.default <= item.max,
                    item.id .. " default outside its range")
            elseif item.type == "choice" then
                local ok = false
                for _, c in ipairs(item.choices or {}) do if c == item.default then ok = true end end
                check("every schema entry is well formed", ok, item.id .. " default not among choices")
            end
        end
    end
end)

test("lighting presets produce a usable environment", function(assert_)
    local vec = require("src.lib.vec3")
    for _, id in ipairs(lighting.order) do
        local env = { sunDir = vec(0, -1, 0), worldUp = vec(0, 1, 0) }
        lighting.apply(env, id)
        check("lighting presets produce a usable environment", env.fillDir ~= nil, id .. ": no fill direction")
        check("lighting presets produce a usable environment",
            math.abs(env.fillDir:length() - 1) < 1e-6, id .. ": fill direction not unit length")
        check("lighting presets produce a usable environment",
            env.fillColor and env.rimColor, id .. ": missing light colours")
        -- the fill must oppose the key, or it is a second key light
        local dot = vec.dot(env.sunDir, env.fillDir)
        check("lighting presets produce a usable environment", dot < 0.9,
            id .. ": fill is parallel to the key")
    end
    assert_(lighting.get("nonsense").name ~= nil, "unknown preset did not fall back")
end)

test("input bindings resolve and rebind", function(assert_)
    local input = require("src.input")
    settings.bindings = nil
    input.controls = nil
    assert_(input.is("boost", "lshift"), "default binding not found")
    assert_(not input.is("boost", "p"), "unbound key matched")
    assert_(input.keyName("throttleUp") == "W", "keyName wrong: " .. input.keyName("throttleUp"))

    -- rebinding keeps gamepad sources and takes effect immediately
    settings.bindings = { boost = { "key:p", "button:leftstick" } }
    input.controls = nil
    assert_(input.is("boost", "p"), "rebound key not active")
    assert_(not input.is("boost", "lshift"), "old binding still active")
    settings.bindings = nil
    input.controls = nil
end)

test("every action in the binding UI exists and is labelled", function(assert_)
    local input = require("src.input")
    for _, group in ipairs(input.actionOrder) do
        for _, action in ipairs(group[2]) do
            check("every action in the binding UI exists and is labelled",
                input.defaults[action] ~= nil, action .. " is listed but has no default binding")
            check("every action in the binding UI exists and is labelled",
                input.labels[action] ~= nil, action .. " has no label")
        end
    end
end)

test("ECS runs its systems", function(assert_)
    local ecs = require("src.ecs")
    local vec = require("src.lib.vec3")

    local hits = {}
    local world = ecs.newWorld({
        onKill = function(v, k) hits[#hits + 1] = v end,
        onImpact = function() end,
    })

    local target = ecs.add(world, {
        transform = ecs.components.transform(0, 0, -300),
        health = ecs.components.health(30, 0),
        radius = 20,
        shieldRecharge = 5,
    })
    local bolt = ecs.add(world, {
        transform = ecs.components.transform(0, 0, 0),
        velocity = ecs.components.velocity(0, 0, -2000),
        projectile = ecs.components.projectile(50),
        lifetime = ecs.components.lifetime(2),
    })

    for _ = 1, 30 do ecs.update(world, 1 / 60) end
    assert_(target.health.hull <= 0, "the bolt never hit: hull " .. target.health.hull)
    assert_(#hits == 1, "onKill fired " .. #hits .. " times")

    -- lifetimes retire entities
    local spark = ecs.add(world, {
        transform = ecs.components.transform(),
        velocity = ecs.components.velocity(),
        lifetime = ecs.components.lifetime(0.1),
    })
    for _ = 1, 20 do ecs.update(world, 1 / 60) end
    local found = false
    for _, e in ipairs(world.entities) do if e == spark then found = true end end
    assert_(not found, "an expired entity was not removed")

    -- movement integrates and gravity pulls along context up
    world.context.up = vec(0, 1, 0)
    local rock = ecs.add(world, {
        transform = ecs.components.transform(0, 100, 0),
        velocity = ecs.components.velocity(0, 0, 0),
        gravity = 10,
    })
    for _ = 1, 60 do ecs.update(world, 1 / 60) end
    assert_(rock.transform.pos.y < 100, "gravity did not pull the entity down")
end)

test("vendored libraries are present and load", function(assert_)
    for _, name in ipairs({ "lib.tiny", "lib.baton", "lib.flux" }) do
        local ok, mod = pcall(require, name)
        check("vendored libraries are present and load", ok and mod ~= nil,
            name .. ": " .. tostring(mod))
    end
end)

-- ---------------------------------------------------------------------------

local i18n = require("src.i18n")
local pois = require("src.procgen.pois")

test("localisation falls back and formats", function(assert_)
    assert_(i18n.setLocale("ru"), "russian locale failed to load")
    assert_(i18n.translate("FUEL") == "ТОПЛИВО", "known string not translated")
    assert_(i18n.translate("a string nobody translated") == "a string nobody translated",
        "unknown string did not fall back")
    -- a translation with broken placeholders must not crash the game.
    -- setLocale points i18n.strings at the shared locale table, so anything
    -- injected here has to be taken back out again.
    local injected = i18n.strings
    injected["Docked at %s"] = "Стыковка с %s"
    assert_(i18n.format("Docked at %s", "Lave") == "Стыковка с Lave", "format failed")
    injected["bad %d"] = "плохо %s %s"
    local ok = pcall(i18n.format, "bad %d", 3)
    assert_(ok, "a malformed translation crashed instead of falling back")
    injected["Docked at %s"] = nil
    injected["bad %d"] = nil
    assert_(i18n.setLocale("en"), "english locale failed")
    assert_(i18n.translate("FUEL") == "FUEL", "english should be the identity")
end)

test("every russian translation is a non-empty string", function(assert_)
    local ru = require("src.locale.ru")
    local n = 0
    for k, v in pairs(ru.strings) do
        check("every russian translation is a non-empty string",
            type(k) == "string" and type(v) == "string" and #v > 0,
            "bad entry for " .. tostring(k))
        -- placeholders must survive translation
        local srcCount = select(2, k:gsub("%%[sd]", ""))
        local dstCount = select(2, v:gsub("%%[sd]", ""))
        check("every russian translation is a non-empty string", srcCount == dstCount,
            string.format("placeholder mismatch in %q -> %q", k, v))
        -- named placeholders must survive too: a template that loses {dest}
        -- silently drops the destination from a contract brief
        for name in k:gmatch("{([%w_]+)[:%w_]*}") do
            check("every russian translation is a non-empty string",
                v:find("{" .. name, 1, true) ~= nil,
                string.format("translation of %q dropped {%s}", k, name))
        end
        n = n + 1
    end
    assert_(n > 100, "only " .. n .. " strings translated")
end)

test("russian counting rule picks the right form", function(assert_)
    i18n.setLocale("ru")
    local cases = {
        [0] = "many", [1] = "one", [2] = "few", [4] = "few", [5] = "many",
        [11] = "many", [12] = "many", [14] = "many", [15] = "many",
        [21] = "one", [22] = "few", [25] = "many", [101] = "one",
        [111] = "many", [112] = "many", [121] = "one", [1002] = "few",
    }
    for n, want in pairs(cases) do
        check("russian counting rule picks the right form", i18n.pluralForm(n) == want,
            string.format("%d should be %s, got %s", n, want, i18n.pluralForm(n)))
    end
    assert_(i18n.plural(1, "тонна", "тонны", "тонн") == "тонна", "1 t")
    assert_(i18n.plural(3, "тонна", "тонны", "тонн") == "тонны", "3 t")
    assert_(i18n.plural(17, "тонна", "тонны", "тонн") == "тонн", "17 t")
    -- English keeps the singular/plural split it has
    i18n.setLocale("en")
    assert_(i18n.plural(1, "tonne", nil, "tonnes") == "tonne", "en singular")
    assert_(i18n.plural(4, "tonne", nil, "tonnes") == "tonnes", "en plural")
end)

test("every declinable term has all six cases and three counts", function(assert_)
    i18n.setLocale("ru")
    local n = 0
    for source, term in pairs(i18n.nouns) do
        for _, c in ipairs(i18n.CASES) do
            check("every declinable term has all six cases and three counts",
                type(term[c]) == "string" and #term[c] > 0,
                string.format("%s has no %s", source, c))
        end
        for _, f in ipairs({ "one", "few", "many" }) do
            check("every declinable term has all six cases and three counts",
                type(term[f]) == "string" and #term[f] > 0,
                string.format("%s has no %s form", source, f))
        end
        -- a form that still carries a generator artefact means the pattern was
        -- wrong for that word: "наркотикя", "робототехникы", "тканй"
        for _, key in ipairs({ "nom", "gen", "dat", "acc", "ins", "pre", "one", "few", "many" }) do
            local v = term[key]
            check("every declinable term has all six cases and three counts",
                not (v:find("кы") or v:find("гы") or v:find("хы") or v:find("кя")
                     or v:find("ии[оа]") or v:find("нй")),
                string.format("%s.%s looks malformed: %s", source, key, v))
        end
        n = n + 1
    end
    assert_(n > 80, "only " .. n .. " declinable terms")
end)

test("templates decline their arguments", function(assert_)
    i18n.setLocale("ru")
    local grain = i18n.term("Grain")
    local station = i18n.term("Station")
    assert_(i18n.isNoun(grain), "Grain should be declinable")

    local out = i18n.format("Доставить {qty} {qty:t} {cargo:gen:lc} на {dest:acc}",
        { qty = 12, cargo = grain, dest = station })
    assert_(out == "Доставить 12 тонн зерна на Станцию", "got: " .. out)

    out = i18n.format("Доставить {qty} {qty:t} {cargo:gen:lc} на {dest:acc}",
        { qty = 1, cargo = grain, dest = station })
    assert_(out == "Доставить 1 тонна зерна на Станцию", "got: " .. out)

    -- the count tag agrees the noun itself with a named number
    out = i18n.format("{qty} {cargo:count:qty:lc}", { qty = 3, cargo = i18n.term("Colonists") })
    assert_(out == "3 колониста", "got: " .. out)
    out = i18n.format("{qty} {cargo:count:qty:lc}", { qty = 7, cargo = i18n.term("Colonists") })
    assert_(out == "7 колонистов", "got: " .. out)

    -- a placeholder with no argument must be visible, not silently blank
    out = i18n.format("нет {missing} тут", { qty = 1 })
    assert_(out:find("{missing}", 1, true) ~= nil, "missing argument vanished")

    -- plain strings still work as arguments
    out = i18n.format("привет {who}", { who = "Кеплер" })
    assert_(out == "привет Кеплер", "got: " .. out)
end)

test("the russian locale has no duplicate keys", function(assert_)
    -- Lua silently keeps the last of two identical keys, so a duplicate is an
    -- invisible way for one translation to shadow another
    local fh = io.open("src/locale/ru.lua", "r")
    assert_(fh ~= nil, "cannot open the locale file")
    local src = fh:read("*a")
    fh:close()
    local seen, dupes = {}, {}
    for key in src:gmatch('\n%s*%["([^"]*)"%]%s*=') do
        if seen[key] then dupes[#dupes + 1] = key end
        seen[key] = true
    end
    assert_(#dupes == 0, "duplicate keys: " .. table.concat(dupes, ", "))
end)

test("contract text renders in russian without stray placeholders", function(assert_)
    i18n.setLocale("ru")
    local g = Galaxy.new(31)
    local diplo = factions.Diplomacy.new(31)
    local sys = systemGen.build(g:findStartSystem(), diplo, 5)
    local port = systemGen.ports(sys)[1]
    assert_(port ~= nil, "no port to post contracts at")
    if not port then i18n.setLocale("en") return end
    local board = missions.generate(port, sys, g, diplo, 5, 14)
    assert_(#board > 0, "empty mission board")
    local cyrillic = 0
    for _, m in ipairs(board) do
        local title, brief = missions.title(m), missions.brief(m)
        check("contract text renders in russian without stray placeholders",
            not title:find("{") and not brief:find("{"),
            "unresolved placeholder: " .. title .. " / " .. brief)
        -- the whole point is that it came out Russian, not that it came out
        if title:find("[\208\209]") then cyrillic = cyrillic + 1 end
    end
    assert_(cyrillic == #board,
        string.format("only %d of %d titles were Russian", cyrillic, #board))
    i18n.setLocale("en")
end)

test("generated names follow the locale and agree in gender", function(assert_)
    local names = require("src.procgen.names")

    i18n.setLocale("en")
    local enSystem, enShip = names.system(4242), names.ship(313)
    assert_(not enSystem:find("[\208\209]"), "english system name is not latin: " .. enSystem)

    i18n.setLocale("ru")
    local ruSystem, ruShip = names.system(4242), names.ship(313)
    assert_(ruSystem:find("[\208\209]") ~= nil, "russian system name is not cyrillic: " .. ruSystem)
    assert_(ruSystem ~= enSystem, "the locale did not change the name")

    -- the same seed must pick the same entry in both banks, so a system keeps
    -- its identity across languages even though it changes spelling
    local bank = names.banks
    assert_(#bank.en.digrams == #bank.ru.digrams, "digram banks differ in size")
    assert_(#bank.en.stationNames == #bank.ru.stationNames, "station banks differ in size")
    assert_(#bank.en.settlementBody == #bank.ru.settlementBody, "settlement banks differ in size")
    assert_(#bank.en.shipNoun == #bank.ru.shipNoun, "ship noun banks differ in size")
    assert_(#bank.en.shipAdjective == #bank.ru.shipAdjective, "ship adjective banks differ")

    -- adjective agreement: sample widely and check that every qualifier that
    -- can inflect actually matches its noun's gender
    local ADJ = {}
    for _, adj in ipairs(bank.ru.shipAdjective) do
        ADJ[adj[1]] = "m"; ADJ[adj[2]] = "f"; ADJ[adj[3]] = "n"
    end
    local GENDER = {}
    for _, n in ipairs(bank.ru.shipNoun) do GENDER[n[1]] = n[2] end
    local checked = 0
    for seed = 1, 300 do
        local name = names.ship(seed * 13)
        local adj, noun = name:match("^(%S+) (.+)$")
        if adj and GENDER[noun] and ADJ[adj] then
            check("generated names follow the locale and agree in gender",
                ADJ[adj] == GENDER[noun],
                string.format("%s: %s is %s but %s is %s", name, adj, ADJ[adj], noun, GENDER[noun]))
            checked = checked + 1
        end
    end
    assert_(checked > 200, "only " .. checked .. " ship names were checkable")

    -- Russian station names are always "<prefix> <name-in-genitive>"; the
    -- English order swap would produce ungrammatical Russian
    local prefixes = {}
    for _, p in ipairs(bank.ru.stationPrefix) do prefixes[p] = true end
    for seed = 1, 120 do
        local st = names.station(seed * 7)
        local head = st:match("^(%S+)")
        check("generated names follow the locale and agree in gender",
            prefixes[head] == true, "station does not lead with a prefix: " .. st)
    end

    i18n.setLocale("en")
end)

test("screen layouts fit at every supported window size", function(assert_)
    -- The layout maths is pure arithmetic, so it can be checked without a
    -- graphics context. These are the constants the screens compute their
    -- lists from; the point is that at the *minimum* supported size nothing
    -- lands on top of anything, which is exactly where the old fixed row
    -- counts failed.
    local function rowsFor(height, lineHeight)
        return math.max(1, math.floor(height / math.max(lineHeight, 1)))
    end

    local SIZES = { { 960, 540 }, { 1280, 720 }, { 1920, 1080 } }
    for _, size in ipairs(SIZES) do
        local w, h = size[1], size[2]
        local where = string.format("%dx%d", w, h)

        -- port: list from y=152, footer rule at h-60, hint at h-48
        local rows = rowsFor(h - 152 - 76, 24)
        local listBottom = 152 + rows * 24
        check("screen layouts fit at every supported window size",
            listBottom <= h - 60,
            string.format("port list ends at %d, footer rule at %d (%s)",
                listBottom, h - 60, where))

        -- port: list right edge vs the side panel at w-380
        local listX = 70
        local listW = w - 380 - listX - 13 - 24
        check("screen layouts fit at every supported window size",
            listX + listW + 13 <= w - 380,
            "port list overlaps the detail panel at " .. where)

        -- settings: two panes from y=140, help rule at h-106
        local paneRows = rowsFor(h - 140 - 116, 21)
        local paneBottom = 140 + paneRows * 21
        check("screen layouts fit at every supported window size",
            paneBottom <= h - 106,
            string.format("settings list ends at %d, help rule at %d (%s)",
                paneBottom, h - 106, where))

        -- settings: the two panes must not overlap each other
        local paneW = (w - 140) * 0.5
        local left, right = 60, 80 + paneW
        local menuW = paneW - 40 - 13
        check("screen layouts fit at every supported window size",
            left + 14 + menuW + 13 <= right,
            "settings panes overlap at " .. where)

        -- colonies: list from y=100 against the same footer
        local colRows = rowsFor(h - 100 - 76, 24)
        check("screen layouts fit at every supported window size",
            100 + colRows * 24 <= h - 60,
            "colony list overruns the footer at " .. where)

        -- pause: panel sized to eight items, status below the last row
        local ph = 84 + 8 * 28 + 52
        local py = (h - ph) * 0.5
        local lastRowBottom = py + 84 + 8 * 28
        check("screen layouts fit at every supported window size",
            lastRowBottom <= py + ph - 30,
            "pause status overlaps the last menu item at " .. where)

        -- HUD: read the real layout rather than a copy of its arithmetic.
        --
        -- This used to recompute `msgBottom = h - 152` here, so the test was
        -- checking its own transcription of the geometry and the two could
        -- drift apart without anything failing.
        local hud = require("src.render.hud")
        local l = hud.layout(w, h)
        check("screen layouts fit at every supported window size",
            l.msgBottom <= l.scannerCaptionY and l.msgTop < l.msgBottom,
            string.format("hud message band %d..%d clashes with the scanner caption at %d, %s",
                l.msgTop, l.msgBottom, l.scannerCaptionY, where))
        check("screen layouts fit at every supported window size",
            l.flagsY < l.scannerCaptionY and l.flagsY > 0,
            "hud status flags land on the scanner caption at " .. where)
        check("screen layouts fit at every supported window size",
            l.leftX + l.gaugeW < l.rightX,
            "the two gauge clusters overlap at " .. where)
        check("screen layouts fit at every supported window size",
            l.targetX + l.targetW < l.bannerX,
            "the target panel runs into the system banner at " .. where)
        check("screen layouts fit at every supported window size",
            l.gaugeY + l.gaugeH <= h,
            "the gauge cluster runs off the bottom at " .. where)
    end
end)

-- The HUD's mode, which decides what the player is looking at.
--
-- Worth a head-less test for the same reason sim/context.lua is: it is a rule
-- about what matters, and a rule is easier to get right when it can be asked
-- questions without a window open.
test("the HUD emphasises what the situation calls for", function(assert_)
    local hudmode = require("src.render.hudmode")

    assert_(hudmode.resolve({}) == "space", "an empty situation is not ordinary flight")
    assert_(hudmode.resolve({ cruise = true }) == "cruise", "frame shift is not cruise")
    assert_(hudmode.resolve({ docking = true }) == "approach", "inside the mouth is not approach")
    assert_(hudmode.resolve({ horizon = true }) == "surface", "over ground is not surface")
    assert_(hudmode.resolve({ landed = true }) == "surface", "landed is not surface")
    assert_(hudmode.resolve({ hostileNear = true }) == "combat", "a hostile in range is not combat")

    -- Being shot at outranks everything else: a station is not going anywhere,
    -- and a pilot in a fight needs the fight's numbers.
    assert_(hudmode.resolve({ hostileNear = true, docking = true, cruise = true }) == "combat",
        "combat did not win over docking and cruise")

    -- and it holds for a while after the shooting stops, so the screen does
    -- not change dress between passes of a dogfight
    assert_(hudmode.resolve({ sinceCombat = 1 }) == "combat", "combat mood ends immediately")
    assert_(hudmode.resolve({ sinceCombat = hudmode.COMBAT_HOLD + 1 }) == "space",
        "combat mood never ends")
end)

test("no HUD mode hides everything", function(assert_)
    local hudmode = require("src.render.hudmode")
    for mode in pairs(hudmode.MODES) do
        local lit = 0
        for _, name in ipairs(hudmode.LAYERS) do
            local a = hudmode.alpha(mode, name)
            check("no HUD mode hides everything", a >= 0 and a <= 1,
                string.format("%s/%s has an alpha of %.2f", mode, name, a))
            if a > 0.9 then lit = lit + 1 end
        end
        -- A mode that dims everything is a blank screen with extra steps.
        check("no HUD mode hides everything", lit >= 2,
            mode .. " leaves only " .. lit .. " layers at full strength")
    end
    -- an unknown layer must dim rather than error, so adding one to the HUD
    -- cannot crash a mode that has not been told about it
    assert_(hudmode.alpha("space", "somethingNew") == hudmode.DIM,
        "an unlisted layer does not fall back to dim")
end)

test("an objective knows where to point", function(assert_)
    local objectivesMod = require("src.sim.objectives")

    local port = { pos = { x = 100, y = 200, z = 300 }, station = { name = "Anvil" } }
    local ctx = {
        player = { missions = { {
            state = "active", kind = "delivery", destSystemId = 7,
            destName = "Anvil", titleText = "Deliver grain", quantity = 1,
        } } },
        systemId = 7,
        findPort = function(name)
            return name == "Anvil" and port or nil
        end,
    }

    local obj = objectivesMod.contractSource(ctx)
    assert_(obj, "an active contract produced no objective")
    assert_(obj.marker, "a contract in this system offered no marker")
    local x, y, z = obj.marker(ctx)
    assert_(x == 100 and y == 200 and z == 300,
        string.format("the marker points at %s,%s,%s rather than at the port",
            tostring(x), tostring(y), tostring(z)))

    -- a contract for somewhere else has nothing to point at *here*, and must
    -- say so rather than pointing at a port with the same name in this system
    ctx.systemId = 9
    local away = objectivesMod.contractSource(ctx)
    assert_(away, "a contract elsewhere produced no objective at all")
    assert_(away.marker == nil, "a contract in another system still offered a marker")
end)

test("a basis rebuilt in a left-handed frame is not mirrored", function(assert_)
    local vec3lib = require("src.lib.vec3")
    local mat4lib = require("src.lib.mat4")

    local function det(a, b, c)
        return a.x * (b.y * c.z - b.z * c.y)
             - a.y * (b.x * c.z - b.z * c.x)
             + a.z * (b.x * c.y - b.y * c.x)
    end

    -- the default is unchanged: right-handed, as every call site but the
    -- surface frame relies on
    local r, u, f = vec3lib(), vec3lib(0, 1, 0), vec3lib(0, 0, 1)
    mat4lib.orthonormalize(r, u, f)
    local dRight = det(r, u, f)

    local r2, u2, f2 = vec3lib(), vec3lib(0, 1, 0), vec3lib(0, 0, 1)
    mat4lib.orthonormalize(r2, u2, f2, -1)
    local dLeft = det(r2, u2, f2)

    assert_(dRight * dLeft < 0, string.format(
        "handed = -1 did not flip the orientation: %.3f against %.3f", dRight, dLeft))
    assert_(math.abs(r.x + r2.x) < 1e-9 and math.abs(r.y + r2.y) < 1e-9
        and math.abs(r.z + r2.z) < 1e-9, "handed = -1 did not mirror right")
    -- up must still be the up that was asked for, whichever hand it is
    assert_(u.y > 0.99 and u2.y > 0.99, "the up vector was lost")

    -- and the triple stays orthonormal either way, which is the whole job
    for _, set in ipairs({ { r, u, f }, { r2, u2, f2 } }) do
        for _, v in ipairs(set) do
            local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
            check("a basis rebuilt in a left-handed frame is not mirrored",
                math.abs(len - 1) < 1e-9, "an axis is not unit length: " .. len)
        end
        local dot = set[1].x * set[2].x + set[1].y * set[2].y + set[1].z * set[2].z
        check("a basis rebuilt in a left-handed frame is not mirrored",
            math.abs(dot) < 1e-9, "right and up are not perpendicular: " .. dot)
    end
end)

test("the lead point puts the bolt and the target in the same place", function(assert_)
    local aim = require("src.sim.aim")

    -- a stationary target 1000 m away, bolt at 2000 m/s: half a second, and
    -- the lead point is the target itself
    local t = aim.time(0, 0, 1000, 0, 0, 0, 2000)
    assert_(t and math.abs(t - 0.5) < 1e-9, "flight time to a stationary target is " .. tostring(t))
    local lx, ly, lz = aim.lead(0, 0, 1000, 0, 0, 0, 2000)
    assert_(lz == 1000 and lx == 0 and ly == 0, "the lead on a stationary target moved")

    -- crossing: the lead is exactly where the target will be, which is the
    -- property that makes this worth drawing at all
    local px, py, pz, ft = aim.lead(0, 0, 1000, 200, 0, 0, 2000)
    assert_(ft, "no intercept on a crossing target")
    assert_(math.abs(px - 200 * ft) < 1e-6, "the lead is not where the target will be")
    -- and the bolt really does cover that distance in that time
    local reach = math.sqrt(px * px + py * py + pz * pz)
    assert_(math.abs(reach - 2000 * ft) < 1e-6, string.format(
        "the bolt covers %.1f m in %.3f s, which is not %.1f", reach, ft, 2000 * ft))

    -- something faster than the bolt, running away, cannot be hit, and saying
    -- so is better than drawing a ring that promises a hit
    assert_(aim.time(0, 0, 1000, 0, 0, 3000, 2000) == nil, "a target outrunning the bolt was hit")
    assert_(aim.time(0, 0, 1000, 0, 0, 2000, 2000) == nil, "a target at exactly bolt speed was hit")
    assert_(aim.time(0, 0, 1000, 0, 0, 0, 0) == nil, "a bolt with no speed still hit")
end)

test("the message strip keeps what matters", function(assert_)
    local hud = require("src.render.hud")
    local function texts(list)
        local out = {}
        for i, m in ipairs(list) do out[i] = m.text end
        return table.concat(out, ",")
    end

    -- newest first, capped at three
    local list = {}
    for _, t in ipairs({ "a", "b", "c", "d" }) do hud.push(list, t, "info") end
    assert_(#list == 3, "the strip kept " .. #list .. " lines")
    assert_(texts(list) == "d,c,b", "expected d,c,b and got " .. texts(list))

    -- a warning survives the chatter that lands on top of it
    list = {}
    hud.push(list, "warning", "warn")
    for _, t in ipairs({ "x", "y", "z" }) do hud.push(list, t, "info") end
    local kept = false
    for _, m in ipairs(list) do if m.text == "warning" then kept = true end end
    assert_(kept, "a warning was pushed off the strip by chatter: " .. texts(list))

    -- and an alert beats a warning in turn
    list = {}
    hud.push(list, "alert", "alert")
    hud.push(list, "warn1", "warn")
    hud.push(list, "warn2", "warn")
    hud.push(list, "warn3", "warn")
    assert_(list[#list].text == "alert" or texts(list):find("alert"),
        "the alert did not survive three warnings: " .. texts(list))

    -- the same line again refreshes rather than stacking
    list = {}
    assert_(hud.push(list, "same", "warn") == true, "a new line reported as a repeat")
    list[1].life = 1
    assert_(hud.push(list, "same", "warn") == false, "a repeat reported as new")
    assert_(#list == 1, "a repeated line stacked: " .. texts(list))
    assert_(list[1].life > 1, "a repeated line did not have its life refreshed")
end)

test("text fitting never returns something wider than asked", function(assert_)
    -- ui.fit does the width maths; without a graphics context we can still
    -- check the byte-level contract that stops it splitting a UTF-8 character
    local ui = require("src.ui.widgets")
    assert_(type(ui.fit) == "function", "ui.fit is missing")

    -- a fake font: every byte is one unit wide, so widths are predictable
    local fake = {
        getWidth = function(_, s) return #s end,
        getHeight = function() return 10 end,
    }
    local realFont = ui.font
    ui.font = function() return fake end

    assert_(ui.fit("hello", 100) == "hello", "short strings must pass through")
    local cut = ui.fit("hello world", 8)
    assert_(#cut <= 8, "fit returned " .. #cut .. " units for a limit of 8")
    assert_(cut:sub(-3) == "...", "truncated text should end in an ellipsis")

    -- Cyrillic: two bytes per letter, so a naive cut lands mid-character
    local ru = "Молчаливый"
    local cutRu = ui.fit(ru, 9)
    local trimmed = cutRu:gsub("%.%.%.$", "")
    check("text fitting never returns something wider than asked",
        #trimmed % 2 == 0, "cut a Cyrillic character in half: " .. cutRu)

    ui.font = realFont
end)

test("belts contain rocks that can actually be mined out", function(assert_)
    local mining = require("src.sim.mining")
    local g = Galaxy.new(31)
    local diplo = factions.Diplomacy.new(31)

    -- find a system that has a belt at all
    local sys
    for _, stub in ipairs(g:systemsNear(0, 0, 0, 60)) do
        local s = systemGen.build(stub, diplo, 5)
        if s.belts and #s.belts > 0 then sys = s break end
    end
    assert_(sys ~= nil, "no system with an asteroid belt nearby")
    if not sys then return end

    local belt = sys.belts[1]
    local damage = {}

    -- a point on the belt's ring
    local x, z = belt.radius, 0
    local rocks = mining.near(sys, x, 0, z, damage)
    assert_(#rocks > 0, "a belt with density " .. belt.density .. " produced no rocks")

    -- deterministic: the same point gives the same field
    local again = mining.near(sys, x, 0, z, damage)
    assert_(#again == #rocks, "rock field is not deterministic")
    if #rocks > 0 and #again > 0 then
        assert_(rocks[1].key == again[1].key, "rock identity changed between calls")
    end

    -- outside the belt there is nothing
    local none = mining.near(sys, belt.radius * 3, 0, 0, damage)
    assert_(#none == 0, "found rocks outside the belt")

    -- mining a rock yields ore and eventually exhausts it
    local rock = rocks[1]
    local total, guard = 0, 0
    local oreId
    while not mining.exhausted(rock) and guard < 10000 do
        local ore, tonnes = mining.hit(rock, 25, damage)
        if ore then oreId, total = ore, total + tonnes end
        guard = guard + 1
    end
    assert_(guard < 10000, "the rock never ran out")
    assert_(total > 0, "mining a rock to destruction yielded nothing")
    assert_(oreId ~= nil and commodities.byId[oreId] ~= nil,
        "mining produced an unknown commodity: " .. tostring(oreId))

    -- damage persists, so a worked rock does not come back whole
    local after = mining.near(sys, x, 0, z, damage)
    local found = false
    for _, r in ipairs(after) do
        if r.key == rock.key then found = true end
    end
    assert_(not found, "an exhausted rock reappeared intact")
end)

test("rank climbs monotonically and never skips its gates", function(assert_)
    local progression = require("src.sim.progression")
    local p = Player.new({ seed = 1 })

    assert_(progression.rank(p).id == "harmless", "a new pilot is not Harmless")
    assert_(progression.next(p) ~= nil, "there is no rank above the first")

    -- credits alone must not promote: a rich pilot who has done nothing is
    -- still inexperienced, and vice versa
    p.credits = 5000000
    assert_(progression.rank(p).id ~= "elite", "wealth alone reached the top rank")

    -- experience alone must not promote either
    p = Player.new({ seed = 1 })
    p.record.kills = 400
    assert_(progression.rank(p).id ~= "elite", "experience alone reached the top rank")

    -- Climbing both together must never demote, and every rank must be
    -- reachable. Skipping a rank is legitimate -- a windfall should be able to
    -- jump two -- so what is checked is monotonicity, and that a gradual climb
    -- actually visits each rung rather than leaving some unreachable.
    p = Player.new({ seed = 1 })
    local function indexOf(id)
        for i, r in ipairs(progression.RANKS) do if r.id == id then return i end end
        return 0
    end
    local visited, lastIndex = {}, indexOf(progression.rank(p).id)
    for step = 1, 2000 do
        p.credits = step * 2600
        p.record.trades = math.floor(step * 0.3)
        p.record.profit = step * 2500
        p.record.kills = math.floor(step * 0.15)
        p.record.jumps = math.floor(step * 0.3)
        p.record.missionsDone = math.floor(step * 0.12)
        local idx = indexOf(progression.rank(p).id)
        check("rank climbs monotonically and never skips its gates",
            idx >= lastIndex, "rank went backwards at step " .. step)
        visited[idx] = true
        lastIndex = idx
    end
    assert_(lastIndex == #progression.RANKS,
        "a gradual climb topped out at rank " .. lastIndex .. " of " .. #progression.RANKS)
    for i = 1, #progression.RANKS do
        check("rank climbs monotonically and never skips its gates",
            visited[i] == true,
            "rank " .. progression.RANKS[i].id .. " is unreachable by a gradual climb")
    end

    -- progress is bounded and monotone within a rank
    p = Player.new({ seed = 1 })
    local prev = -1
    for step = 0, 40 do
        p.credits = step * 150
        local f = progression.progress(p)
        check("rank climbs monotonically and never skips its gates",
            f >= 0 and f <= 1, "progress out of range: " .. f)
        if progression.rank(p).id == "harmless" then
            check("rank climbs monotonically and never skips its gates",
                f >= prev - 1e-9, "progress fell inside a rank")
            prev = f
        end
    end

    -- promotion fires once per rank
    p = Player.new({ seed = 1 })
    progression.check(p)                     -- first call only records
    p.credits = 500000
    p.record.trades = 200
    p.record.profit = 900000
    local first = progression.check(p)
    assert_(first ~= nil, "promotion was never announced")
    assert_(progression.check(p) == nil, "promotion announced twice for one rank")
end)

test("the tutorial chain advances, skips and finishes", function(assert_)
    local tutorial = require("src.sim.tutorial")
    local p = Player.new({ seed = 5 })
    local state = tutorial.newState()
    local ctx = { player = p, flight = { throttle = 0 } }

    local first = tutorial.current(state, ctx)
    assert_(first ~= nil and first.id == "look", "the chain did not start at the first step")

    -- doing what a step asks advances exactly one step
    ctx.flight.throttle = 1
    local second = tutorial.current(state, ctx)
    assert_(second ~= nil and second.id == "target", "did not advance to the target step")

    -- a step already satisfied is skipped rather than replayed: satisfy the
    -- next three at once and the chain should land past all of them
    ctx.flight.target = { station = {} }
    ctx.flight.autopilot = true
    p.record.dockings = 1
    local after = tutorial.current(state, ctx)
    assert_(after ~= nil and after.id == "buy",
        "expected to skip to 'buy', landed on " .. tostring(after and after.id))

    -- The whole chain completes and stays completed.
    --
    -- The list below is every step's completion condition, which is the point:
    -- when the chain grew past "step outside" into mining, fighting,
    -- outfitting and colonies, this test is what says whether the new steps
    -- can be finished at all rather than parking the player on one for ever.
    p.cargo = { grain = 3 }
    p.record.jumps = 2
    p.record.trades = 5
    p.missions = { {} }
    p.record.landings = 1
    p.record.walked = 1
    p.record.scanned = 1
    p.record.mined = 4
    p.record.fitted = 1
    p.record.kills = 1
    p.record.coloniesFounded = 1
    assert_(tutorial.current(state, ctx) == nil, "the chain did not finish")
    assert_(state.done == true, "the chain did not mark itself done")
    assert_(tutorial.current(state, ctx) == nil, "a finished chain produced a step again")

    -- every step must declare the fields the UI reads
    for _, step in ipairs(tutorial.STEPS) do
        check("the tutorial chain advances, skips and finishes",
            type(step.id) == "string" and #step.id > 0, "a step has no id")
        check("the tutorial chain advances, skips and finishes",
            type(step.text) == "string" and #step.text > 0, step.id .. " has no text")
        check("the tutorial chain advances, skips and finishes",
            type(step.done) == "function", step.id .. " has no completion test")
        -- a hint that names a key must declare which action it means, or the
        -- placeholder will print itself to the player
        if step.hint then
            for name in step.hint:gmatch("{([%w_]+)}") do
                local declared = false
                for _, k in ipairs(step.keys or {}) do
                    if k == name then declared = true end
                end
                check("the tutorial chain advances, skips and finishes", declared,
                    string.format("%s uses {%s} but does not list it in keys", step.id, name))
            end
        end
    end
end)

test("objectives pick one source by priority", function(assert_)
    local objectives = require("src.sim.objectives")
    local tracker = objectives.tracker()
    tracker:addSource("low", 9, function() return { id = "low", text = "low" } end)
    tracker:addSource("high", 1, function() return { id = "high", text = "high" } end)
    local obj = tracker:update({})
    assert_(obj ~= nil and obj.id == "high", "priority was not respected")
    assert_(obj.source == "high", "the source name was not attached")

    -- a source that errors must not take the tracker down with it
    local t2 = objectives.tracker()
    t2:addSource("broken", 1, function() error("boom") end)
    t2:addSource("ok", 2, function() return { id = "ok", text = "ok" } end)
    local obj2 = t2:update({})
    assert_(obj2 ~= nil and obj2.id == "ok", "a broken source blocked the rest")

    -- nothing to do is a valid answer
    local t3 = objectives.tracker()
    t3:addSource("none", 1, function() return nil end)
    assert_(t3:update({}) == nil, "an empty tracker invented an objective")
end)

test("letter case helpers handle cyrillic", function(assert_)
    assert_(i18n.lcFirst("Зерно") == "зерно", "lc cyrillic")
    assert_(i18n.lcFirst("Руда") == "руда", "lc cyrillic р-я range")
    assert_(i18n.lcFirst("Ёмкость") == "ёмкость", "lc yo")
    assert_(i18n.ucFirst("зерно") == "Зерно", "uc cyrillic")
    assert_(i18n.ucFirst("руда") == "Руда", "uc cyrillic р-я range")
    assert_(i18n.ucFirst("ёмкость") == "Ёмкость", "uc yo")
    assert_(i18n.lcFirst("Fuel") == "fuel", "lc ascii still works")
    assert_(i18n.ucFirst("") == "", "empty string")
end)

test("points of interest are deterministic and spread out", function(assert_)
    local a = pois.spaceAt(4242, 3, 0, -7)
    local b = pois.spaceAt(4242, 3, 0, -7)
    if a then
        assert_(b ~= nil and a.kind == b.kind and a.x == b.x, "space POI is not deterministic")
    end
    local found, cells = 0, 0
    for cx = -12, 12 do
        for cz = -12, 12 do
            cells = cells + 1
            if pois.spaceAt(4242, cx, 0, cz) then found = found + 1 end
        end
    end
    assert_(found > 0, "no points of interest anywhere")
    local density = found / cells
    assert_(density > 0.15 and density < 0.5,
        string.format("density %.2f is not a sensible scatter", density))

    -- every kind must produce a mesh
    for _, kind in ipairs(pois.SPACE_KINDS) do
        local p = { kind = kind.id, seed = 7, scale = 1 }
        local model = pois.spaceMesh(p)
        check("points of interest are deterministic and spread out", model ~= nil,
            kind.id .. " produced no mesh")
        if model then
            check("points of interest are deterministic and spread out", model.triangles > 4,
                kind.id .. " mesh is nearly empty")
        end
    end
end)

test("surface points of interest build", function(assert_)
    local found = 0
    for cx = -8, 8 do
        for cz = -8, 8 do
            if pois.surfaceAt(991, cx, cz) then found = found + 1 end
        end
    end
    assert_(found > 0, "no surface features anywhere")

    for _, kind in ipairs(pois.SURFACE_KINDS) do
        local p = { kind = kind.id, seed = 31, rot = 0, radius = 60 }
        local built = pois.surfaceMesh(p)
        check("surface points of interest build", built and built.model ~= nil,
            kind.id .. " produced no mesh")
        if built and built.model then
            check("surface points of interest build", built.model.triangles > 8,
                kind.id .. " is nearly empty")
            -- must not sink far below the ground it stands on
            check("surface points of interest build", built.model.min[2] > -12,
                kind.id .. " sinks to " .. built.model.min[2])
        end
    end
end)

test("hints react to context", function(assert_)
    local hints = require("src.render.hints")
    local plain = hints.flight({})
    local landing = hints.flight({ hoverMode = true })
    assert_(#plain > 3, "no hints produced")

    local function has(list, label)
        for _, h in ipairs(list) do if h.label:find(label, 1, true) then return true end end
        return false
    end
    -- landing mode swaps combat hints for translation thrusters
    assert_(has(landing, "Strafe") or has(landing, "Смещение"), "landing hints lack strafe")
    assert_(not (has(landing, "Fire") or has(landing, "Огонь")), "landing hints still show weapons")
    -- The context line names the action rather than the situation, and only
    -- appears when there is one: this is the single row that replaced the
    -- separate dock / enter / disembark / board hints.
    assert_(not (has(plain, "Dock") or has(plain, "Стыковка")), "dock hint shown with nothing to dock")
    local gameContext2 = require("src.sim.context")
    local docking = hints.flight({ contextVerb = gameContext2.verb("dock") })
    assert_(has(docking, "Dock") or has(docking, "Стыковка"), "dock hint missing when docking")
    local scooping = hints.flight({ contextVerb = gameContext2.verb("scoop") })
    assert_(not (has(scooping, "Dock") or has(scooping, "Стыковка")),
        "the context hint still says dock when it would scoop")

    local foot = hints.onFoot({ contextVerb = gameContext2.verb("board") })
    assert_(#foot > 3, "no on-foot hints")
    assert_(has(foot, "Board") or has(foot, "На борт"), "boarding hint missing next to the ship")
end)

-- ---------------------------------------------------------------------------
-- Biomes and ground cover.

test("a planet is not one biome from pole to pole", function(assert_)
    local biomeMod = require("src.procgen.biome")
    local terrainMod = require("src.procgen.terrain")
    local galaxy = require("src.procgen.galaxy").new(20250811)
    local sysMod = require("src.procgen.system")
    local sys = sysMod.build(galaxy:findStartSystem(),
        require("src.sim.factions").Diplomacy.new(20250811), 5)

    local checked = 0
    for _, body in ipairs(sysMod.landables(sys)) do
        if body.landable and not body.giant then
            checked = checked + 1
            local field = terrainMod.field(body)
            local seen = {}
            local n = 0
            -- sweep the whole sphere, not one patch
            for i = 0, 23 do
                for j = 0, 11 do
                    local lat = (j / 11 - 0.5) * math.pi * 0.98
                    local lon = i / 24 * math.pi * 2
                    local cl = math.cos(lat)
                    local h = field:heightDir(cl * math.cos(lon), math.sin(lat), cl * math.sin(lon))
                    local b = field.climate:at(lat, lon, h)
                    if not seen[b.id] then seen[b.id] = true n = n + 1 end
                end
            end
            assert_(n >= 3, body.name .. " (" .. tostring(body.terrain)
                .. ") has only " .. n .. " biome(s) over its whole surface")
            -- and nothing may appear on a class that forbids it
            for id in pairs(seen) do
                local def = biomeMod.byId[id]
                assert_(def, "unknown biome id " .. id)
                assert_(not def.classes or def.classes[field.kind],
                    id .. " appeared on a " .. field.kind .. " world, which forbids it")
            end
        end
    end
    assert_(checked > 0, "no landable worlds to check")
end)

test("the climate is deterministic and its lattice does not show", function(assert_)
    local terrainMod = require("src.procgen.terrain")
    local galaxy = require("src.procgen.galaxy").new(20250811)
    local sysMod = require("src.procgen.system")
    local sys = sysMod.build(galaxy:findStartSystem(),
        require("src.sim.factions").Diplomacy.new(20250811), 5)
    local body
    for _, b in ipairs(sysMod.landables(sys)) do
        if b.landable and not b.giant then body = b break end
    end
    assert_(body, "no landable world")
    local field = terrainMod.field(body)

    -- same question, same answer, cold cache or warm
    local a = { field.climate:base(0.3, 0.7) }
    field.climate.cache, field.climate.cacheCount = {}, 0
    local b = { field.climate:base(0.3, 0.7) }
    for i = 1, 3 do
        assert_(math.abs(a[i] - b[i]) < 1e-12, "the climate changed when its cache was dropped")
    end

    -- The lattice is interpolated, so walking a line must not produce steps:
    -- a jump between adjacent samples would show as a visible cell edge.
    local prev
    local worst = 0
    for i = 0, 400 do
        local lon = 0.7 + i * 0.0004      -- ~2.5 km steps at planetary scale
        local t = field.climate:base(0.3, lon)
        if prev then worst = math.max(worst, math.abs(t - prev)) end
        prev = t
    end
    assert_(worst < 0.02, "the climate steps by " .. worst .. " between samples")
end)

test("ground cover follows the biome and sits on the drawn ground", function(assert_)
    local terrainMod = require("src.procgen.terrain")
    local flora = require("src.procgen.flora")
    local galaxy = require("src.procgen.galaxy").new(20250811)
    local sysMod = require("src.procgen.system")
    local sys = sysMod.build(galaxy:findStartSystem(),
        require("src.sim.factions").Diplomacy.new(20250811), 5)
    local body
    for _, b in ipairs(sysMod.landables(sys)) do
        if b.landable and not b.giant then body = b break end
    end
    local field = terrainMod.field(body)
    field:setOrigin(0.12, 0.4)

    -- every kind a biome asks for must be something flora can build
    local biomeMod = require("src.procgen.biome")
    for _, def in ipairs(biomeMod.LIST) do
        for _, entry in ipairs(def.scatter) do
            assert_(flora.KINDS[entry.kind] ~= nil,
                def.id .. " grows '" .. entry.kind .. "', which flora cannot build")
        end
    end

    local res, size = 24, 900
    local step = size / res
    local hs = {}
    for j = 0, res do
        hs[j] = {}
        for i = 0, res do hs[j][i] = field:height(i * step, j * step) end
    end
    local model = field:buildScatter(0, 0, size, 1, hs, res)
    assert_(model and model.triangles > 0, "an ordinary chunk grew nothing at all")

    -- deterministic
    local again = field:buildScatter(0, 0, size, 1, hs, res)
    assert_(again.triangles == model.triangles, "ground cover is not deterministic")

    -- density zero means nothing, for the lowest quality preset
    local none = field:buildScatter(0, 0, size, 0, hs, res)
    assert_(not none or none.triangles == 0, "density 0 still grew something")
end)

test("two worlds of the same class do not come out the same colour", function(assert_)
    -- A planet class only unlocks a handful of biomes, and they share their
    -- palettes, so every barren world used to be the same drab grey-brown as
    -- every other barren world. Each body carries its own cast now.
    local terrainMod = require("src.procgen.terrain")
    local galaxy = require("src.procgen.galaxy").new(20250811)
    local sysMod = require("src.procgen.system")
    local diplo = require("src.sim.factions").Diplomacy.new(20250811)

    local byKind = {}
    local start = galaxy:findStartSystem()
    local stubs = galaxy:systemsNear(start.x, start.y, start.z, 80, 40)
    for i = 1, math.min(#stubs, 26) do
        local sys = sysMod.build(stubs[i], diplo, 5)
        for _, b in ipairs(sysMod.landables(sys)) do
            if b.landable and not b.giant then
                local f = terrainMod.field(b)
                byKind[f.kind] = byKind[f.kind] or {}
                table.insert(byKind[f.kind], f.worldTint)
            end
        end
    end

    local checked = 0
    for kind, tints in pairs(byKind) do
        if #tints >= 3 then
            checked = checked + 1
            -- the ratio of red to blue is what separates a rusty world from a
            -- cold one; it must not be the same number for all of them
            local lo, hi = math.huge, -math.huge
            for _, t in ipairs(tints) do
                local ratio = t[1] / t[3]
                lo, hi = math.min(lo, ratio), math.max(hi, ratio)
            end
            assert_(hi - lo > 0.15, kind .. " worlds all share the same cast ("
                .. #tints .. " of them, spread " .. string.format("%.3f", hi - lo) .. ")")
        end
    end
    assert_(checked > 0, "not enough worlds of any one class to compare")
end)

test("ground colour varies from facet to facet", function(assert_)
    local terrainMod = require("src.procgen.terrain")
    local galaxy = require("src.procgen.galaxy").new(20250811)
    local sysMod = require("src.procgen.system")
    local sys = sysMod.build(galaxy:findStartSystem(),
        require("src.sim.factions").Diplomacy.new(20250811), 5)
    local body
    for _, b in ipairs(sysMod.landables(sys)) do
        if b.landable and not b.giant then body = b break end
    end
    local field = terrainMod.field(body)
    field:setOrigin(0.12, 0.4)

    -- across a patch the size of a chunk, neighbouring facets must differ:
    -- identical colours over tens of metres is the flat wash of paint this
    -- replaces
    local lo, hi = math.huge, -math.huge
    local samples = 0
    for i = 0, 20 do
        for j = 0, 20 do
            local x, z = i * 40, j * 40
            local h = field:height(x, z)
            if not field:isWater(h) then
                local c = field:colorAt(x, z, h, 0.95)
                local lum = c[1] * 0.3 + c[2] * 0.59 + c[3] * 0.11
                lo, hi = math.min(lo, lum), math.max(hi, lum)
                samples = samples + 1
            end
        end
    end
    assert_(samples > 50, "not enough dry ground to sample")
    assert_(hi - lo > 0.03, "the ground is one flat tone (spread "
        .. string.format("%.4f", hi - lo) .. ")")

    -- and it must still be deterministic
    local h = field:height(200, 200)
    local a = field:colorAt(200, 200, h, 0.95)
    local b = field:colorAt(200, 200, h, 0.95)
    for i = 1, 3 do assert_(a[i] == b[i], "ground colour is not deterministic") end
end)

-- ---------------------------------------------------------------------------
-- Walking around a settlement.

test("a walker is pushed out of every building, not just the first", function(assert_)
    local settlementMod = require("src.procgen.settlement")
    -- two buildings with a gap too narrow to stand in
    local detail = {
        buildings = {
            { x = -6, z = 0, radius = 6 },
            { x = 6, z = 0, radius = 6 },
        },
        pads = {}, radius = 60, plateRadius = 56,
    }
    -- Standing in the gap, which is narrower than the player: whatever else
    -- happens, they must not be left inside a wall.
    local x, z = settlementMod.collide(detail, 0, 0, 0.6)
    local deepest = 0
    for _, b in ipairs(detail.buildings) do
        local d = math.sqrt((x - b.x) ^ 2 + (z - b.z) ^ 2)
        deepest = math.max(deepest, (b.radius * 0.92 + 0.6) - d)
    end
    assert_(deepest < 1e-6, string.format("left standing %.2f m inside a wall", deepest))

    -- and the ordinary case: pushed clear of a single building
    local sx, sz = settlementMod.collide(detail, -6, 1, 0.6)
    local sd = math.sqrt((sx + 6) ^ 2 + (sz - 0) ^ 2)
    assert_(sd >= 6 * 0.92 + 0.6 - 1e-6, string.format(
        "not pushed clear of a single building: %.2f", sd))
    -- and somebody in the clear is not moved at all
    local cx, cz = settlementMod.collide(detail, 40, 40, 0.6)
    assert_(cx == 40 and cz == 40, "a walker in open ground was shoved")
end)

test("the settlement plate blends into the terrain at its rim", function(assert_)
    local settlementMod = require("src.procgen.settlement")
    local detail = { buildings = {}, pads = {}, radius = 60, plateRadius = 56 }
    assert_(settlementMod.plateBlend(detail, 0, 0) == 1, "the middle of the plate is not solid")
    assert_(settlementMod.plateBlend(detail, 100, 0) == 0, "the plate extends past the settlement")
    local edge = settlementMod.plateBlend(detail, 57, 0)
    assert_(edge > 0 and edge < 1, "the rim is a step rather than a blend")
    -- monotone, so walking outwards never climbs back onto the plate
    local prev = 2
    for d = 0, 70, 2 do
        local k = settlementMod.plateBlend(detail, d, 0)
        assert_(k <= prev + 1e-9, "the plate blend is not monotone at " .. d)
        prev = k
    end
end)

-- ---------------------------------------------------------------------------
-- The control scheme.
--
-- The whole point of the rework is that the scheme cannot grow back. These
-- tests are the thing stopping it.

test("the core scheme fits on a dozen keys", function(assert_)
    local input = require("src.input")
    -- keyboard only: the mouse buttons are not part of the count, and neither
    -- is anything outside CORE
    local keys = {}
    for _, action in ipairs(input.CORE) do
        assert_(input.defaults[action] ~= nil, action .. " is in CORE but is not bound")
        for _, src in ipairs(input.defaults[action]) do
            local k = src:match("^key:(.+)$") or src:match("^sc:(.+)$")
            if k then keys[k] = true break end
        end
    end
    local distinct = 0
    for _ in pairs(keys) do distinct = distinct + 1 end
    -- twelve for playing, plus escape and F1
    assert_(distinct <= 14, "the core scheme uses " .. distinct .. " distinct keys")
    -- and the help panels must only ever show core bindings
    for _, entry in ipairs(input.flightHelp) do
        local list = type(entry) == "table" and entry or { entry }
        for _, action in ipairs(list) do
            assert_(input.isCore[action], "flightHelp lists a non-core action: " .. action)
        end
    end
end)

test("no two core actions fight over the same key in the same place", function(assert_)
    local input = require("src.input")
    -- Some pairs share a key on purpose, because only one of the two is ever
    -- live: WASD flies the ship in the cockpit and walks the player outside
    -- it, space is cruise in the ship and jump on foot, shift is boost and
    -- sprint. That is the same key doing the same *kind* of thing in both
    -- places, which is the point. Anything else sharing a key is a conflict.
    local allowed = {
        ["jump|warp"] = true, ["boost|run"] = true,
        ["throttleUp|walkForward"] = true, ["throttleDown|walkBack"] = true,
        ["rollLeft|walkLeft"] = true, ["rollRight|walkRight"] = true,
    }
    local byKey = {}
    for _, action in ipairs(input.CORE) do
        for _, src in ipairs(input.defaults[action] or {}) do
            local k = src:match("^key:(.+)$") or src:match("^sc:(.+)$")
            if k then
                byKey[k] = byKey[k] or {}
                table.insert(byKey[k], action)
            end
        end
    end
    for k, list in pairs(byKey) do
        if #list > 1 then
            table.sort(list)
            assert_(allowed[table.concat(list, "|")],
                "key " .. k .. " is bound to " .. table.concat(list, ", "))
        end
    end
end)

test("every bound action has a label and appears in the rebinding screen", function(assert_)
    local input = require("src.input")
    local listed = {}
    for _, section in ipairs(input.actionOrder) do
        for _, action in ipairs(section[2]) do listed[action] = true end
    end
    for action in pairs(input.defaults) do
        assert_(input.labels[action] ~= nil, action .. " has no label")
        if action ~= "save" and action ~= "load" then
            assert_(listed[action], action .. " cannot be rebound: it is in no section")
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The context action.

local gameContext = require("src.sim.context")

test("the context key offers one action, in priority order", function(assert_)
    local station = { name = "Alpha" }
    local place = { name = "Beta" }

    local a = gameContext.resolve({ station = station, landed = true, canister = {} })
    assert_(a and a.kind == "dock", "docking did not win")

    a = gameContext.resolve({ station = station, stationBlocked = true, blockedReason = "too fast" })
    assert_(a and a.kind == "dock" and a.blocked, "a blocked dock is not reported as blocked")
    assert_(a.text == "too fast", "the blocked reason was not passed through")

    a = gameContext.resolve({ landedPlace = place, landed = true })
    assert_(a and a.kind == "enterSettlement", "landing at a settlement did not offer the settlement")

    a = gameContext.resolve({ landed = true })
    assert_(a and a.kind == "disembark", "landed with nothing around did not offer disembark")

    a = gameContext.resolve({ canister = { id = "ore" }, canisterName = "Ore" })
    assert_(a and a.kind == "scoop", "loose cargo was not offered")

    assert_(gameContext.resolve({}) == nil, "an empty situation produced an action")
end)

test("on foot the door beats the ship", function(assert_)
    local a = gameContext.resolve({ walking = true, nearShip = true,
                                    building = { name = "Market Hall" } })
    assert_(a and a.kind == "enterBuilding", "standing in a doorway offered the ship instead")
    a = gameContext.resolve({ walking = true, nearShip = true })
    assert_(a and a.kind == "board", "next to the ship, boarding was not offered")
    -- and a walking player is never offered something only a ship can do
    a = gameContext.resolve({ walking = true, station = { name = "Alpha" }, canister = {} })
    assert_(a == nil, "a pedestrian was offered a docking clamp")
end)

test("the prompt always names the action the key will run", function(assert_)
    -- the defect this replaces: the prompt said "U to disembark" while the key
    -- that did it had been rebound, because they were written out separately
    for _, s in ipairs({
        { station = { name = "Alpha" }, key = "Q" },
        { landedPlace = { name = "Beta" }, key = "Q" },
        { landed = true, key = "Q" },
        { walking = true, nearShip = true, key = "Q" },
    }) do
        local a = gameContext.resolve(s)
        assert_(a ~= nil, "no action for a situation that has one")
        assert_(a.text:find("Q", 1, true) ~= nil,
            "the prompt does not mention the key: " .. tostring(a.text))
    end
end)

-- ---------------------------------------------------------------------------
-- Salvage.

local salvage = require("src.sim.salvage")

local function fakeWreck(seed, value, kind)
    return {
        seed = seed, cargoValue = value, aiKind = kind or "trader", radius = 12,
        pos = vec3(100, 0, 0), vel = vec3(0, 0, 0),
    }
end

test("a wreck spills a manifest that matches what it was carrying", function(assert_)
    local rich = salvage.manifest(fakeWreck(7, 40000, "trader"))
    local poor = salvage.manifest(fakeWreck(7, 300, "trader"))
    local empty = salvage.manifest(fakeWreck(7, 0, "trader"))
    local function tonnes(m)
        local t = 0
        for _, item in ipairs(m) do t = t + item.tonnes end
        return t
    end
    assert_(tonnes(rich) > tonnes(poor), "a rich hold spilled no more than a poor one")
    assert_(#empty == 0, "a ship with no cargo still spilled some")
    -- deterministic: the same wreck always spills the same thing
    local again = salvage.manifest(fakeWreck(7, 40000, "trader"))
    assert_(#again == #rich, "the same wreck spilled a different number of canisters")
    for i, item in ipairs(rich) do
        assert_(again[i].id == item.id and again[i].tonnes == item.tonnes,
            "salvage is not deterministic")
    end
    -- and a commodity that exists
    local commoditiesMod = require("src.sim.commodities")
    for _, item in ipairs(rich) do
        assert_(commoditiesMod.get(item.id) ~= nil, "spilled an unknown commodity: " .. item.id)
    end
end)

test("canisters drift, expire, and can be found by proximity", function(assert_)
    local list = {}
    salvage.fromWreck(list, fakeWreck(11, 30000, "pirate"))
    assert_(#list > 0, "a pirate with a full hold spilled nothing")
    local first = list[1]
    local x0 = first.pos.x
    salvage.update(list, 1.0)
    assert_(first.pos.x ~= x0 or first.vel.x == 0, "canisters do not drift")

    local found, dist = salvage.nearest(list, first.pos.x, first.pos.y, first.pos.z, 1000)
    assert_(found ~= nil and dist < 1, "the nearest canister was not the one underfoot")
    assert_(salvage.nearest(list, 1e9, 0, 0, salvage.SCOOP_RANGE) == nil,
        "a canister half a system away was in scoop range")

    salvage.update(list, salvage.LIFETIME + 1)
    assert_(#list == 0, "canisters never expire")
end)

test("scooping fills the hold and leaves the remainder behind", function(assert_)
    local Player = require("src.sim.player")
    local list = {}
    local can = { id = "ore", tonnes = 10, pos = vec3(), vel = vec3(), life = 60 }
    list[1] = can

    local player = Player.new()
    player.cargo = {}
    -- fill all but three tonnes
    local free = player:cargoFree()
    if free > 3 then player:addCargo("water", free - 3) end

    local id, taken = salvage.scoop(list, can, player)
    assert_(id == "ore", "the scoop returned the wrong commodity")
    assert_(taken == 3, "took " .. tostring(taken) .. " tonnes into three tonnes of space")
    assert_(can.tonnes == 7, "the remainder was not left in the canister")
    assert_(#list == 1, "a partly emptied canister was removed")

    local _, reason = salvage.scoop(list, can, player)
    assert_(reason == "full", "scooping into a full hold did not report it")

    -- emptying it removes it
    player.cargo = {}
    salvage.scoop(list, can, player)
    assert_(#list == 0, "an emptied canister stayed in the world")
end)

-- ---------------------------------------------------------------------------
-- The first person controller.
--
-- Three defects shipped here, and all three are sign errors that no amount of
-- reading catches but one line of arithmetic does: on the planet surface the
-- mouse turned the view the wrong way, and inside a building A and D were
-- swapped. The surface tangent frame is left handed (east = north x up) and an
-- interior is right handed, so every one of these has to be asserted twice.

local Walker = require("src.sim.walker")

local function walkerFrames() return { "surface", "world" } end

test("mouse right turns the view right, in both frames", function(assert_)
    for _, frame in ipairs(walkerFrames()) do
        for _, yaw in ipairs({ 0, 0.9, 2.7, -1.3, 4.4 }) do
            local w = Walker.new({ frame = frame, yaw = yaw })
            local f0x, _, f0z = w:forward()
            local rx, _, rz = w:right()
            w:look(12, 0)
            local f1x, _, f1z = w:forward()
            local dot = (f1x - f0x) * rx + (f1z - f0z) * rz
            assert_(dot > 0, frame .. " yaw " .. yaw .. ": mouse right turned left (" .. dot .. ")")
        end
    end
end)

test("mouse down looks down, and invert pitch flips it", function(assert_)
    local settings = require("src.settings")
    local was = settings.get("invertY")
    for _, frame in ipairs(walkerFrames()) do
        settings.set("invertY", false)
        local w = Walker.new({ frame = frame })
        w:look(0, 12)
        local _, fy = w:forward()
        assert_(fy < 0, frame .. ": mouse down did not look down")

        settings.set("invertY", true)
        local inv = Walker.new({ frame = frame })
        inv:look(0, 12)
        local _, iy = inv:forward()
        assert_(iy > 0, frame .. ": invert pitch had no effect")
    end
    settings.set("invertY", was)
end)

test("the strafe key steps towards screen right, in both frames", function(assert_)
    for _, frame in ipairs(walkerFrames()) do
        for _, yaw in ipairs({ 0, 0.9, 2.7, -1.3 }) do
            local w = Walker.new({ frame = frame, yaw = yaw })
            local rx, _, rz = w:right()
            local sx, sz = w:wishDir(1, 0)
            assert_(sx * rx + sz * rz > 0.99, frame .. " yaw " .. yaw .. ": D stepped the wrong way")
            local fx, _, fz = w:heading()
            local wx, wz = w:wishDir(0, 1)
            assert_(wx * fx + wz * fz > 0.99, frame .. " yaw " .. yaw .. ": W walked the wrong way")
        end
    end
end)

test("the walker's right matches the camera's right on a real tangent frame", function(assert_)
    -- This is the actual defect: `right` has to be what mat4.orthonormalize
    -- produces from (up, fwd), because that is what the renderer projects with.
    local function norm(x, y, z)
        local l = math.sqrt(x * x + y * y + z * z)
        return x / l, y / l, z / l
    end
    local ux, uy, uz = norm(0.3, 0.9, -0.2)
    local nx, ny, nz = 0.4, 0.1, 0.9
    local d = nx * ux + ny * uy + nz * uz
    nx, ny, nz = norm(nx - ux * d, ny - uy * d, nz - uz * d)
    -- east = north x up, exactly as terrain.tangentFrame builds it
    local ex, ey, ez = norm(ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux)
    local function toWorld(x, y, z)
        return ex * x + ux * y + nx * z, ey * x + uy * y + ny * z, ez * x + uz * y + nz * z
    end
    for _, yaw in ipairs({ 0, 0.7, 2.3, -1.1 }) do
        local w = Walker.new({ frame = "surface", yaw = yaw, pitch = 0.3 })
        local fwd = vec3(toWorld(w:forward()))
        local up = vec3(ux, uy, uz)
        local right = vec3(0, 0, 0)
        mat4.orthonormalize(right, up, fwd)
        local mine = vec3(toWorld(w:right()))
        assert_(vec3.dot(right, mine) > 0.9999,
            "yaw " .. yaw .. ": walker right disagrees with camera right")
    end
end)

test("walking accelerates towards the wish speed and stops", function(assert_)
    local config = require("src.config")
    local w = Walker.new({ frame = "surface" })
    for _ = 1, 120 do w:walk(1 / 60, 0, 1, false) end
    local cruise = w:groundSpeed()
    assert_(math.abs(cruise - config.walk.speed) < 0.05,
        "walk speed settled at " .. cruise .. ", wanted " .. config.walk.speed)
    for _ = 1, 120 do w:walk(1 / 60, 0, 1, true) end
    assert_(w:groundSpeed() > cruise * 1.5, "sprinting is barely faster than walking")
    assert_(w:fovBoost() > 0, "no field of view boost while sprinting")
    for _ = 1, 180 do w:walk(1 / 60, 0, 0, false) end
    assert_(w:groundSpeed() < 0.05, "the walker never comes to a stop")
    assert_(w:fovBoost() == 0, "field of view still boosted while standing still")
end)

test("a settlement is crossable in a reasonable time", function(assert_)
    -- 5.2 m/s across a tier-3 town was over a minute of holding W, which is
    -- what "движение слишком медленное" was about.
    local config = require("src.config")
    local townRadius = 60 + 3 * 26 + 2 * 8      -- Surface:setOrigin's formula
    local seconds = (townRadius * 2) / config.walk.runSpeed
    assert_(seconds < 30, "sprinting across a town takes " .. seconds .. " s")
end)

test("movement is bound by scancode so a non-latin layout still works", function(assert_)
    local input = require("src.input")
    for _, action in ipairs({ "walkForward", "walkBack", "walkLeft", "walkRight" }) do
        local sources = input.defaults[action]
        assert_(sources ~= nil, action .. " is not bound at all")
        local hasScancode = false
        for _, src in ipairs(sources or {}) do
            if src:match("^sc:") then hasScancode = true end
            assert_(not src:match("^key:"),
                action .. " uses a layout dependent key source: " .. src)
        end
        assert_(hasScancode, action .. " has no scancode source")
    end
    -- Landing mode must not reach outside the core scheme either: it used to
    -- advertise LEFT/RIGHT and PAGEUP/PAGEDOWN, four keys nobody had been told
    -- about, in the one situation where precision matters most.
    local hints = require("src.render.hints")
    local core = {}
    for _, a in ipairs(input.CORE) do core[input.keyName(a)] = true end
    for _, row in ipairs(hints.flight({ hoverMode = true })) do
        for key in row.keys:gmatch("[^/]+") do
            if key ~= "MOUSE" and key ~= "F1" then
                assert_(core[key], "landing hints advertise a non-core key: " .. key)
            end
        end
    end

    -- and movement has to show up in the help panel, which hard coded "W A S D"
    local rows = input.controlRows(input.footHelp)
    local labels = {}
    for _, r in ipairs(rows) do labels[#labels + 1] = r[1] end
    local joined = table.concat(labels, "|")
    assert_(joined:find("Move", 1, true), "the on-foot help lists no movement row")
end)

-- ---------------------------------------------------------------------------

-- Sound.
--
-- The synthesis is plain Lua for exactly this reason: a machine with no sound
-- card can still say whether a laser is the right shape. What cannot be
-- checked here is whether it is audible -- that needs ears -- so these check
-- the things that are checkable and would each produce silence or a crackle if
-- they were wrong.
local voices = require("src.audio.voices")

test("every voice produces a usable buffer", function(assert_)
    for _, name in ipairs(voices.order) do
        local b = voices[name]()
        check("every voice produces a usable buffer", b and b.n and b.n > 0,
            name .. " produced nothing")
        check("every voice produces a usable buffer", b.rate and b.rate > 8000,
            name .. " has an implausible sample rate")
        local bad, peak = 0, 0
        for i = 1, b.n do
            local v = b[i]
            -- NaN is the one that matters: it silences the whole source rather
            -- than clicking, so it would be invisible in a listening test too
            if v ~= v or v < -1 or v > 1 then bad = bad + 1 end
            if math.abs(v) > peak then peak = math.abs(v) end
        end
        check("every voice produces a usable buffer", bad == 0,
            name .. " has " .. bad .. " samples outside -1..1 or NaN")
        check("every voice produces a usable buffer", peak > 0.2,
            string.format("%s peaks at %.3f -- inaudible", name, peak))
    end
    assert_(#voices.order >= 12, "the catalogue is only " .. #voices.order .. " voices")
end)

test("one-shot voices decay and loops do not", function(assert_)
    local function tailOf(b)
        local sum, n = 0, 0
        for i = math.floor(b.n * 0.9), b.n do sum = sum + math.abs(b[i]) n = n + 1 end
        return sum / math.max(n, 1)
    end
    local function bodyOf(b)
        local sum, n = 0, 0
        for i = math.floor(b.n * 0.1), math.floor(b.n * 0.4) do sum = sum + math.abs(b[i]) n = n + 1 end
        return sum / math.max(n, 1)
    end

    -- an impact whose end is as loud as its middle is a tone, not an impact
    for _, name in ipairs({ "laser", "hit", "explosion", "step", "uiMove" }) do
        local b = voices[name]()
        assert_(tailOf(b) < bodyOf(b) * 0.5, string.format(
            "%s does not decay: tail %.4f against body %.4f", name, tailOf(b), bodyOf(b)))
    end

    -- and a loop that decays would fade out once a cycle
    for _, name in ipairs({ "engine", "cruise", "wind" }) do
        local b = voices[name]()
        assert_(b.loop, name .. " is used as a loop but is not marked as one")
        assert_(tailOf(b) > bodyOf(b) * 0.4, string.format(
            "%s fades out, so it will pulse once a cycle: tail %.4f against body %.4f",
            name, tailOf(b), bodyOf(b)))
    end
end)

test("voices are deterministic and distinct", function(assert_)
    local a1, a2 = voices.laser(), voices.laser()
    assert_(a1.n == a2.n, "the same voice came out at two different lengths")
    local same = true
    for i = 1, a1.n do
        if a1[i] ~= a2[i] then same = false break end
    end
    assert_(same, "the same voice built twice is not the same sound")

    -- Distinctness matters as much: a catalogue where two entries are the same
    -- buffer means one of them was written wrong and nothing would say so.
    local seen = {}
    for _, name in ipairs(voices.order) do
        local b = voices[name]()
        local sig = 0
        for i = 1, b.n, 37 do sig = (sig + b[i] * i) % 1e6 end
        for other, s in pairs(seen) do
            check("voices are deterministic and distinct", math.abs(s - sig) > 1e-9,
                name .. " and " .. other .. " are the same sound")
        end
        seen[name] = sig
    end
end)

test("the runtime is a no-op with no sound device", function(assert_)
    local audio = require("src.audio")
    -- head-less, so there is no love.audio at all; every entry point has to
    -- survive that, because this is also what a player with sound disabled
    -- gets and a crash there would be a crash on startup
    assert_(audio.init() == false, "audio reported a device in a head-less run")
    assert_(audio.available == false, "audio is available without love.audio")
    assert_(audio.reason ~= nil, "audio gave no reason for being unavailable")
    audio.play("laser")
    audio.loop("engine", 0.5, 1.2)
    audio.update(1 / 60)
    audio.stopLoops()
    audio.setVolume(0.5, 0.5, 0.5)
    assert_(true, "the no-op path raised")
end)

-- ---------------------------------------------------------------------------

-- No source file may read a global that does not exist, or write one at all.
--
-- Lua reports neither at compile time: `cos(a)` is a call of a nil global and
-- only fails on the frame that runs it. Flight:submitCanisters shipped exactly
-- that, and stayed hidden because the function returns early unless loose
-- cargo is in the world. Coverage cannot be relied on to reach every branch of
-- a renderer, so this reads the bytecode -- where every global access is
-- listed whether the line runs or not.
test("no file touches an undefined global", function(assert_)
    local lint = require("tools.lint_globals")
    local bad = lint.scan()
    local report = {}
    for _, b in ipairs(bad) do
        report[#report + 1] = string.format("%s: %s '%s'", b.file, b.mode, b.name)
    end
    assert_(#bad == 0, table.concat(report, "; "))
    assert_(#lint.sources() > 50, "the lint scanned almost nothing; check the paths")
end)

io.write("\n", string.rep("-", 52), "\n")
io.write(string.format("%d passed, %d failed\n", passed, failed))
if failed > 0 then
    io.write("\nfailures:\n")
    for _, f in ipairs(failures) do io.write("  ", f, "\n") end
    os.exit(1)
end
os.exit(0)

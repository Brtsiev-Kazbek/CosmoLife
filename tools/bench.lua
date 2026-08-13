-- Head-less performance benchmark.
--
--     luajit tools/bench.lua [iterations]
--
-- Measures the parts of the frame that do not need a GPU: terrain chunk
-- building, the noise stack under it, system generation, market simulation
-- and mission board generation. Those are where the time actually goes -- a
-- chunk build is tens of thousands of noise evaluations -- and measuring them
-- without LOVE means a change can be checked in a second rather than by
-- watching a frame counter.
--
-- Prints milliseconds and, where it is meaningful, a derived rate. Run it
-- before and after a change and compare.

package.path = "./?.lua;./?/init.lua;" .. package.path

local iterations = tonumber(arg and arg[1]) or 1

local Rng = require("src.lib.rng")
local noise = require("src.lib.noise")
local Galaxy = require("src.procgen.galaxy")
local systemGen = require("src.procgen.system")
local terrain = require("src.procgen.terrain")
local factions = require("src.sim.factions")
local economy = require("src.sim.economy")
local missions = require("src.sim.missions")
local mining = require("src.sim.mining")

local results = {}

local function bench(name, detail, fn)
    -- warm up so the first run's JIT compilation is not counted
    fn()
    collectgarbage("collect")
    local beforeMem = collectgarbage("count")
    local t0 = os.clock()
    local n = 0
    for _ = 1, iterations do n = fn() or n end
    local ms = (os.clock() - t0) * 1000 / iterations
    local mem = collectgarbage("count") - beforeMem
    results[#results + 1] = { name = name, ms = ms, detail = detail, n = n, mem = mem }
end

-- ---------------------------------------------------------------------------

bench("perlin3 x100k", "noise evaluations", function()
    local sum = 0
    for i = 1, 100000 do
        sum = sum + noise.perlin3(7, i * 0.013, i * 0.007, i * 0.021)
    end
    return sum ~= nil and 100000 or 0
end)

local g = Galaxy.new(20250811)
local diplo = factions.Diplomacy.new(20250811)
local startStub = g:findStartSystem()

bench("galaxy sweep 60ly", "systems found", function()
    local list = g:systemsNear(startStub.x, startStub.y, startStub.z, 60, 24)
    return #list
end)

bench("system build", "bodies", function()
    local sys = systemGen.build(startStub, diplo, 5)
    return #sys.bodies
end)

local sys = systemGen.build(startStub, diplo, 5)
local body
for _, b in ipairs(systemGen.landables(sys)) do
    if b.landable and not b.giant then body = b break end
end

if body then
    local field = terrain.field(body)

    bench("terrain height x10k", "samples", function()
        local sum = 0
        for i = 1, 10000 do sum = sum + field:height(i * 3.1, i * 1.7) end
        return 10000
    end)

    -- This is the one that matters: a chunk at the default resolution is
    -- 25x25 height samples plus a colour lookup per quad, and the colour
    -- lookup used to re-sample the field four more times per quad.
    bench("terrain chunk 24x24", "quads", function()
        local res = 24
        local step = 900 / res
        local hs = {}
        for j = 0, res do
            hs[j] = {}
            for i = 0, res do hs[j][i] = field:height(i * step, j * step) end
        end
        local quads = 0
        for j = 0, res - 1 do
            for i = 0, res - 1 do
                local h00, h10 = hs[j][i], hs[j][i + 1]
                local h01, h11 = hs[j + 1][i], hs[j + 1][i + 1]
                local hc = (h00 + h10 + h01 + h11) * 0.25
                local dhx = ((h10 + h11) - (h00 + h01)) / (2 * step)
                local dhz = ((h01 + h11) - (h00 + h10)) / (2 * step)
                local ny = 1 / math.sqrt(dhx * dhx + 1 + dhz * dhz)
                field:colorAt(i * step, j * step, hc, ny)
                quads = quads + 1
            end
        end
        return quads
    end)

    bench("terrain chunk (old colour path)", "quads", function()
        local res = 24
        local step = 900 / res
        local hs = {}
        for j = 0, res do
            hs[j] = {}
            for i = 0, res do hs[j][i] = field:height(i * step, j * step) end
        end
        local quads = 0
        for j = 0, res - 1 do
            for i = 0, res - 1 do
                local h00, h10 = hs[j][i], hs[j][i + 1]
                local h01, h11 = hs[j + 1][i], hs[j + 1][i + 1]
                local hc = (h00 + h10 + h01 + h11) * 0.25
                field:colorAt(i * step, j * step, hc)     -- no slope passed
                quads = quads + 1
            end
        end
        return quads
    end)
end

local port = systemGen.ports(sys)[1]
if port then
    bench("market build + 30 days", "commodities", function()
        local m = economy.marketFor(port, sys, 5, 0)
        m:update(35)
        return #m:tradedIds()
    end)

    bench("mission board", "contracts", function()
        local board = missions.generate(port, sys, g, diplo, 5, 14)
        return #board
    end)
end

local npc = require("src.sim.npc")
local ships = require("src.procgen.ships")

bench("npc spawn x40", "ships", function()
    -- hulls come from a small per-system pool, so this measures the cache
    -- hitting the way it does in play
    for i = 1, 40 do
        npc.create({ seed = Rng.hash(sys.seed, i, i % 5, "trader"),
                     systemSeed = sys.seed, kind = "trader" })
    end
    return 40
end)

bench("npc spawn x40 (uncached hulls)", "ships", function()
    ships.clearCache()
    for i = 1, 40 do
        npc.create({ seed = Rng.hash(sys.seed, i, i % 5, "trader"),
                     systemSeed = Rng.hash(sys.seed, i), kind = "trader" })
    end
    return 40
end)

if sys.belts and #sys.belts > 0 then
    bench("mining field scan", "rocks", function()
        local damage = {}
        local list = mining.near(sys, sys.belts[1].radius, 0, 0, damage)
        return #list
    end)
end

-- ---------------------------------------------------------------------------

print(string.format("CosmoLife benchmark  (%d iteration%s)",
    iterations, iterations == 1 and "" or "s"))
print(string.rep("-", 62))
for _, r in ipairs(results) do
    local rate = ""
    if r.n and r.n > 0 and r.ms > 0 then
        rate = string.format("%10.0f %s/s", r.n / (r.ms / 1000), r.detail)
    end
    print(string.format("%-34s %8.2f ms %s", r.name, r.ms, rate))
end
print(string.rep("-", 62))

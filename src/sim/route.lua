-- Plotting a course further than one jump.
--
-- The chart could tell you a system was out of range and nothing else, which
-- is the least useful true statement it could make: the whole point of a map
-- is that you cannot get there directly. Everything needed to answer "then how
-- do I get there" was already present -- the galaxy generates on demand, the
-- ship has a jump range, `World:fuelCost` prices a leg -- and nothing joined
-- them up.
--
-- Dijkstra over the systems near the straight line, counting jumps first and
-- fuel only to break ties. Minimising fuel outright was tried and measured:
-- with the game's cost curve it plotted nine hops in place of six to save
-- 0.6% of a tank, which is not a course anyone wants to fly. Fuel is refilled
-- at every port on the way; what the player is actually spending is evenings.
-- Pure Lua on plain tables, so a course can be checked head-lessly.

local route = {}

local sqrt, huge = math.sqrt, math.huge

-- How many systems the search will consider. A 60 ly sweep finds around 900,
-- and the search is quadratic in this, so it is a cap on the worst case rather
-- than a limit anyone reaches on a normal course.
route.MAX_NODES = 700

local function dist(a, b)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    return sqrt(dx * dx + dy * dy + dz * dz)
end

--- opts: galaxy, from, to, jumpRange, fuelCost(distance) -> tonnes, maxNodes
--
-- Returns { hops = { stub, ... }, fuel, jumps } where `hops` excludes the
-- system you are standing in, or nil and a reason.
function route.plan(opts)
    local galaxy, from, to = opts.galaxy, opts.from, opts.to
    local range = opts.jumpRange or 10
    local fuelOf = opts.fuelCost or dist
    if not (galaxy and from and to) then return nil, "no destination" end
    if from.id == to.id then return { hops = {}, fuel = 0, jumps = 0 } end

    local span = dist(from, to)
    if span <= range then
        return { hops = { to }, fuel = fuelOf(span), jumps = 1 }
    end

    -- Candidates from a tube around the straight line, not a ball around its
    -- middle. The ball was tried first and fails exactly where it matters: on
    -- a 136 ly haul the node budget is spent on the systems nearest the
    -- midpoint and both ends of the corridor -- including everything within
    -- reach of the ship -- fall outside it, so a route that plainly exists
    -- comes back "no course".
    local ux, uy, uz = (to.x - from.x) / span, (to.y - from.y) / span, (to.z - from.z) / span
    local tube = range * 2

    -- Swept in segments along the line rather than as one ball over the whole
    -- span: the galaxy generates what it is asked for, and one ball around a
    -- 240 ly course means generating the 2.8 million cubic light years inside
    -- it to use a tube holding a few hundred systems. Segmenting makes the
    -- sweep linear in distance -- 66 ms down to 12 on that same course.
    local segs = math.max(1, math.ceil(span / 40))
    local segLen = span / segs
    local found = {}
    for i = 1, segs do
        local t = (i - 0.5) * segLen
        local list = galaxy:systemsNear(from.x + ux * t, from.y + uy * t, from.z + uz * t,
            segLen * 0.5 + tube, tube + range)
        for _, s in ipairs(list) do found[#found + 1] = s end
    end
    local corridor = {}
    for i = 1, #found do
        local s = found[i]
        local dx, dy, dz = s.x - from.x, s.y - from.y, s.z - from.z
        local along = dx * ux + dy * uy + dz * uz
        if along > -range and along < span + range then
            -- perpendicular distance to the line, which is uniform along it:
            -- trimming by this thins the tube instead of shortening it
            local ox, oy, oz = dx - ux * along, dy - uy * along, dz - uz * along
            corridor[#corridor + 1] = { s = s, off = ox * ox + oy * oy + oz * oz }
        end
    end
    table.sort(corridor, function(a, b)
        if a.off ~= b.off then return a.off < b.off end
        return a.s.id < b.s.id          -- ties broken by name, never by table order
    end)

    local nodes, index = {}, {}
    local cap = opts.maxNodes or route.MAX_NODES
    for i = 1, #corridor do
        if #nodes >= cap then break end
        local s = corridor[i].s
        if not index[s.id] then
            nodes[#nodes + 1] = s
            index[s.id] = #nodes
        end
    end
    for _, s in ipairs({ from, to }) do
        if not index[s.id] then
            nodes[#nodes + 1] = s
            index[s.id] = #nodes
        end
    end

    local n = #nodes
    local best, prev, done = {}, {}, {}
    for i = 1, n do best[i] = huge end
    local start = index[from.id]
    local goal = index[to.id]
    best[start] = 0

    local r2 = range * range
    while true do
        -- linear scan for the nearest unvisited node: a heap would win on a
        -- galaxy-wide search, and on 700 nodes it would only add a heap
        local at, atCost = nil, huge
        for i = 1, n do
            if not done[i] and best[i] < atCost then at, atCost = i, best[i] end
        end
        if not at or at == goal then break end
        done[at] = true

        local a = nodes[at]
        for i = 1, n do
            if not done[i] then
                local b = nodes[i]
                local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 <= r2 and d2 > 0 then
                    -- one per jump, plus a thousandth of a tonne per tonne so
                    -- that among courses of equal length the cheap one wins
                    local cost = atCost + 1 + fuelOf(sqrt(d2)) * 1e-3
                    if cost < best[i] then
                        best[i] = cost
                        prev[i] = at
                    end
                end
            end
        end
    end

    if best[goal] == huge then return nil, "no course within jump range" end

    local hops = {}
    local at = goal
    while at and at ~= start do
        table.insert(hops, 1, nodes[at])
        at = prev[at]
    end
    -- the search's own cost is jumps-with-a-tiebreak, which is not a number to
    -- show anyone; the fuel is the sum of the legs actually flown
    local burn, at2 = 0, from
    for _, s in ipairs(hops) do
        burn = burn + fuelOf(dist(at2, s))
        at2 = s
    end
    return { hops = hops, fuel = burn, jumps = #hops }
end

return route

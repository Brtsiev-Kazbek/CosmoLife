-- Small helpers shared across the whole project.

local util = {}

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

function util.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

function util.lerp(a, b, t) return a + (b - a) * t end

function util.sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end

--- Smooth, frame-rate independent approach of `a` towards `b`.
-- `rate` is the fraction of the remaining distance covered per second.
function util.damp(a, b, rate, dt)
    return b + (a - b) * math.exp(-rate * dt)
end

function util.smoothstep(e0, e1, x)
    local t = util.clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
end

--- Maps `v` from [a0,a1] to [b0,b1], clamped.
function util.remap(v, a0, a1, b0, b1)
    if a1 == a0 then return b0 end
    return util.clamp(b0 + (v - a0) / (a1 - a0) * (b1 - b0), min(b0, b1), max(b0, b1))
end

function util.round(v) return floor(v + 0.5) end

--- Moves `a` toward `b` by at most `step`.
function util.approach(a, b, step)
    if a < b then return min(a + step, b) end
    return max(a - step, b)
end

--- Formats a credit amount with thin separators: 1234567 -> "1 234 567"
function util.money(n)
    local neg = n < 0
    n = floor(abs(n) + 0.5)
    local s = tostring(n)
    local out = {}
    local c = 0
    for i = #s, 1, -1 do
        out[#out + 1] = s:sub(i, i)
        c = c + 1
        if c % 3 == 0 and i > 1 then out[#out + 1] = " " end
    end
    local rev = table.concat(out):reverse()
    return (neg and "-" or "") .. rev
end

--- Human readable distance: metres -> m / km / Mm / Gm / AU
-- Unit abbreviations, so a localisation can write them in its own alphabet.
-- Kept as a table rather than going through i18n directly because util is a
-- leaf module the head-less tests load without any locale at all.
util.units = {
    m = "m", km = "km", Mm = "Mm", Gm = "Gm", AU = "AU",
    mps = "m/s", kmps = "km/s", c = "c",
}

function util.distance(m)
    local a = abs(m)
    local u = util.units
    if a < 1000 then return string.format("%.0f %s", m, u.m) end
    if a < 1e6 then return string.format("%.1f %s", m / 1e3, u.km) end
    if a < 1e9 then return string.format("%.1f %s", m / 1e6, u.Mm) end
    if a < 1.5e11 then return string.format("%.2f %s", m / 1e9, u.Gm) end
    return string.format("%.2f %s", m / 1.495978707e11, u.AU)
end

function util.speed(v)
    local a = abs(v)
    local u = util.units
    if a < 10000 then return string.format("%.0f %s", v, u.mps) end
    if a < 1e7 then return string.format("%.1f %s", v / 1e3, u.kmps) end
    return string.format("%.2f %s", v / 299792458, u.c)
end

--- Days since epoch -> in-game date string.
function util.date(days)
    local d = floor(days)
    local year = 3200 + floor(d / 360)
    local rest = d % 360
    local month = floor(rest / 30) + 1
    local day = rest % 30 + 1
    return string.format("%02d.%02d.%d", day, month, year)
end

function util.shuffle(t, rng)
    for i = #t, 2, -1 do
        local j = rng:int(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function util.choice(t, rng) return t[rng:int(1, #t)] end

--- Weighted pick. `t` is an array of tables that each carry a `weight` field.
function util.weighted(t, rng, field)
    field = field or "weight"
    local total = 0
    for i = 1, #t do total = total + (t[i][field] or 1) end
    local r = rng:float() * total
    for i = 1, #t do
        r = r - (t[i][field] or 1)
        if r <= 0 then return t[i], i end
    end
    return t[#t], #t
end

function util.copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

function util.deepcopy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local o = {}
    seen[t] = o
    for k, v in pairs(t) do o[util.deepcopy(k, seen)] = util.deepcopy(v, seen) end
    return setmetatable(o, getmetatable(t))
end

function util.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- The keys of a table as an array.
--
-- Mostly wanted with `table.sort` right after it: `pairs` order over a hash
-- table is not stable between processes, so anything that draws random numbers
-- or picks a winner while walking one has to sort first.
function util.keys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    return out
end

--- Stable sort helper that keeps the original order of equal elements.
function util.sortBy(t, keyfn, descending)
    local keys = {}
    for i = 1, #t do keys[t[i]] = keyfn(t[i]) end
    table.sort(t, function(a, b)
        local ka, kb = keys[a], keys[b]
        if ka == kb then return false end
        if descending then return ka > kb end
        return ka < kb
    end)
    return t
end

--- Word-wraps `text` to `width` characters (used by the terminal-style UI).
function util.wrap(text, width)
    local lines, line = {}, ""
    for word in tostring(text):gmatch("%S+") do
        if #line == 0 then
            line = word
        elseif #line + #word + 1 <= width then
            line = line .. " " .. word
        else
            lines[#lines + 1] = line
            line = word
        end
    end
    if #line > 0 then lines[#lines + 1] = line end
    return lines
end

return util

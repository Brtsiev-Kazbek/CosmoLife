-- Deterministic, portable pseudo random numbers.
--
-- Everything procedural in CosmoLife (galaxies, systems, ships, cities,
-- buildings) is derived from integer seeds through this module, so the same
-- coordinates always produce the same universe on every machine and in every
-- LOVE/Lua build.  We deliberately avoid `math.random` (implementation
-- defined) and bitwise operators (missing in 5.1, different spellings in
-- 5.3/LuaJIT) -- the generator below is L'Ecuyer's combined MRG which runs
-- exactly in IEEE doubles.

local class = require("src.lib.class")

local M1, A1 = 2147483563, 40014
local M2, A2 = 2147483399, 40692
local MD = M1 - 1

local floor, sqrt, log, cos, pi = math.floor, math.sqrt, math.log, math.cos, math.pi

local Rng = class("Rng")

--- Mixes any number of integers into a single positive 31 bit integer.
local function hash(...)
    local h = 2166136261 % M1
    local n = select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        if type(v) == "string" then
            local acc = 0
            for j = 1, #v do acc = (acc * 131 + v:byte(j)) % M1 end
            v = acc
        elseif type(v) == "boolean" then
            v = v and 1 or 0
        end
        v = floor(v or 0)
        -- fold a full 53 bit range down into the modulus without overflowing
        local lo = v % 65536
        local hi = floor(v / 65536) % 65536
        h = (h * A1 + lo * 31 + 7) % M1
        h = (h * A2 + hi * 17 + 13) % M2
    end
    -- a couple of avalanche rounds so that neighbouring inputs diverge
    h = (h * A1 + 12345) % M1
    h = (h * A2 + 6789) % M2
    return h
end

function Rng:init(seed, ...)
    self:seed(seed, ...)
end

function Rng:seed(seed, ...)
    if select("#", ...) > 0 then
        seed = hash(seed, ...)
    elseif type(seed) ~= "number" then
        seed = hash(seed or os.time())
    end
    seed = floor(math.abs(seed or 0))
    self.s1 = seed % (M1 - 1) + 1
    self.s2 = hash(seed, 0x9E37) % (M2 - 1) + 1
    -- discard the first few outputs: freshly seeded MRGs correlate
    for _ = 1, 6 do self:next() end
    return self
end

--- Raw step -- returns an integer in [0, MD).
function Rng:next()
    self.s1 = (self.s1 * A1) % M1
    self.s2 = (self.s2 * A2) % M2
    local z = (self.s1 - self.s2) % MD
    return z
end

--- Uniform float in [0, 1).
function Rng:float() return self:next() / MD end

--- Uniform float in [a, b).
function Rng:range(a, b)
    if not b then a, b = 0, a end
    return a + (b - a) * self:float()
end

--- Uniform integer in [a, b] inclusive.
function Rng:int(a, b)
    if not b then a, b = 1, a end
    if b < a then return a end
    return a + floor(self:float() * (b - a + 1))
end

function Rng:bool(p) return self:float() < (p or 0.5) end

function Rng:sign() return self:bool() and 1 or -1 end

function Rng:pick(t) return t[self:int(1, #t)] end

--- Normal distribution (Box-Muller), clamped to +/-4 sigma.
function Rng:gauss(mu, sigma)
    mu, sigma = mu or 0, sigma or 1
    local u1 = self:float()
    if u1 < 1e-12 then u1 = 1e-12 end
    local u2 = self:float()
    local z = sqrt(-2 * log(u1)) * cos(2 * pi * u2)
    if z > 4 then z = 4 elseif z < -4 then z = -4 end
    return mu + z * sigma
end

--- A unit vector with uniform distribution over the sphere.
function Rng:direction()
    local z = self:range(-1, 1)
    local a = self:range(0, 2 * pi)
    local r = sqrt(1 - z * z)
    return r * cos(a), r * math.sin(a), z
end

--- A child generator whose stream is independent of this one but still fully
--- determined by (this seed, extra arguments).  This is how sub-features
--- (a planet of a system, a building of a city) get stable seeds.
function Rng:derive(...)
    return Rng.new(hash(self.s1, self.s2, ...))
end

--- Shuffles an array in place.
function Rng:shuffle(t)
    for i = #t, 2, -1 do
        local j = self:int(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

Rng.hash = hash

--- Hash straight to a float in [0,1) -- handy for noise and one-off decisions.
function Rng.hashf(...)
    return hash(...) / M1
end

return Rng

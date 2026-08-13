-- Deterministic gradient / value noise used for planet terrain, cloud decks
-- and surface detail.  Built on the hash from `rng` so a planet looks the same
-- on every machine without shipping any data files.

local Rng = require("src.lib.rng")

local noise = {}
local hash = Rng.hash
local floor, sqrt, abs = math.floor, math.sqrt, math.abs

local M1 = 2147483563

-- A gradient hash returning one of 12 fixed 3D gradients (Perlin's trick:
-- avoids a normalisation and gives an even directional distribution).
local GRAD = {
    { 1, 1, 0 }, { -1, 1, 0 }, { 1, -1, 0 }, { -1, -1, 0 },
    { 1, 0, 1 }, { -1, 0, 1 }, { 1, 0, -1 }, { -1, 0, -1 },
    { 0, 1, 1 }, { 0, -1, 1 }, { 0, 1, -1 }, { 0, -1, -1 },
}

local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end

local function grad3(seed, ix, iy, iz, dx, dy, dz)
    local g = GRAD[hash(seed, ix, iy, iz) % 12 + 1]
    return g[1] * dx + g[2] * dy + g[3] * dz
end

local function grad2(seed, ix, iy, dx, dy)
    local h = hash(seed, ix, iy) % 8
    local a = h * (math.pi / 4)
    return math.cos(a) * dx + math.sin(a) * dy
end

--- Perlin style gradient noise in 2D, output roughly in [-1, 1].
function noise.perlin2(seed, x, y)
    local ix, iy = floor(x), floor(y)
    local fx, fy = x - ix, y - iy
    local u, v = fade(fx), fade(fy)
    local n00 = grad2(seed, ix, iy, fx, fy)
    local n10 = grad2(seed, ix + 1, iy, fx - 1, fy)
    local n01 = grad2(seed, ix, iy + 1, fx, fy - 1)
    local n11 = grad2(seed, ix + 1, iy + 1, fx - 1, fy - 1)
    local a = n00 + u * (n10 - n00)
    local b = n01 + u * (n11 - n01)
    return (a + v * (b - a)) * 1.4
end

--- Perlin style gradient noise in 3D, output roughly in [-1, 1].
function noise.perlin3(seed, x, y, z)
    local ix, iy, iz = floor(x), floor(y), floor(z)
    local fx, fy, fz = x - ix, y - iy, z - iz
    local u, v, w = fade(fx), fade(fy), fade(fz)

    local n000 = grad3(seed, ix, iy, iz, fx, fy, fz)
    local n100 = grad3(seed, ix + 1, iy, iz, fx - 1, fy, fz)
    local n010 = grad3(seed, ix, iy + 1, iz, fx, fy - 1, fz)
    local n110 = grad3(seed, ix + 1, iy + 1, iz, fx - 1, fy - 1, fz)
    local n001 = grad3(seed, ix, iy, iz + 1, fx, fy, fz - 1)
    local n101 = grad3(seed, ix + 1, iy, iz + 1, fx - 1, fy, fz - 1)
    local n011 = grad3(seed, ix, iy + 1, iz + 1, fx, fy - 1, fz - 1)
    local n111 = grad3(seed, ix + 1, iy + 1, iz + 1, fx - 1, fy - 1, fz - 1)

    local x00 = n000 + u * (n100 - n000)
    local x10 = n010 + u * (n110 - n010)
    local x01 = n001 + u * (n101 - n001)
    local x11 = n011 + u * (n111 - n011)
    local y0 = x00 + v * (x10 - x00)
    local y1 = x01 + v * (x11 - x01)
    return (y0 + w * (y1 - y0)) * 1.2
end

--- Fractal Brownian motion over perlin3.
function noise.fbm3(seed, x, y, z, octaves, lacunarity, gain)
    octaves = octaves or 4
    lacunarity = lacunarity or 2.0
    gain = gain or 0.5
    local sum, amp, freq, norm = 0, 1, 1, 0
    for i = 1, octaves do
        sum = sum + amp * noise.perlin3(seed + i * 7919, x * freq, y * freq, z * freq)
        norm = norm + amp
        amp = amp * gain
        freq = freq * lacunarity
    end
    return sum / norm
end

function noise.fbm2(seed, x, y, octaves, lacunarity, gain)
    octaves = octaves or 4
    lacunarity = lacunarity or 2.0
    gain = gain or 0.5
    local sum, amp, freq, norm = 0, 1, 1, 0
    for i = 1, octaves do
        sum = sum + amp * noise.perlin2(seed + i * 6151, x * freq, y * freq)
        norm = norm + amp
        amp = amp * gain
        freq = freq * lacunarity
    end
    return sum / norm
end

--- Ridged multifractal -- produces mountain ridges and canyon walls.
function noise.ridged3(seed, x, y, z, octaves, lacunarity, gain)
    octaves = octaves or 5
    lacunarity = lacunarity or 2.1
    gain = gain or 0.5
    local sum, amp, freq, norm = 0, 1, 1, 0
    for i = 1, octaves do
        local n = 1 - abs(noise.perlin3(seed + i * 4271, x * freq, y * freq, z * freq))
        sum = sum + amp * n * n
        norm = norm + amp
        amp = amp * gain
        freq = freq * lacunarity
    end
    return sum / norm
end

--- Worley / cellular noise: returns the distance to the closest feature point.
--- Used for crater fields and city district boundaries.
function noise.worley2(seed, x, y)
    local ix, iy = floor(x), floor(y)
    local best = 1e9
    for oy = -1, 1 do
        for ox = -1, 1 do
            local cx, cy = ix + ox, iy + oy
            local px = cx + hash(seed, cx, cy, 1) / M1
            local py = cy + hash(seed, cx, cy, 2) / M1
            local dx, dy = px - x, py - y
            local d = dx * dx + dy * dy
            if d < best then best = d end
        end
    end
    return sqrt(best)
end

--- Cheap deterministic white noise in [0,1).
function noise.white(seed, ...)
    return hash(seed, ...) / M1
end

return noise

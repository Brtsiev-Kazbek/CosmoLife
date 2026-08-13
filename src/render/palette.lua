-- A deliberately small, era-appropriate palette.
--
-- Keeping every generated mesh inside one palette is what makes procedural
-- content look designed rather than random: a city, a freighter and a mining
-- rig share the same handful of hull greys, hazard oranges and screen cyans.

local palette = {}

local function c(r, g, b) return { r / 255, g / 255, b / 255, 1 } end

palette.colors = {
    -- hull metals
    hullDark      = c(46, 50, 58),
    hull          = c(86, 92, 104),
    hullLight     = c(132, 140, 154),
    hullBright    = c(178, 186, 200),
    steel         = c(108, 116, 128),
    titanium      = c(150, 152, 148),
    rust          = c(122, 78, 52),
    copper        = c(158, 104, 60),
    gold          = c(198, 158, 74),

    -- accent / faction paint
    red           = c(184, 52, 46),
    darkRed       = c(112, 30, 28),
    orange        = c(214, 118, 40),
    amber         = c(226, 166, 52),
    yellow        = c(228, 206, 74),
    green         = c(78, 156, 84),
    darkGreen     = c(44, 96, 58),
    teal          = c(52, 148, 148),
    cyan          = c(96, 200, 214),
    blue          = c(56, 100, 178),
    darkBlue      = c(32, 56, 108),
    purple        = c(112, 68, 156),
    magenta       = c(184, 74, 138),
    white         = c(232, 236, 240),
    black         = c(18, 18, 22),

    -- glass, screens, lights
    glass         = c(72, 118, 140),
    glassLit      = c(150, 214, 226),
    window        = c(226, 214, 140),
    windowCold    = c(150, 200, 226),
    lamp          = c(255, 236, 168),
    hazard        = c(228, 176, 40),
    engine        = c(120, 190, 255),
    engineHot     = c(226, 240, 255),
    plasma        = c(196, 120, 255),

    -- terrain families
    rockDry       = c(122, 96, 74),
    rockRed       = c(138, 78, 52),
    rockGrey      = c(96, 96, 100),
    rockIce       = c(196, 210, 222),
    sand          = c(184, 156, 108),
    ash           = c(70, 66, 64),
    moss          = c(88, 112, 66),
    grass         = c(96, 132, 72),
    forest        = c(56, 92, 58),
    water         = c(38, 78, 122),
    waterDeep     = c(24, 48, 84),
    lava          = c(206, 84, 32),
    snow          = c(228, 234, 240),

    -- UI
    uiPrimary     = c(120, 226, 208),
    uiDim         = c(58, 118, 112),
    uiWarn        = c(232, 176, 64),
    uiDanger      = c(226, 84, 72),
    uiText        = c(198, 226, 220),
    uiPanel       = { 0.02, 0.05, 0.06, 0.82 },
    uiLine        = { 0.24, 0.62, 0.60, 0.9 },
}

--- Named colour lookup with a loud failure -- typos in generators are bugs.
function palette.get(name)
    local col = palette.colors[name]
    if not col then error("palette: unknown colour '" .. tostring(name) .. "'", 2) end
    return col
end

--- Multiplies a colour by a scalar (used to fake a second light bounce or to
--- vary panels on the same hull without leaving the palette).
function palette.shade(col, k)
    return { col[1] * k, col[2] * k, col[3] * k, col[4] or 1 }
end

function palette.mix(a, b, t)
    return {
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
        (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t,
    }
end

--- Deterministic small variation of a colour, so adjacent panels of a
--- generated hull are not perfectly identical.
function palette.jitter(col, rng, amount)
    amount = amount or 0.08
    local k = 1 + rng:range(-amount, amount)
    return { math.min(col[1] * k, 1), math.min(col[2] * k, 1), math.min(col[3] * k, 1), col[4] or 1 }
end

--- Palettes assigned to procedurally generated hulls per faction / role.
palette.hullSets = {
    civilian  = { "hull", "hullLight", "steel", "hullDark", "white" },
    military  = { "hullDark", "steel", "darkGreen", "hull", "black" },
    pirate    = { "hullDark", "darkRed", "rust", "black", "orange" },
    trader    = { "hull", "copper", "hullLight", "amber", "steel" },
    industry  = { "steel", "rust", "hazard", "hullDark", "copper" },
    highTech  = { "hullBright", "white", "teal", "hullLight", "cyan" },
    alien     = { "purple", "magenta", "darkBlue", "teal", "plasma" },
}

--- Terrain colour ramps per planet class, low to high altitude.
palette.terrainSets = {
    terran   = { "waterDeep", "water", "sand", "grass", "forest", "rockGrey", "snow" },
    desert   = { "rockRed", "sand", "sand", "rockDry", "rockDry", "rockGrey", "rockGrey" },
    ice      = { "rockIce", "rockIce", "snow", "snow", "rockGrey", "rockIce", "snow" },
    volcanic = { "lava", "ash", "ash", "rockGrey", "rockDry", "ash", "rockGrey" },
    barren   = { "rockGrey", "rockGrey", "rockDry", "ash", "rockGrey", "hullDark", "rockIce" },
    ocean    = { "waterDeep", "waterDeep", "water", "water", "sand", "grass", "rockGrey" },
    toxic    = { "moss", "darkGreen", "moss", "rockDry", "ash", "rockGrey", "hullDark" },
}

return palette

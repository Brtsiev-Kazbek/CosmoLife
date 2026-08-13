-- Locale coverage audit.
--
--   luajit tools/audit_locale.lua [locale]
--
-- Scans the source for translated literals -- `L("...")`, `i18n.translate(...)`
-- and the noun dictionary -- and reports the ones the locale has no entry for.
-- Run it after wiring a screen; anything it prints is a string the player will
-- still see in English.
--
-- It reads the source rather than the running game on purpose: a coverage
-- number gathered by playing only covers the screens that were opened.

package.path = "./?.lua;" .. package.path

local i18n = require("src.i18n")

local locale = arg and arg[1] or "ru"
assert(i18n.setLocale(locale))

local SOURCE_DIRS = { "src" }

-- Literals that are keys into other tables rather than display text, or are
-- deliberately identical in every language.
local IGNORE = {
    ["%s"] = true, ["%d"] = true, [""] = true, ["-"] = true, ["--"] = true,
}

local function listFiles(dir, out)
    out = out or {}
    local p = io.popen('find "' .. dir .. '" -name "*.lua" -type f')
    if not p then return out end
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

local seen, order = {}, {}
local function record(text, file)
    if IGNORE[text] or text:match("^%s*$") then return end
    if not seen[text] then
        seen[text] = { file = file, count = 0 }
        order[#order + 1] = text
    end
    seen[text].count = seen[text].count + 1
end

--- Reads the literal starting at `i` (which points at the opening quote),
--- following `..` concatenation so a long template wrapped over several lines
--- is audited as the one string the call actually receives.
local function readLiteral(src, i)
    local parts = {}
    while true do
        local q = src:sub(i, i)
        if q ~= '"' and q ~= "'" then break end
        local j = i + 1
        local buf = {}
        while j <= #src do
            local ch = src:sub(j, j)
            if ch == "\\" then
                buf[#buf + 1] = src:sub(j, j + 1)
                j = j + 2
            elseif ch == q then
                break
            elseif ch == "\n" then
                return nil                     -- unterminated: not a literal
            else
                buf[#buf + 1] = ch
                j = j + 1
            end
        end
        parts[#parts + 1] = table.concat(buf)
        -- keep going only if the next non-space token is `..` then a quote
        local k = src:match("^%s*%.%.%s*()", j + 1)
        if not k then break end
        i = k
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

--- Call prefixes whose first argument is a translated literal.
local CALLS = { "L(", "i18n.translate(", "i18n.term(", "i18n.format(" }

--- Fields whose string value is a template rendered through i18n later --
--- mission text is data, not a call site, so it needs its own sweep.
local FIELDS = { "titleText", "briefText" }

local function scan(src, emit)
    for _, field in ipairs(FIELDS) do
        local from = 1
        while true do
            local a, b = src:find(field, from, true)
            if not a then break end
            from = b + 1
            -- `titleText = "..."` or `titleText = cond and "..." or "..."`;
            -- take every literal up to the end of the line's expression
            local rest = src:match("^%s*=%s*()", b + 1)
            if rest then
                local tail = src:sub(rest, rest + 400)
                for q in tail:gmatch('"') do break end
                local pos = rest
                for _ = 1, 2 do
                    local q = src:find('"', pos, true)
                    if not q or q > rest + 400 then break end
                    local text = readLiteral(src, q)
                    if text then emit(text) end
                    -- move past this literal chain
                    pos = q + 1
                    while true do
                        local e = src:find('"', pos, true)
                        if not e then break end
                        pos = e + 1
                        local k = src:match("^%s*%.%.%s*()", pos)
                        if not k then break end
                        pos = k + 1
                    end
                end
            end
        end
    end
    for _, call in ipairs(CALLS) do
        local from = 1
        while true do
            local a, b = src:find(call, from, true)
            if not a then break end
            from = b + 1
            -- `L(` must not be the tail of a longer identifier
            local before = a > 1 and src:sub(a - 1, a - 1) or " "
            if not before:match("[%w_%.]") or call:find("%.") then
                local text = readLiteral(src, b + 1)
                if text then emit(text) end
            end
        end
    end
end

local files = {}
for _, d in ipairs(SOURCE_DIRS) do listFiles(d, files) end
table.sort(files)

for _, file in ipairs(files) do
    -- The locale files are the translations, not call sites, and i18n.lua's
    -- own header documents the API with example templates that are not real
    -- strings. Everything else is fair game.
    if not file:match("/locale/") and not file:match("/i18n%.lua$") then
        local fh = io.open(file, "r")
        if fh then
            local src = fh:read("*a")
            fh:close()
            scan(src, function(text) record(text, file) end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Data sweep
--
-- Plenty of display text never appears as a literal at a call site: it lives in
-- a table and reaches the screen as `L(item.name)`. Source scanning cannot see
-- those, so the tables are walked directly.
-- ---------------------------------------------------------------------------

local function sweepData()
    local function emit(v, where)
        if type(v) == "string" then record(v, where) end
    end

    local input = require("src.input")
    for _, v in pairs(input.labels) do emit(v, "src/input.lua (labels)") end
    for _, group in ipairs(input.actionOrder) do
        emit(group[1]:upper(), "src/input.lua (sections)")
    end

    local settings = require("src.settings")
    for _, group in ipairs(settings.schema) do
        emit(group.section:upper(), "src/settings.lua (sections)")
        for _, item in ipairs(group.items) do
            emit(item.name, "src/settings.lua (options)")
            emit(item.help, "src/settings.lua (help)")
        end
    end

    local equipment = require("src.sim.equipment")
    for _, e in ipairs(equipment.list) do
        emit(e.name, "src/sim/equipment.lua")
        emit(e.blurb, "src/sim/equipment.lua (blurb)")
        emit(e.slot:upper(), "src/sim/equipment.lua (slot)")
    end

    local commodities = require("src.sim.commodities")
    for _, c in ipairs(commodities.list) do emit(c.name, "src/sim/commodities.lua") end
    for _, v in pairs(commodities.categoryNames) do emit(v, "src/sim/commodities.lua (category)") end
    for _, e in ipairs(commodities.economies) do emit(e.name, "src/sim/commodities.lua (economy)") end

    local factions = require("src.sim.factions")
    for _, f in ipairs(factions.list) do
        emit(f.name, "src/sim/factions.lua")
        emit(f.blurb, "src/sim/factions.lua (blurb)")
    end

    local colony = require("src.sim.colony")
    for _, s in pairs(colony.specialisations) do emit(s.name, "src/sim/colony.lua (spec)") end
    if colony.TIERS then
        for _, t in ipairs(colony.TIERS) do emit(t, "src/sim/colony.lua (tier)") end
    end

    local lighting = require("src.render.lighting")
    for _, p in ipairs(lighting.presets or {}) do
        emit(p.name, "src/render/lighting.lua")
        emit(p.blurb, "src/render/lighting.lua (blurb)")
    end

    local ships = require("src.procgen.ships")
    for _, role in ipairs(ships.roles) do
        local def = ships.roleDef and ships.roleDef(role)
        if def then emit(def.name, "src/procgen/ships.lua (role)") end
    end

    -- colony tiers and reputation bands are returned by functions rather than
    -- held in a table, so they are swept by calling them across their range
    for tier = 1, 5 do emit(colony.tierName(tier), "src/sim/colony.lua (tier)") end

    local Player = require("src.sim.player")
    local probe = setmetatable({ reputations = {} }, { __index = Player })
    for _, r in ipairs({ 1, 0.6, 0.2, 0, -0.2, -0.6, -1 }) do
        probe.reputation = function() return r end
        emit(Player.reputationName(probe, "federation"), "src/sim/player.lua (reputation)")
    end

    local systemGen = require("src.procgen.system")
    for _, k in ipairs(systemGen.STATION_KINDS or {}) do
        emit(k.name, "src/procgen/system.lua (station kind)")
    end

    local buildings = require("src.procgen.buildings")
    for _, k in ipairs(buildings.kinds) do emit(k.name, "src/procgen/buildings.lua") end

    local interior = require("src.procgen.interior")
    for _, r in pairs(interior.kinds or {}) do emit(r.name, "src/procgen/interior.lua") end

    for _, t in ipairs(systemGen.PLANET_TYPES or {}) do
        emit(t.name, "src/procgen/system.lua (planet type)")
    end

    local progression = require("src.sim.progression")
    for _, r in ipairs(progression.RANKS) do emit(r.name, "src/sim/progression.lua (rank)") end
    for _, u in pairs(progression.UNLOCKS) do emit(u, "src/sim/progression.lua (unlock)") end

    local pois = require("src.procgen.pois")
    for _, list in ipairs({ pois.SPACE_KINDS or {}, pois.SURFACE_KINDS or {} }) do
        for _, k in ipairs(list) do emit(k.name, "src/procgen/pois.lua") end
    end
end

local okSweep, sweepErr = pcall(sweepData)
if not okSweep then
    print("warning: data sweep incomplete: " .. tostring(sweepErr))
end

local missing, translated = {}, 0
for _, text in ipairs(order) do
    if i18n.strings[text] or i18n.nouns[text] then
        translated = translated + 1
    else
        missing[#missing + 1] = text
    end
end
table.sort(missing)

local total = #order
print(string.format("locale %s: %d/%d literals translated (%.0f%%)",
    locale, translated, total, total > 0 and translated / total * 100 or 100))

if #missing > 0 then
    print("")
    print("missing (" .. #missing .. "):")
    for _, text in ipairs(missing) do
        print(string.format('    [%q] = "",   -- %s', text, seen[text].file))
    end
end

os.exit(#missing == 0 and 0 or 1)

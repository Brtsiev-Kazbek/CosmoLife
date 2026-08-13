-- Localisation.
--
-- Strings are keyed by their English source text rather than by an abstract
-- id. That is a deliberate trade: it means every call site stays readable
-- (`L("Landing gear down")` says what it shows), a missing translation falls
-- back to sensible English instead of printing `hud.gear.down`, and the game
-- can be translated incrementally without a big-bang refactor.
--
-- The cost is that changing the English text orphans its translation. The
-- `--audit` report below exists to catch exactly that.
--
--   L("Docked at %s"):format(name)      -- pattern strings keep their %s
--   L("Fuel")                           -- plain strings

local i18n = {}

i18n.available = { "en", "ru" }
i18n.names = { en = "English", ru = "Русский" }

i18n.locale = "en"
i18n.strings = {}

--- Loads a locale table. `en` is the identity locale and needs no file.
function i18n.setLocale(code)
    if code == i18n.locale and i18n.loaded then return true end
    if code == "en" then
        i18n.strings = {}
        i18n.locale = "en"
        i18n.loaded = true
        return true
    end
    local ok, tbl = pcall(require, "src.locale." .. tostring(code))
    if not ok or type(tbl) ~= "table" then return false, tbl end
    i18n.strings = tbl
    i18n.locale = code
    i18n.loaded = true
    return true
end

--- Translates a string, falling back to the source text.
function i18n.translate(text)
    if type(text) ~= "string" then return text end
    local hit = i18n.strings[text]
    if hit then return hit end
    -- record the miss so `i18n.missing()` can report what still needs doing
    if i18n.locale ~= "en" then
        i18n.misses = i18n.misses or {}
        i18n.misses[text] = true
    end
    return text
end

--- Translates and formats in one call: L("Docked at %s", name).
function i18n.format(text, ...)
    local s = i18n.translate(text)
    if select("#", ...) == 0 then return s end
    local ok, result = pcall(string.format, s, ...)
    if ok then return result end
    -- a translation with the wrong placeholders must not crash the game
    return string.format(text, ...)
end

--- Every source string looked up that had no translation, sorted.
function i18n.missing()
    local out = {}
    for text in pairs(i18n.misses or {}) do out[#out + 1] = text end
    table.sort(out)
    return out
end

function i18n.next()
    local idx = 1
    for i, c in ipairs(i18n.available) do if c == i18n.locale then idx = i end end
    return i18n.available[(idx % #i18n.available) + 1]
end

return i18n

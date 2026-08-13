-- Localisation.
--
-- Strings are keyed by their English source text rather than by an abstract
-- id. That is a deliberate trade: it means every call site stays readable
-- (`L("Landing gear down")` says what it shows), a missing translation falls
-- back to sensible English instead of printing `hud.gear.down`, and the game
-- can be translated incrementally without a big-bang refactor.
--
--   L("Fuel")                           -- plain strings
--   L("Docked at {name}", { name = s }) -- named templates
--   L("Docked at %s"):format(name)      -- legacy printf strings still work
--
-- ---------------------------------------------------------------------------
-- Why this file is bigger than a lookup table
--
-- English gets away with concatenation: "Deliver 12 t of Grain to Reen Port".
-- Russian does not. That same sentence needs the commodity in the genitive,
-- the destination in the accusative, and "t" agreeing with 12 in a way that
-- differs for 1, 2-4 and 5-20. `string.format` cannot express any of that, so
-- a translation built on it is either wrong or written in telegraph style.
--
-- So the format layer takes *named* arguments, and an argument may be a noun
-- object carrying its own declensions:
--
--   local grain = i18n.noun("Зерно", "neuter")
--   L("Deliver {qty} {qty:t} of {cargo} to {dest}",
--     { qty = 12, cargo = grain, dest = port })
--
-- A placeholder may name a case (`{cargo:gen}`), and `{qty:t}` picks the right
-- plural form of the unit registered under "t". Everything degrades safely:
-- an unknown placeholder prints its own name rather than erroring, and the
-- English locale ignores the case tags entirely because English nouns are
-- plain strings.

local i18n = {}

i18n.available = { "en", "ru" }
i18n.names = { en = "English", ru = "Русский" }

i18n.locale = "en"
i18n.strings = {}

-- ---------------------------------------------------------------------------
-- Nouns
-- ---------------------------------------------------------------------------

--- The six cases we actually use, in the order Russian schoolbooks list them.
i18n.CASES = { "nom", "gen", "dat", "acc", "ins", "pre" }

local Noun = {}
Noun.__index = Noun

--- Nouns print as their nominative when used as a plain string, so passing one
--- to `tostring`, `..` or an untagged placeholder always does something sane.
function Noun.__tostring(self) return self.nom end
Noun.__concat = function(a, b)
    if type(a) == "table" then a = a.nom end
    if type(b) == "table" then b = b.nom end
    return a .. b
end

function i18n.isNoun(v)
    return type(v) == "table" and getmetatable(v) == Noun
end

--- Declension patterns.
--
-- Each entry maps a stem to the six singular cases and the three plural forms
-- the counting rule needs. These are the productive types -- the ones that
-- cover ordinary vocabulary. Anything irregular is written out by hand via
-- `i18n.noun(base, { gen = ..., acc = ... })`.
--
-- `animate` matters because the accusative of an animate masculine noun copies
-- the genitive, not the nominative: "вижу колониста", not "вижу колонист".
--
-- Hard and soft stems take different endings, and the split is not cosmetic:
-- "станция" declines to "станции", never "станциы". Softness is detected from
-- the dictionary form's last letter, not asked of the caller.
local PATTERNS = {}

-- Every Cyrillic letter is two bytes in UTF-8, so a fixed-width tail works.
local function tail(s, n) return s:sub(-2 * (n or 1)) end
local function chop(s, n) return s:sub(1, #s - 2 * (n or 1)) end

local VOWEL = {
    ["а"] = true, ["е"] = true, ["ё"] = true, ["и"] = true, ["о"] = true,
    ["у"] = true, ["ы"] = true, ["э"] = true, ["ю"] = true, ["я"] = true,
}

-- Заднеязычные и шипящие: после них по правилу орфографии пишется «и», а не
-- «ы». Это не мягкость -- «наркотики» склоняются как твёрдые «минералы», --
-- поэтому окончание «-и» после них нельзя принимать за мягкий тип.
local VELAR = {
    ["к"] = true, ["г"] = true, ["х"] = true,
    ["ж"] = true, ["ч"] = true, ["ш"] = true, ["щ"] = true,
}

-- жен.: планета (твёрдая), станция (мягкая на -ия), земля (мягкая)
--
-- The -ия type is worth its own branch because it takes -ии in the dative and
-- prepositional where plain soft stems take -е: "к станции", but "к земле".
PATTERNS.fem = {
    gender = "f",
    build = function(stem, soft)
        if not soft then
            -- после заднеязычных «-и», а не «-ы»: робототехника -> робототехники
            local y = VELAR[tail(stem)] and "и" or "ы"
            return {
                nom = stem .. "а", gen = stem .. y, dat = stem .. "е",
                acc = stem .. "у", ins = stem .. "ой", pre = stem .. "е",
                one = stem .. "а", few = stem .. y, many = stem,
            }
        end
        local iType = VOWEL[tail(stem)] ~= nil          -- станци|я, колони|я
        local de = iType and (stem .. "и") or (stem .. "е")
        return {
            nom = stem .. "я", gen = stem .. "и", dat = de,
            acc = stem .. "ю", ins = stem .. "ей", pre = de,
            one = stem .. "я", few = stem .. "и", many = stem .. "й",
        }
    end,
}

-- муж.: реактор (твёрдый), корабль (мягкий на -ь)
PATTERNS.masc = {
    gender = "m",
    build = function(stem, soft, animate)
        if not soft then
            return {
                nom = stem, gen = stem .. "а", dat = stem .. "у",
                acc = animate and (stem .. "а") or stem,
                ins = stem .. "ом", pre = stem .. "е",
                one = stem, few = stem .. "а", many = stem .. "ов",
            }
        end
        return {
            nom = stem .. "ь", gen = stem .. "я", dat = stem .. "ю",
            acc = animate and (stem .. "я") or (stem .. "ь"),
            ins = stem .. "ем", pre = stem .. "е",
            one = stem .. "ь", few = stem .. "я", many = stem .. "ей",
        }
    end,
}

-- ср.: зерно (твёрдое), оборудование (мягкое на -ие)
PATTERNS.neuter = {
    gender = "n",
    build = function(stem, soft)
        if not soft then
            return {
                nom = stem .. "о", gen = stem .. "а", dat = stem .. "у",
                acc = stem .. "о", ins = stem .. "ом", pre = stem .. "е",
                one = stem .. "о", few = stem .. "а", many = stem,
            }
        end
        return {
            nom = stem .. "е", gen = stem .. "я", dat = stem .. "ю",
            acc = stem .. "е", ins = stem .. "ем", pre = stem .. "и",
            one = stem .. "е", few = stem .. "я", many = stem .. "й",
        }
    end,
}

-- Слова, у которых игровое значение всегда во множественном: медикаменты,
-- колонисты, специи. Мягкий вариант -- на -и (специи).
PATTERNS.plural = {
    gender = "p",
    build = function(stem, soft)
        if soft then
            -- родительный мн.: после гласной -- «-й» (специи -> специй),
            -- после согласной -- «-ей» (ткани -> тканей)
            local gen = VOWEL[tail(stem)] and (stem .. "й") or (stem .. "ей")
            return {
                nom = stem .. "и", gen = gen, dat = stem .. "ям",
                acc = stem .. "и", ins = stem .. "ями", pre = stem .. "ях",
                one = stem .. "я", few = stem .. "и", many = gen,
            }
        end
        local y = VELAR[tail(stem)] and "и" or "ы"
        return {
            nom = stem .. y, gen = stem .. "ов", dat = stem .. "ам",
            acc = stem .. y, ins = stem .. "ами", pre = stem .. "ах",
            one = stem, few = stem .. "а", many = stem .. "ов",
        }
    end,
}

-- Несклоняемое: аббревиатуры, латиница, «кр»
PATTERNS.invariant = {
    gender = "n",
    build = function(stem)
        return {
            nom = stem, gen = stem, dat = stem, acc = stem, ins = stem, pre = stem,
            one = stem, few = stem, many = stem,
        }
    end,
}

--- Which dictionary ending belongs to which pattern, and whether it is soft.
--- The caller writes the word as it appears in a dictionary; we work out the
--- stem and the hard/soft split from the ending.
local ENDINGS = {
    fem    = { ["а"] = false, ["я"] = true },
    neuter = { ["о"] = false, ["е"] = true },
    plural = { ["ы"] = false, ["и"] = true },
    masc   = { ["ь"] = true },
}

--- Builds a declinable noun.
--
--   i18n.noun("Планета", "fem")           -- планеты, планете, планету...
--   i18n.noun("Станция", "fem")           -- станции, станции, станцию...
--   i18n.noun("Колонист", "masc", { animate = true })
--   i18n.noun("Специи", "plural")
--   i18n.noun("Мышь", "fem", { gen = "мыши", dat = "мыши" })  -- overrides
--
-- `opts.gender` overrides the pattern's gender for adjective agreement. Any of
-- the six cases or three counting forms given in `opts` overrides what the
-- pattern produced, which is how irregulars are handled without a new pattern.
function i18n.noun(base, pattern, opts)
    opts = opts or {}
    if i18n.isNoun(base) then return base end
    pattern = pattern or "invariant"
    local p = PATTERNS[pattern] or PATTERNS.invariant

    local stem, soft = base, opts.soft
    local endings = ENDINGS[pattern]
    if endings then
        local isSoft = endings[tail(base)]
        if isSoft ~= nil then
            stem = chop(base)
            -- «наркотики», «сверхпроводники»: «-и» тут орфографическое, тип
            -- твёрдый
            if isSoft and VELAR[tail(stem)] then isSoft = false end
            if soft == nil then soft = isSoft end
        elseif pattern ~= "masc" then
            -- The dictionary form does not end the way this pattern expects,
            -- which happens for multi-word terms whose head noun is not last
            -- ("Батарея щитовых ячеек", "Форсировка двигателей"). Appending an
            -- ending would mangle it, so treat the phrase as given and let the
            -- caller's explicit overrides supply the oblique cases.
            --
            -- Masculine is excluded because a hard masculine noun legitimately
            -- has no ending to strip: "Реактор" is already its own stem.
            p = PATTERNS.invariant
        end
    end

    local forms = p.build(stem, soft, opts.animate)
    -- gender comes from the declared pattern, not from whatever pattern ended
    -- up building the forms, so a phrase that fell back to `invariant` still
    -- agrees as feminine
    forms.gender = opts.gender or (PATTERNS[pattern] or p).gender
    forms.stem = stem
    forms.pattern = pattern
    for _, c in ipairs(i18n.CASES) do
        if opts[c] then forms[c] = opts[c] end
    end

    -- Multi-word terms decline on their head word, which is not always the
    -- last one ("Комплект основания колонии"), so the counting rule cannot be
    -- derived mechanically. Rather than emit "Комплект основания колонииов",
    -- fall back to the nominative unless the dictionary spells the forms out.
    local phrase = base:find(" ", 1, true) ~= nil
    for _, c in ipairs({ "one", "few", "many" }) do
        if opts[c] then
            forms[c] = opts[c]
        elseif phrase then
            forms[c] = forms.nom
        end
    end

    -- Dictionary forms are capitalised because they double as display names;
    -- hand-written overrides are easy to type in lower case. Normalising here
    -- means the two can never disagree, and `:lc` still lowers a form when it
    -- lands mid-sentence.
    local upper = base ~= i18n.lcFirst(base)
    local fix = upper and i18n.ucFirst or i18n.lcFirst
    for _, c in ipairs(i18n.CASES) do forms[c] = fix(forms[c]) end
    for _, c in ipairs({ "one", "few", "many" }) do forms[c] = fix(forms[c]) end
    return setmetatable(forms, Noun)
end

--- The case form of a value. Plain strings have no cases, so they come back
--- unchanged -- which is exactly right for English and for proper nouns we
--- have chosen not to decline.
function i18n.case(value, which)
    if i18n.isNoun(value) then return value[which] or value.nom end
    return tostring(value)
end

-- ---------------------------------------------------------------------------
-- Letter case
-- ---------------------------------------------------------------------------
--
-- Dictionary entries are capitalised because that is how they appear in menus
-- ("Зерно", "Медикаменты"). Dropped into the middle of a sentence they need to
-- be lower case ("12 тонн зерна"), and `string.lower` only knows ASCII. These
-- two touch the first letter only, which is all the distinction requires.

--- Lower-cases the first letter, Cyrillic included.
function i18n.lcFirst(s)
    local b1, b2 = s:byte(1, 2)
    if not b1 then return s end
    if b1 == 0xD0 and b2 then
        if b2 >= 0x90 and b2 <= 0x9F then                 -- А-П
            return string.char(0xD0, b2 + 0x20) .. s:sub(3)
        elseif b2 >= 0xA0 and b2 <= 0xAF then             -- Р-Я
            return string.char(0xD1, b2 - 0x20) .. s:sub(3)
        elseif b2 == 0x81 then                            -- Ё
            return string.char(0xD1, 0x91) .. s:sub(3)
        end
        return s
    end
    return s:sub(1, 1):lower() .. s:sub(2)
end

--- Upper-cases the first letter, Cyrillic included.
function i18n.ucFirst(s)
    local b1, b2 = s:byte(1, 2)
    if not b1 then return s end
    if b1 == 0xD0 and b2 and b2 >= 0xB0 and b2 <= 0xBF then       -- а-п
        return string.char(0xD0, b2 - 0x20) .. s:sub(3)
    elseif b1 == 0xD1 and b2 then
        if b2 >= 0x80 and b2 <= 0x8F then                         -- р-я
            return string.char(0xD0, b2 + 0x20) .. s:sub(3)
        elseif b2 == 0x91 then                                    -- ё
            return string.char(0xD0, 0x81) .. s:sub(3)
        end
        return s
    end
    return s:sub(1, 1):upper() .. s:sub(2)
end

-- ---------------------------------------------------------------------------
-- Plurals
-- ---------------------------------------------------------------------------

--- Russian counting rule.
--
--   1, 21, 101   -> one   (тонна)
--   2-4, 22-24   -> few   (тонны)
--   0, 5-20, 25  -> many  (тонн)
--
-- 11-14 are the exception that makes the naive `n % 10` version wrong, which
-- is why the teens are tested explicitly.
function i18n.pluralForm(n)
    n = math.abs(math.floor(tonumber(n) or 0))
    local mod100 = n % 100
    if mod100 >= 11 and mod100 <= 14 then return "many" end
    local mod10 = n % 10
    if mod10 == 1 then return "one" end
    if mod10 >= 2 and mod10 <= 4 then return "few" end
    return "many"
end

--- English rule, used when the locale has no plural table of its own.
local function pluralFormEn(n)
    return (math.abs(tonumber(n) or 0) == 1) and "one" or "many"
end

--- Picks a form: i18n.plural(n, "тонна", "тонны", "тонн")
function i18n.plural(n, one, few, many)
    local form = (i18n.locale == "ru") and i18n.pluralForm(n) or pluralFormEn(n)
    if form == "one" then return one end
    if form == "few" then return few or many or one end
    return many or few or one
end

--- Units registered by name so templates can write `{qty:t}` and get "тонна",
--- "тонны" or "тонн" without the call site knowing the rule exists.
i18n.units = {}

--- i18n.unit("t", "тонна", "тонны", "тонн")
function i18n.unit(name, one, few, many)
    i18n.units[name] = { one = one, few = few, many = many }
end

local function unitForm(name, n)
    local u = i18n.units[name]
    if not u then return nil end
    local form = (i18n.locale == "ru") and i18n.pluralForm(n) or pluralFormEn(n)
    return u[form] or u.many or u.one
end

-- ---------------------------------------------------------------------------
-- Locale loading
-- ---------------------------------------------------------------------------

--- Declinable terms, keyed by their English source string. Separate from
--- `strings` because the value is a noun object rather than a plain string.
i18n.nouns = {}

--- Loads a locale table. `en` is the identity locale and needs no file.
--
-- A locale module may return either a flat `{ ["Fuel"] = "Топливо" }` table or
-- a structured `{ strings = ..., nouns = ..., units = ... }` one. The flat form
-- is kept working so a new language can start as a single lookup table.
function i18n.setLocale(code)
    if code == i18n.locale and i18n.loaded then return true end
    if code == "en" then
        i18n.strings, i18n.nouns, i18n.units = {}, {}, {}
        i18n.locale = "en"
        i18n.loaded = true
        if i18n.onLocaleChanged then i18n.onLocaleChanged(code) end
        return true
    end
    local ok, tbl = pcall(require, "src.locale." .. tostring(code))
    if not ok or type(tbl) ~= "table" then return false, tbl end
    i18n.strings = tbl.strings or tbl
    i18n.nouns = tbl.nouns or {}
    i18n.units = tbl.units or {}
    i18n.locale = code
    i18n.loaded = true
    if i18n.onLocaleChanged then i18n.onLocaleChanged(code) end
    return true
end

--- The declinable term for an English source string.
--
-- Returns a noun object when the locale declares one, a translated string when
-- the locale has one, and the text itself otherwise. Call sites that only
-- display a name can keep using `L(name)`; the ones that build a sentence
-- around it use this.
--
-- Unlike `translate` this does not record a miss: it is routinely handed
-- procedurally generated proper nouns ("Реен Прима"), which are not dictionary
-- entries and never will be.
function i18n.term(text)
    if type(text) ~= "string" then return text end
    local n = i18n.nouns[text]
    if n then return n end
    return i18n.strings[text] or text
end

-- ---------------------------------------------------------------------------
-- Translation and formatting
-- ---------------------------------------------------------------------------

--- Translates a string, falling back to the source text.
--
-- A term declared as a declinable noun translates to its nominative, so a
-- plain `L("Grain")` in a menu prints "Зерно" without the call site knowing
-- that the word also has five other forms.
function i18n.translate(text)
    if type(text) ~= "string" then return text end
    local hit = i18n.strings[text]
    if hit then return hit end
    local noun = i18n.nouns[text]
    if noun then return noun.nom end
    -- record the miss so `i18n.missing()` can report what still needs doing
    if i18n.locale ~= "en" then
        i18n.misses = i18n.misses or {}
        i18n.misses[text] = true
    end
    return text
end

local CASE_SET = {}
for _, c in ipairs(i18n.CASES) do CASE_SET[c] = true end

--- The counting form of a noun for a given number: 1 тонна / 2 тонны / 5 тонн.
function i18n.countForm(value, n)
    if not i18n.isNoun(value) then return tostring(value) end
    local form = (i18n.locale == "ru") and i18n.pluralForm(n) or pluralFormEn(n)
    return value[form] or value.nom
end

--- Expands `{name}` and `{name:tag:tag...}` against a table of arguments.
--
-- Tags are applied left to right and each is one of:
--
--   gen acc dat ins pre nom   grammatical case
--   count [argname]           counting form; the number comes from the named
--                             argument, or from `n`/`qty`/`count` if omitted
--   <unit>                    a unit registered with `i18n.unit`, agreeing
--                             with this placeholder's own numeric value
--   lc / uc                   lower- or upper-case the first letter
--
-- So `"{qty} {qty:t} {cargo:gen:lc}"` renders as "12 тонн зерна", and
-- `"{qty} {cargo:count:qty:lc}"` as "3 контейнера".
--
-- An unresolvable placeholder prints its own name in braces so a broken
-- template is visible in-game rather than silently blank.
local function expand(template, args)
    return (template:gsub("{([%w_]+)([:%w_]*)}", function(name, chain)
        local v = args[name]
        if v == nil then return "{" .. name .. "}" end

        local out = nil
        if chain ~= "" then
            -- collect the tags once so `count` can consume the one after it
            local tags, i = {}, 0
            for tag in chain:gmatch("[^:]+") do tags[#tags + 1] = tag end
            i = 1
            while i <= #tags do
                local tag = tags[i]
                if CASE_SET[tag] then
                    out = i18n.case(v, tag)
                elseif tag == "count" then
                    local n = tonumber(args[tags[i + 1] or ""])
                    if n then
                        i = i + 1
                    else
                        n = tonumber(args.n) or tonumber(args.qty)
                            or tonumber(args.count) or 0
                    end
                    out = i18n.countForm(v, n)
                elseif i18n.units[tag] then
                    out = unitForm(tag, tonumber(v) or 0)
                elseif tag == "lc" then
                    out = i18n.lcFirst(out or i18n.case(v, "nom"))
                elseif tag == "uc" then
                    out = i18n.ucFirst(out or i18n.case(v, "nom"))
                end
                i = i + 1
            end
        end
        return out or i18n.case(v, "nom")
    end))
end

--- Translates and formats in one call.
--
--   i18n.format("Fuel")                                  -- plain
--   i18n.format("Docked at {name}", { name = station })   -- named
--   i18n.format("Docked at %s", name)                     -- legacy printf
--
-- The named form is chosen when a single table argument is passed. Legacy
-- printf strings keep working so the whole codebase does not have to convert
-- in one go, and a translation with the wrong placeholders falls back to the
-- English source rather than crashing.
function i18n.format(text, ...)
    local s = i18n.translate(text)
    local n = select("#", ...)
    if n == 0 then return s end
    local first = ...
    if n == 1 and type(first) == "table" and not i18n.isNoun(first) then
        local ok, result = pcall(expand, s, first)
        if ok then return result end
        local ok2, fallback = pcall(expand, text, first)
        return ok2 and fallback or text
    end
    local ok, result = pcall(string.format, s, ...)
    if ok then return result end
    local ok2, fallback = pcall(string.format, text, ...)
    return ok2 and fallback or text
end

-- ---------------------------------------------------------------------------
-- Coverage reporting
-- ---------------------------------------------------------------------------

--- Every source string looked up that had no translation, sorted.
function i18n.missing()
    local out = {}
    for text in pairs(i18n.misses or {}) do out[#out + 1] = text end
    table.sort(out)
    return out
end

--- Same list, but as a report the tests can assert on and `--audit` can print.
function i18n.coverage()
    local missing = i18n.missing()
    local total = 0
    for _ in pairs(i18n.strings) do total = total + 1 end
    return { locale = i18n.locale, translated = total, missing = missing }
end

function i18n.resetCoverage() i18n.misses = nil end

function i18n.next()
    local idx = 1
    for i, c in ipairs(i18n.available) do if c == i18n.locale then idx = i end end
    return i18n.available[(idx % #i18n.available) + 1]
end

return i18n

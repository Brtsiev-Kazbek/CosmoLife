-- Procedural naming.
--
-- Star systems use the trick the original Elite used: a table of two letter
-- digrams sampled by the system seed.  It produces pronounceable, faintly
-- alien names ("Lave", "Zaonce", "Tionisla") from almost no data.  Everything
-- else -- people, ships, corporations, settlements -- is assembled from small
-- word banks so that a name always carries a little information about what it
-- labels.
--
-- ---------------------------------------------------------------------------
-- Why the banks are per language
--
-- Transliterating a finished name does not work: "Kepler Port" becomes "Порт
-- Кеплера", which is a different word order *and* a case change, and "Silent
-- Migration" becomes "Молчаливая Миграция" only if the adjective is inflected
-- to match the noun's gender. Neither is recoverable from the English string.
--
-- So each language gets its own banks, and the seed picks an *index* rather
-- than a word. A given system is the same entry in every language -- same
-- identity, spelled the way that language spells it.
--
-- Names are derived from seeds and never stored, so switching language
-- renames the galaxy. That is intended; nothing keys off a name.

local Rng = require("src.lib.rng")
local i18n = require("src.i18n")

local names = {}

-- ---------------------------------------------------------------------------
-- Word banks
-- ---------------------------------------------------------------------------

local BANKS = {}

BANKS.en = {
    digrams = {
        "ab", "ou", "se", "it", "ed", "or", "ve", "xe", "za", "ce", "bi", "so",
        "us", "es", "ar", "ma", "in", "di", "re", "a", "er", "at", "en", "be",
        "ra", "la", "vi", "ti", "qu", "on", "el", "an", "ge", "ne", "il", "ec",
        "te", "is", "ri", "on", "za", "le", "us", "sa", "ta", "ri", "ka", "on",
    },
    suffix = { "", "", "", "", " Prime", " Secundus", " Major", " Minor",
               " II", " III", " IV", " IX", " Reach", " Gate", " Rift" },
    greek = { "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta",
              "Theta", "Iota", "Kappa", "Lambda", "Mu" },
    moonLetters = "abcdefghijkl",
    beltForm = "{system} {greek} Belt",

    -- station: a prefix and a name, in either order
    -- English reads either way round, so the order is part of the variety
    stationOrderSwaps = true,
    stationPrefix = { "Port", "Station", "Terminal", "Depot", "Anchorage",
                      "Waypoint", "Hub", "Outpost", "Dock", "Relay", "Keep", "Bastion" },
    stationNames = { "Kepler", "Hakim", "Novak", "Oyelaran", "Bright", "Sorensen",
                     "Ibarra", "Vaduva", "Amundsen", "Chen", "Okonkwo", "Reyes",
                     "Lindqvist", "Farid", "Tsiolkovsky", "Mbeki", "Halden", "Vega",
                     "Corvus", "Meridian", "Solace", "Ashfall", "Longhaul",
                     "Ironside", "Quiet Harbour", "Last Light", "Coldstart" },

    settlementRoot = { "New", "Old", "Fort", "Camp", "Mount", "Port", "Cape",
                       "Lower", "Upper", "North", "South" },
    settlementBody = { "Haven", "Landing", "Crossing", "Furnace", "Anvil", "Hollow",
                       "Ridge", "Basin", "Prospect", "Quarry", "Terrace", "Beacon",
                       "Refuge", "Foundry", "Garden", "Spire", "Cistern",
                       "Threshold", "Verge", "Salvation", "Endeavour", "Redoubt" },
    settlementTail = { "Station", "Colony", "Works", "Post", "Fields", "Yards", "Point" },

    first = { "Ada", "Ines", "Kai", "Noor", "Rina", "Sol", "Tam", "Vela", "Yusuf",
              "Zora", "Bram", "Cato", "Dara", "Esen", "Faye", "Goran", "Halim",
              "Ivo", "Juno", "Kesi", "Lars", "Mira", "Nika", "Oren", "Pia",
              "Rhea", "Suri", "Teo", "Uma" },
    last = { "Achebe", "Bardem", "Coelho", "Duarte", "Eriksen", "Fontaine",
             "Gustafsson", "Hollis", "Ivanova", "Jarrah", "Kovacs", "Lindholm",
             "Moreau", "Nakamura", "Okafor", "Petrov", "Quintero", "Rasmussen",
             "Sato", "Tanaka", "Ueda", "Volkov", "Weiss", "Xu", "Yilmaz", "Zeleny" },

    corpA = { "Vector", "Helios", "Onyx", "Kestrel", "Tessera", "Orbital", "Iron",
              "Meridian", "Cobalt", "Quartz", "Aster", "Halcyon" },
    corpB = { "Dynamics", "Combine", "Freight", "Holdings", "Industries", "Mining",
              "Logistics", "Foundry", "Salvage", "Shipwrights", "Agritech", "Sciences" },
    corpForm = "{a} {b}",

    shipAdjective = { "Silent", "Iron", "Red", "Distant", "Broken", "Patient",
                      "Wandering", "Cold", "Bright", "Second", "Blind", "Hollow" },
    shipNoun = { "Vagrant", "Promise", "Meridian", "Answer", "Errand", "Custom",
                 "Verdict", "Anchor", "Compass", "Lantern", "Debt", "Migration" },
}

-- Русские банки.
--
-- Прилагательные хранятся в трёх родах, существительные -- с пометой рода,
-- чтобы «Молчаливый Странник», но «Молчаливая Миграция».
-- Названия станций записаны сразу в родительном падеже: конструкция всегда
-- «Порт Кеплера», «Станция Тихой Гавани».
BANKS.ru = {
    digrams = {
        "аб", "оу", "се", "ит", "эд", "ор", "ве", "ксе", "за", "це", "би", "со",
        "ус", "эс", "ар", "ма", "ин", "ди", "ре", "а", "эр", "ат", "эн", "бе",
        "ра", "ла", "ви", "ти", "ку", "он", "эл", "ан", "ге", "не", "ил", "эк",
        "те", "ис", "ри", "он", "за", "ле", "ус", "са", "та", "ри", "ка", "он",
    },
    suffix = { "", "", "", "", " Прима", " Секунда", " Майор", " Минор",
               " II", " III", " IV", " IX", " Предел", " Врата", " Разлом" },
    greek = { "Альфа", "Бета", "Гамма", "Дельта", "Эпсилон", "Дзета", "Эта",
              "Тета", "Йота", "Каппа", "Лямбда", "Мю" },
    moonLetters = { "а", "б", "в", "г", "д", "е", "ж", "з", "и", "к", "л", "м" },
    beltForm = "пояс {system} {greek}",

    stationPrefix = { "Порт", "Станция", "Терминал", "Депо", "Причал",
                      "Разъезд", "Узел", "Аванпост", "Док", "Ретранслятор",
                      "Форпост", "Бастион" },
    -- родительный падеж: «Порт Кеплера»
    stationNames = { "Кеплера", "Хакима", "Новака", "Оеларана", "Брайта",
                     "Соренсена", "Ибарры", "Вадувы", "Амундсена", "Чена",
                     "Оконкво", "Рейеса", "Линдквиста", "Фарида", "Циолковского",
                     "Мбеки", "Халдена", "Веги", "Корвуса", "Меридиана",
                     "Утешения", "Пепельного Дождя", "Долгого Пути",
                     "Железнобокого", "Тихой Гавани", "Последнего Света",
                     "Холодного Старта" },

    -- приложения к названию посёлка: «Форт Наковальня», «Новая Посадка»
    settlementRoot = {
        { "Новый", "Новая", "Новое" },
        { "Старый", "Старая", "Старое" },
        { "Форт", noun = true },
        { "Лагерь", noun = true },
        { "Гора", noun = true },
        { "Порт", noun = true },
        { "Мыс", noun = true },
        { "Нижний", "Нижняя", "Нижнее" },
        { "Верхний", "Верхняя", "Верхнее" },
        { "Северный", "Северная", "Северное" },
        { "Южный", "Южная", "Южное" },
    },
    settlementBody = {
        { "Приют", "m" }, { "Посадка", "f" }, { "Переправа", "f" },
        { "Горнило", "n" }, { "Наковальня", "f" }, { "Лощина", "f" },
        { "Гребень", "m" }, { "Котловина", "f" }, { "Прииск", "m" },
        { "Карьер", "m" }, { "Терраса", "f" }, { "Маяк", "m" },
        { "Убежище", "n" }, { "Литейная", "f" }, { "Сад", "m" },
        { "Шпиль", "m" }, { "Цистерна", "f" }, { "Порог", "m" },
        { "Грань", "f" }, { "Спасение", "n" }, { "Дерзание", "n" },
        { "Редут", "m" },
    },
    settlementTail = { "Станция", "Колония", "Заводы", "Пост", "Поля", "Верфи", "Точка" },

    first = { "Ада", "Инес", "Кай", "Нур", "Рина", "Сол", "Там", "Вела", "Юсуф",
              "Зора", "Брам", "Като", "Дара", "Эсен", "Фэй", "Горан", "Халим",
              "Иво", "Юно", "Кеси", "Ларс", "Мира", "Ника", "Орен", "Пиа",
              "Рея", "Сури", "Тео", "Ума" },
    last = { "Ачебе", "Бардем", "Коэльо", "Дуарте", "Эриксен", "Фонтен",
             "Густафссон", "Холлис", "Иванова", "Джарра", "Ковач", "Линдхольм",
             "Моро", "Накамура", "Окафор", "Петров", "Кинтеро", "Расмуссен",
             "Сато", "Танака", "Уэда", "Волков", "Вайс", "Сюй", "Йылмаз", "Зелены" },

    corpA = { "Вектор", "Гелиос", "Оникс", "Кестрел", "Тессера", "Орбитал",
              "Айрон", "Меридиан", "Кобальт", "Кварц", "Астер", "Гальциона" },
    corpB = { "Динамика", "Комбинат", "Фрахт", "Холдинг", "Индустрия", "Рудники",
              "Логистика", "Литейная", "Утилизация", "Верфи", "Агротех", "Науки" },
    corpForm = "{a}-{b}",

    shipAdjective = {
        { "Молчаливый", "Молчаливая", "Молчаливое" },
        { "Железный", "Железная", "Железное" },
        { "Красный", "Красная", "Красное" },
        { "Далёкий", "Далёкая", "Далёкое" },
        { "Сломанный", "Сломанная", "Сломанное" },
        { "Терпеливый", "Терпеливая", "Терпеливое" },
        { "Блуждающий", "Блуждающая", "Блуждающее" },
        { "Холодный", "Холодная", "Холодное" },
        { "Яркий", "Яркая", "Яркое" },
        { "Второй", "Вторая", "Второе" },
        { "Слепой", "Слепая", "Слепое" },
        { "Пустой", "Пустая", "Пустое" },
    },
    shipNoun = {
        { "Бродяга", "m" }, { "Обещание", "n" }, { "Меридиан", "m" },
        { "Ответ", "m" }, { "Поручение", "n" }, { "Обычай", "m" },
        { "Приговор", "m" }, { "Якорь", "m" }, { "Компас", "m" },
        { "Фонарь", "m" }, { "Долг", "m" }, { "Миграция", "f" },
    },
}

--- The bank for the active locale, falling back to English.
local function bank()
    return BANKS[i18n.locale] or BANKS.en
end

names.banks = BANKS

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

--- A star system name.  `length` is drawn from the seed so names vary.
function names.system(seed)
    local rng = Rng.new(seed, "system-name")
    local b = bank()
    local parts = rng:int(2, 4)
    local idx = {}
    for i = 1, parts do idx[i] = rng:int(1, #b.digrams) end
    local suffixRoll = rng:bool(0.16) and rng:int(1, #b.suffix) or nil

    local s = {}
    for i = 1, parts do s[i] = b.digrams[idx[i]] end
    local name = table.concat(s)
    name = i18n.ucFirst(name)
    if suffixRoll then name = name .. b.suffix[suffixRoll] end
    return name
end

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" }

--- Planets are named after their star, catalogue style.
function names.planet(systemName, index)
    return systemName .. " " .. (ROMAN[index] or tostring(index))
end

function names.moon(planetName, index)
    local letters = bank().moonLetters
    if type(letters) == "table" then
        return planetName .. (letters[index] or tostring(index))
    end
    return planetName .. (letters:sub(index, index) ~= "" and letters:sub(index, index)
        or tostring(index))
end

function names.belt(systemName, index)
    local b = bank()
    local form = b.beltForm
    return (form:gsub("{system}", systemName)
                :gsub("{greek}", b.greek[index] or b.greek[#b.greek]))
end

--- Station names.
--
-- English swaps the word order half the time ("Kepler Port" / "Port Kepler").
-- Russian cannot: the two orders are different cases, and only one of them is
-- idiomatic. The Russian bank therefore stores genitives and always builds
-- "<prefix> <name-in-genitive>".
function names.station(seed)
    local rng = Rng.new(seed, "station")
    local b = bank()
    local swap = rng:bool(0.55)
    local nameIdx = rng:int(1, #b.stationNames)
    local prefixIdx = rng:int(1, #b.stationPrefix)
    local prefix, name = b.stationPrefix[prefixIdx], b.stationNames[nameIdx]
    if b.stationOrderSwaps and swap then return name .. " " .. prefix end
    return prefix .. " " .. name
end

--- Settlement names.
--
-- Two shapes: a qualifier plus a body ("New Haven" / "Новая Посадка", with the
-- adjective agreeing), or a body plus a tail ("Ridge Station" / "Гребень
-- Станция" -> in Russian the tail leads: "Станция Гребень").
function names.settlement(seed)
    local rng = Rng.new(seed, "settlement")
    local b = bank()
    local shape = rng:bool(0.4)
    local rootIdx = rng:int(1, #b.settlementRoot)
    local bodyIdx = rng:int(1, #b.settlementBody)
    local tailIdx = rng:int(1, #b.settlementTail)

    local body = b.settlementBody[bodyIdx]
    if type(body) ~= "table" then
        -- English: plain strings, no agreement
        if shape then return b.settlementRoot[rootIdx] .. " " .. body end
        return body .. " " .. b.settlementTail[tailIdx]
    end

    local word, gender = body[1], body[2]
    if shape then
        local root = b.settlementRoot[rootIdx]
        if root.noun then return root[1] .. " " .. word end
        local form = (gender == "f" and root[2]) or (gender == "n" and root[3]) or root[1]
        return form .. " " .. word
    end
    -- appositive: the generic term leads and the proper name follows unchanged
    return b.settlementTail[tailIdx] .. " " .. word
end

function names.person(seed)
    local rng = Rng.new(seed, "person")
    local b = bank()
    local f, l = rng:int(1, #b.first), rng:int(1, #b.last)
    return b.first[f] .. " " .. b.last[l]
end

function names.company(seed)
    local rng = Rng.new(seed, "company")
    local b = bank()
    local a, bb = rng:int(1, #b.corpA), rng:int(1, #b.corpB)
    return (b.corpForm:gsub("{a}", b.corpA[a]):gsub("{b}", b.corpB[bb]))
end

--- Ship names: an adjective and a noun, agreeing in gender where the language
--- requires it.
function names.ship(seed)
    local rng = Rng.new(seed, "ship")
    local b = bank()
    local a, n = rng:int(1, #b.shipAdjective), rng:int(1, #b.shipNoun)
    local adj, noun = b.shipAdjective[a], b.shipNoun[n]
    if type(noun) ~= "table" then return adj .. " " .. noun end
    local word, gender = noun[1], noun[2]
    local form = (gender == "f" and adj[2]) or (gender == "n" and adj[3]) or adj[1]
    return form .. " " .. word
end

return names

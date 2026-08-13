-- Rank and progression.
--
-- The game had exactly two economic states: 1,400 credits at the start, and
-- the ~135,000 needed to plant a colony (a 74,000 credit kit, the 55,000
-- founding cost and sixteen tonnes of cargo). Nothing sat between them -- no
-- milestone, no title, nothing that told a player halfway there that they were
-- halfway there. A hundredfold climb with no marks on the wall reads as a flat
-- grind rather than progress.
--
-- Rank is derived, never stored: it is a function of the player's record, so
-- it cannot drift out of step with what they have actually done, and an old
-- save gets the right rank the moment it loads.

local util = require("src.lib.util")

local progression = {}

--- Ranks, in order. `require` is measured against the player's record.
--
-- Each is reachable by more than one route on purpose: a trader climbs on
-- turnover, a fighter on kills, an explorer on systems visited. The score is
-- the best of the three rather than their sum, so no one is forced through a
-- style of play they dislike.
progression.RANKS = {
    { id = "harmless",  name = "Harmless",    credits = 0,       score = 0 },
    { id = "novice",    name = "Novice",      credits = 6000,    score = 4 },
    { id = "trader",    name = "Trader",      credits = 22000,   score = 12 },
    { id = "dealer",    name = "Dealer",      credits = 60000,   score = 30 },
    { id = "merchant",  name = "Merchant",    credits = 140000,  score = 60 },
    { id = "broker",    name = "Broker",      credits = 320000,  score = 110 },
    { id = "magnate",   name = "Magnate",     credits = 750000,  score = 200 },
    { id = "tycoon",    name = "Tycoon",      credits = 1800000, score = 340 },
    { id = "elite",     name = "Elite",       credits = 4000000, score = 560 },
}

--- What each rank opens up, as text the UI can show.
progression.UNLOCKS = {
    novice   = "Better paid contracts appear on the boards.",
    trader   = "Shipyards will trade in your hull.",
    dealer   = "High tech outfitting becomes available.",
    merchant = "Colony equipment is within reach.",
    broker   = "Faction agents offer standing work.",
    magnate  = "Your colonies attract migrants faster.",
    tycoon   = "Rare hulls are offered for sale.",
    elite    = "Nothing left to prove.",
}

--- A single number summarising what the player has done.
--
-- Deliberately not credits: a pilot can be broke and still experienced, and
-- a rank that fell when you spent money would be nonsense.
function progression.score(player)
    local r = player.record or {}
    local trade = (r.trades or 0) * 0.6 + (r.profit or 0) / 9000
    local combat = (r.kills or 0) * 2.2
    local explore = (r.jumps or 0) * 0.35 + (r.landings or 0) * 0.5
        + (r.scanned or 0) * 0.6 + util.count(player.knownSystems or {}) * 0.8
    local contracts = (r.missionsDone or 0) * 2.0
    -- best single discipline, plus a little credit for the others
    local best = math.max(trade, combat, explore, contracts)
    local rest = (trade + combat + explore + contracts - best) * 0.25
    return best + rest + (r.coloniesFounded or 0) * 25
end

--- The player's current rank: the highest whose thresholds they have both met.
function progression.rank(player)
    local score = progression.score(player)
    local wealth = math.max(player.credits or 0, (player.record and player.record.profit) or 0)
    local best = progression.RANKS[1]
    for _, rank in ipairs(progression.RANKS) do
        if score >= rank.score and wealth >= rank.credits then best = rank end
    end
    return best
end

--- The next rank up, or nil at the top.
function progression.next(player)
    local current = progression.rank(player)
    for i, rank in ipairs(progression.RANKS) do
        if rank.id == current.id then return progression.RANKS[i + 1] end
    end
    return nil
end

--- Fractional progress towards the next rank, 0..1.
function progression.progress(player)
    local nextRank = progression.next(player)
    if not nextRank then return 1 end
    local current = progression.rank(player)
    local score = progression.score(player)
    local wealth = math.max(player.credits or 0, (player.record and player.record.profit) or 0)

    local function frac(have, from, to)
        if to <= from then return 1 end
        return util.clamp((have - from) / (to - from), 0, 1)
    end
    -- both gates must be passed, so progress is the lesser of the two
    return math.min(
        frac(score, current.score, nextRank.score),
        frac(wealth, current.credits, nextRank.credits))
end

--- True when the player has reached at least `id`.
function progression.hasReached(player, id)
    local current = progression.rank(player)
    local wanted, have
    for i, rank in ipairs(progression.RANKS) do
        if rank.id == id then wanted = i end
        if rank.id == current.id then have = i end
    end
    return wanted ~= nil and have ~= nil and have >= wanted
end

--- What is still missing for the next rank, as a short line for the UI.
function progression.requirement(player)
    local nextRank = progression.next(player)
    if not nextRank then return nil end
    local score = progression.score(player)
    local wealth = math.max(player.credits or 0, (player.record and player.record.profit) or 0)
    if wealth < nextRank.credits then
        return "credits", math.floor(nextRank.credits - wealth)
    end
    if score < nextRank.score then
        return "experience", math.floor(nextRank.score - score)
    end
    return nil
end

--- Checks for a promotion, returning the new rank once when it changes.
--
-- The player stores only the last rank *seen*, so the announcement fires once
-- while the rank itself stays derived.
function progression.check(player)
    local rank = progression.rank(player)
    if player.rankSeen ~= rank.id then
        local first = player.rankSeen ~= nil
        player.rankSeen = rank.id
        if first then return rank end
    end
    return nil
end

return progression

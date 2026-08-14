-- The context action.
--
-- The game had a key for docking, a key for disembarking, a key for
-- interacting and a key for entering a building, and which one applied was
-- something the player had to work out. Every one of them is a different
-- answer to the same question -- "what is the obvious thing to do right here?"
-- -- so there is now one key, and this module answers the question.
--
-- It is deliberately pure: it takes a plain description of the situation and
-- returns a plain description of the action, with no reference to the flight
-- state, the renderer or LOVE. That makes the priority order testable, and it
-- means the HUD prompt and the key handler cannot disagree about what the key
-- is going to do -- they both read this.

local i18n = require("src.i18n")

local context = {}

local L = i18n.format

--- A one-word name for each kind, for the corner hint list.
local VERB = {
    dock = "Dock", enterSettlement = "Enter", enterBuilding = "Enter",
    disembark = "Disembark", board = "Board", scoop = "Scoop", talk = "Talk",
}

function context.verb(kind) return kind and VERB[kind] or nil end

--- Resolves the situation into a single action.
--
-- `s` describes what is within reach:
--   station        a station whose docking envelope we are inside
--   stationBlocked truthy when we are inside it but not allowed in
--   blockedReason  already-localised text explaining why
--   landedPlace    the settlement we are parked at
--   landed         true when the ship is on the ground anywhere
--   canister       a cargo canister in scoop range
--   canisterName   its contents, already localised
--   walking        true when the player is on foot
--   nearShip       true when the player is on foot and next to their ship
--   building       a building whose door is in reach
--   npc            a person in reach
--   key            the key name to print in the prompt
--
-- Returns `{ kind, text, blocked }` or nil. `kind` is what the caller
-- dispatches on; `text` is what the HUD prints.
function context.resolve(s)
    s = s or {}
    local key = s.key or "E"

    -- On foot the choices are all within a few metres, so they come first and
    -- in order of how close they are to the player's hands.
    if s.walking then
        if s.building then
            return { kind = "enterBuilding", target = s.building,
                     text = L("{key} to enter {name}", { key = key, name = s.building.name }) }
        end
        if s.npc then
            return { kind = "talk", target = s.npc,
                     text = L("{key} to talk to {name}", { key = key, name = s.npc.name }) }
        end
        if s.nearShip then
            return { kind = "board", text = L("{key} to board ship", { key = key }) }
        end
        return nil
    end

    -- In the ship, docking outranks everything: if the envelope has been
    -- entered, that is unambiguously what the player came here to do.
    if s.station then
        if s.stationBlocked then
            return { kind = "dock", target = s.station, blocked = true,
                     text = s.blockedReason or L("Cannot dock") }
        end
        return { kind = "dock", target = s.station,
                 text = L("{key} to dock at {name}", { key = key, name = s.station.name }) }
    end

    if s.landedPlace then
        return { kind = "enterSettlement", target = s.landedPlace,
                 text = L("{key} to enter {name}", { key = key, name = s.landedPlace.name }) }
    end

    -- Scooping is only offered in flight, and only when there is nothing more
    -- important on offer -- you cannot be inside a docking envelope and next
    -- to loose cargo at the same time in any situation that matters.
    if s.canister then
        return { kind = "scoop", target = s.canister,
                 text = L("{key} to scoop {cargo}", { key = key, cargo = s.canisterName or "" }) }
    end

    if s.landed then
        return { kind = "disembark", text = L("{key} to disembark", { key = key }) }
    end

    return nil
end

return context

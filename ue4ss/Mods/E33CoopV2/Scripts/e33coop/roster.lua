-- Canonical playable character roster and shared domain constants.

local Roster = {
    PLAYER_1 = 0,
    PLAYER_2 = 1,
    PLAYER_3 = 2,
    RANDOM_P1_P2 = 3,

    MAX_PARTY_SLOTS = 3,

    -- EBattleEndResult enum values from AC_jRPG_BattleManager
    BATTLE_END_NONE = 0,
    BATTLE_END_WON = 1,
    BATTLE_END_LOST = 2,
    BATTLE_END_FLED = 3,

    -- ECommonInputType enum values from CommonInput
    INPUT_TYPE_MOUSE_AND_KEYBOARD = 0,
    INPUT_TYPE_GAMEPAD = 1,

    RANDOM_LABEL = "Random (P1/P2)",
    PLAYER_LABELS = {
        [0] = "Player 1",
        [1] = "Player 2",
        [2] = "Player 3",
        [3] = "Random (P1/P2)",
    },

    -- CharacterHardcodedName -> Display name (Frey is Gustave internally)
    CHARACTERS = {
        { id = "Frey", display = "Gustave" },
        { id = "Lune", display = "Lune" },
        { id = "Maelle", display = "Maelle" },
        { id = "Sciel", display = "Sciel" },
        { id = "Monoco", display = "Monoco" },
        { id = "Verso", display = "Verso" },
    },
}

local DISPLAY_BY_ID = {}
for _, entry in ipairs(Roster.CHARACTERS) do
    DISPLAY_BY_ID[entry.id] = entry.display
end

function Roster.isKnownCharacter(charId)
    return type(charId) == "string" and DISPLAY_BY_ID[charId] ~= nil
end

function Roster.displayName(charId)
    if type(charId) ~= "string" or charId == "" then
        return nil
    end
    return DISPLAY_BY_ID[charId] or charId
end

function Roster.isValidAssignment(val)
    return type(val) == "number"
        and math.floor(val) == val
        and val >= Roster.PLAYER_1
        and val <= Roster.RANDOM_P1_P2
end

return Roster

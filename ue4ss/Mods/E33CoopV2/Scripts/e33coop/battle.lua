-- Character-first battle assignment projection, enemy-turn defense safety, and turn toasts.
--
-- Core idea:
--   Instead of splicing MapBattleSpotToUser / MapUserToBattleSpots bytecode, we project the
--   resolved per-character player index (0, 1, or 2) of whoever is ACTUALLY standing on each
--   battle spot directly into ModActor.CoopConfig.Character{1,2,3}Assignment in memory.
--   Because the unpatched mod's spot-to-slot table is a bijection across spots 0..2 whenever
--   MoreThan1 is true (and trivial when solo/1-char), ALL defense hooks (TryStartDodge/Parry/
--   Jump/GradientParry/JumpCounter), CoopController defense routing, defense windows, and
--   OnTurnStart automatically agree — for normal parties, OverrideParty, AND Reserve Teams.

local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local Battle = {}

-- Pure function (unit-testable without UE):
-- Computes the 3 slot values { [0]=c1, [1]=c2, [2]=c3 } that unpatched CoopConfig must hold
-- so MapBattleSpotToUser / MapUserToBattleSpots return the exact character-first player index.
function Battle.computeProjectedSlots(config, partyNames, spotChars, soloInfo, activeUserCount, moreThanOne)
    local slots = {
        [0] = config.resolveEffectivePlayer(partyNames[1], 0, activeUserCount),
        [1] = config.resolveEffectivePlayer(partyNames[2], 1, activeUserCount),
        [2] = config.resolveEffectivePlayer(partyNames[3], 2, activeUserCount),
    }

    if soloInfo and soloInfo.isSolo then
        local soloSlot = math.max(0, math.min(Roster.MAX_PARTY_SLOTS - 1, soloInfo.partyIndex or 0))
        slots[soloSlot] = config.resolveEffectivePlayer(soloInfo.charId, soloSlot, activeUserCount)
        return slots
    end

    if type(spotChars) == "table" and next(spotChars) ~= nil then
        for spot, charId in pairs(spotChars) do
            local targetSlot = nil
            if moreThanOne then
                -- Inverse of unpatched MapBattleSpotToUser when MoreThan1 == true:
                --   spot 0 -> Character2Assignment (slot 1)
                --   spot 1 -> Character3Assignment (slot 2)
                --   spot 2 -> Character1Assignment (slot 0)
                if spot == 0 then
                    targetSlot = 1
                elseif spot == 1 then
                    targetSlot = 2
                elseif spot == 2 then
                    targetSlot = 0
                end
            else
                -- When MoreThan1 == false, unpatched MapBattleSpotToUser maps spot 0 -> slot 0
                if spot == 0 then
                    targetSlot = 0
                elseif spot == 1 then
                    targetSlot = 2
                elseif spot == 2 then
                    targetSlot = 0
                end
            end

            if targetSlot ~= nil then
                slots[targetSlot] = config.resolveEffectivePlayer(charId, targetSlot, activeUserCount)
            end
        end
    end

    return slots
end

function Battle.new(ue, config, control)
    local self = {}

    -- Syncs ModActor.CoopConfig's in-memory Character{1,2,3}Assignment to resolved 0..2 values.
    function self.syncConfig(reason)
        local coopConfig = ue.getCoopConfig()
        if not coopConfig then
            return false
        end

        local partyNames = ue.getCurrentPartyNames()
        local activeUsers = ue.getAllActiveUsers()
        local userCount = #activeUsers
        local moreThanOne = ue.moreThanOneCharInParty(partyNames)

        local spotChars = nil
        local soloInfo = nil
        if control.isInBattle() or ue.isInBattle() then
            local bm = ue.getBattleManager()
            if bm then
                local isSolo, soloIdx, soloChar = ue.getOverrideSoloBattleInfo(bm, partyNames)
                if isSolo then
                    soloInfo = { isSolo = true, partyIndex = soloIdx, charId = soloChar }
                else
                    spotChars = ue.getSpawnedBattleSpotCharacters(bm)
                end
            end
        end

        local slots = Battle.computeProjectedSlots(config, partyNames, spotChars, soloInfo, userCount, moreThanOne)
        local ok, err = pcall(function()
            coopConfig.Character1Assignment = slots[0]
            coopConfig.Character2Assignment = slots[1]
            coopConfig.Character3Assignment = slots[2]
        end)
        if not ok then
            Log.warn("syncConfig(%s) failed: %s", tostring(reason), tostring(err))
            return false
        end

        Log.debug("Synced CoopConfig (%s): slots=[%d, %d, %d] users=%d",
            tostring(reason), slots[0], slots[1], slots[2], userCount)
        return true
    end

    -- Called when ModActor finishes loading CoopConfig asynchronously from the "Coop" SaveGame slot.
    function self.onCoopConfigLoaded()
        local coopConfig = ue.getCoopConfig()
        if not coopConfig then
            return
        end

        local slotValues = {}
        local v1CharValues = {}
        pcall(function()
            slotValues[1] = coopConfig.Character1Assignment
            slotValues[2] = coopConfig.Character2Assignment
            slotValues[3] = coopConfig.Character3Assignment
            -- Read any v1 per-character properties if upgrading from a patched v1 SaveGame
            for _, entry in ipairs(Roster.CHARACTERS) do
                local okProp, val = pcall(function() return coopConfig[entry.id .. "Assignment"] end)
                if okProp and type(val) == "number" then
                    v1CharValues[entry.id] = val
                end
            end
        end)

        local hadRawRandom = config.importFromLegacySave(slotValues, v1CharValues)
        self.syncConfig("coop_config_loaded")

        -- If an old v1 SaveGame stored raw value 3 ("Random"), sanitize the SaveGame to 0..2
        -- so unpatched SetupSettingsMenu::CreateIntegerSelector never asserts on SetSelectedValue(3).
        if hadRawRandom then
            Log.info("Sanitizing legacy 'Coop' SaveGame slot (removing raw value 3)")
            ue.saveCoopConfigSlot(coopConfig)
        end
    end

    -- Called when AC_jRPG_BattleManager spawns a player character (initial spawn, OverrideParty, or Reserve Team).
    function self.onPlayerCharacterSpawned()
        self.syncConfig("character_spawned")
    end

    -- Called right before a character's OnTurnStart via AC_jRPG_BattleManager::StartCharacterTurn.
    function self.onStartCharacterTurn()
        self.syncConfig("start_character_turn")
    end

    -- Called POST after BP_jRPG_Character_Battle_Base::OnTurnStart.
    function self.onTurnStart(character)
        if not ue.isValid(character) then
            return
        end

        local okCtrl, isPlayer = pcall(function() return character.IsPlayerControlledCharacter end)
        if not okCtrl then
            return
        end

        self.syncConfig("turn_start")

        if not isPlayer then
            control.onEnemyTurnStart()
            return
        end

        local charId = ue.getCharacterNameFromBattleActor(character)
        local okSpot, spot = pcall(function() return character.BattleSpotIndex end)
        local fallbackSlot = (okSpot and type(spot) == "number") and spot or 0

        local activeUsers = ue.getAllActiveUsers()
        local playerIndex = config.resolveEffectivePlayer(charId, fallbackSlot, #activeUsers)
        local targetEntry = activeUsers[playerIndex + 1] or activeUsers[1]
        local _, primaryId = ue.getPrimaryPlatformUser()
        local targetUserId = targetEntry and targetEntry.internalId or primaryId

        control.onPlayerTurnStart(targetUserId, playerIndex, charId)

        if config.shouldShowTurnToast() then
            local display = Roster.displayName(charId)
            local toastText = display
                and string.format("Player %d's Turn (%s)", playerIndex + 1, display)
                or string.format("Player %d's Turn", playerIndex + 1)
            ue.spawnTurnToast(toastText)
        end
    end

    -- Called POST after BP_jRPG_Character_Battle_Base::OnTurnEnded.
    function self.onTurnEnded(character)
        if not ue.isValid(character) then
            return
        end
        local okCtrl, isPlayer = pcall(function() return character.IsPlayerControlledCharacter end)
        if okCtrl then
            control.onTurnEnded(isPlayer == true)
        end
    end

    return self
end

return Battle

-- Single source of truth for per-character assignments, persistence,
-- v1 SaveGame migration, and per-character battle random rolls.

local Json = require("e33coop.json")
local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local Config = {}

local function defaultData()
    return {
        version = 2,
        debug = false,
        blockStartInBattle = true,
        showTurnToast = true,
        hasPerCharacterAssignments = false,
        -- Per-character saved setting: 0 = P1, 1 = P2, 2 = P3, 3 = Random (P1/P2)
        assignments = {},
        -- Legacy slot fallback (1-indexed in Lua, mirrors Character1/2/3Assignment before any per-char choice)
        legacySlots = { 0, 1, 2 },
    }
end

function Config.new(filePath, rngFn)
    local self = {
        filePath = filePath,
        rngFn = rngFn or function() return math.random(0, 1) end,
        data = defaultData(),
        -- Transient per-battle random roll: { [charId or "slot_N"] = 0 | 1 }
        battleRoll = {},
        keepRollOnNextBattle = false,
        loadedFromDisk = false,
    }

    local function persist()
        if not self.filePath then
            return true
        end
        local ok, encoded = pcall(Json.encode, self.data, 2)
        if not ok then
            Log.error("Failed to encode config: %s", tostring(encoded))
            return false
        end
        local f, err = io.open(self.filePath, "w")
        if not f then
            Log.error("Failed to write config '%s': %s", tostring(self.filePath), tostring(err))
            return false
        end
        f:write(encoded .. "\n")
        f:close()
        return true
    end

    function self.load()
        if not self.filePath then
            return false
        end
        local f = io.open(self.filePath, "r")
        if not f then
            return false
        end
        local raw = f:read("*a")
        f:close()
        local decoded, err = Json.decode(raw)
        if type(decoded) ~= "table" then
            Log.warn("Invalid config.json (%s), using defaults", tostring(err))
            return false
        end

        local merged = defaultData()
        if type(decoded.debug) == "boolean" then merged.debug = decoded.debug end
        if type(decoded.blockStartInBattle) == "boolean" then merged.blockStartInBattle = decoded.blockStartInBattle end
        if type(decoded.showTurnToast) == "boolean" then merged.showTurnToast = decoded.showTurnToast end
        if type(decoded.hasPerCharacterAssignments) == "boolean" then
            merged.hasPerCharacterAssignments = decoded.hasPerCharacterAssignments
        end
        if type(decoded.assignments) == "table" then
            for charId, val in pairs(decoded.assignments) do
                if Roster.isKnownCharacter(charId) and Roster.isValidAssignment(val) then
                    merged.assignments[charId] = val
                end
            end
        end
        if type(decoded.legacySlots) == "table" then
            for i = 1, Roster.MAX_PARTY_SLOTS do
                local v = decoded.legacySlots[i]
                if Roster.isValidAssignment(v) then
                    merged.legacySlots[i] = v
                end
            end
        end

        self.data = merged
        self.loadedFromDisk = true
        Log.setDebug(self.data.debug)
        Log.info("Loaded config from %s (perCharacter=%s, debug=%s)",
            tostring(self.filePath), tostring(self.data.hasPerCharacterAssignments), tostring(self.data.debug))
        return true
    end

    function self.save()
        return persist()
    end

    function self.isDebug()
        return self.data.debug
    end

    function self.shouldBlockStartInBattle()
        return self.data.blockStartInBattle
    end

    function self.shouldShowTurnToast()
        return self.data.showTurnToast
    end

    -- Migrates settings from the Unreal "Coop" SaveGame when no config.json exists yet
    -- (vanilla slot assignments, plus v1 <Char>Assignment fields, which only exist while the
    -- v1-patched CoopConfig class is still installed).
    -- Returns true if any value on the Unreal CoopConfig had raw value 3 (Random) and should be sanitized.
    function self.importFromLegacySave(slotValues, v1CharValues)
        local hadRawRandom = false
        if type(slotValues) == "table" then
            for i = 1, Roster.MAX_PARTY_SLOTS do
                local v = slotValues[i]
                if v == Roster.RANDOM_P1_P2 then
                    hadRawRandom = true
                end
                if not self.loadedFromDisk and Roster.isValidAssignment(v) then
                    self.data.legacySlots[i] = v
                end
            end
        end

        if not self.loadedFromDisk and type(v1CharValues) == "table" then
            local importedAny = false
            for charId, stored in pairs(v1CharValues) do
                -- v1 stored assignment + 1 (0 = never assigned)
                if Roster.isKnownCharacter(charId) and type(stored) == "number" and stored > 0 then
                    local val = stored - 1
                    if Roster.isValidAssignment(val) then
                        self.data.assignments[charId] = val
                        importedAny = true
                    end
                end
            end
            if importedAny then
                self.data.hasPerCharacterAssignments = true
                Log.info("Migrated v1 per-character assignments into config.json")
            end
        end

        if not self.loadedFromDisk then
            self.loadedFromDisk = true
            persist()
        end
        return hadRawRandom
    end

    -- Returns the configured setting (0, 1, 2, or 3 for Random).
    -- Matches the documented rule:
    --   - Once any character has been assigned, known playable characters that were never
    --     assigned default to Player 1 (0) instead of inheriting whatever was in that slot.
    --   - Before any choice has been made (or for non-playable guests like Sophie), the slot setting applies.
    function self.getConfiguredAssignment(charId, fallbackSlotZeroBased)
        local slot = math.max(0, math.min(Roster.MAX_PARTY_SLOTS - 1, fallbackSlotZeroBased or 0))
        if self.data.hasPerCharacterAssignments and Roster.isKnownCharacter(charId) then
            local saved = self.data.assignments[charId]
            if Roster.isValidAssignment(saved) then
                return saved
            end
            return Roster.PLAYER_1
        end
        local legacy = self.data.legacySlots[slot + 1]
        if Roster.isValidAssignment(legacy) then
            return legacy
        end
        return Roster.PLAYER_1
    end

    -- Saves a player choice made in Settings for the character currently in slotZeroBased.
    -- Also snapshots the other party members' current settings if this is the first per-character edit,
    -- so existing slot assignments aren't unexpectedly wiped when changing one character.
    function self.setSlotAssignment(slotZeroBased, value, partyNames)
        if not Roster.isValidAssignment(value) then
            Log.warn("Ignoring invalid assignment value: %s", tostring(value))
            return false
        end
        local slot = math.max(0, math.min(Roster.MAX_PARTY_SLOTS - 1, slotZeroBased or 0))
        self.data.legacySlots[slot + 1] = value

        local isFirstPerChar = not self.data.hasPerCharacterAssignments
        if type(partyNames) == "table" then
            if isFirstPerChar then
                -- Snapshot current party members' existing slot assignments before enabling per-character mode
                for idx = 0, Roster.MAX_PARTY_SLOTS - 1 do
                    local member = partyNames[idx + 1]
                    if Roster.isKnownCharacter(member) and self.data.assignments[member] == nil then
                        self.data.assignments[member] = self.data.legacySlots[idx + 1] or Roster.PLAYER_1
                    end
                end
            end
            local targetChar = partyNames[slot + 1]
            if Roster.isKnownCharacter(targetChar) then
                self.data.assignments[targetChar] = value
                self.data.hasPerCharacterAssignments = true
                Log.info("Saved assignment: %s (%s) -> %s",
                    targetChar, Roster.displayName(targetChar), Roster.PLAYER_LABELS[value] or tostring(value))
            end
        end

        return persist()
    end

    -- Rolls an independent 0/1 (P1/P2) assignment for every playable character (plus fallback slots).
    -- If the previous battle was lost and retried, keeps the existing roll once.
    function self.rollForBattle()
        if self.keepRollOnNextBattle and next(self.battleRoll) ~= nil then
            self.keepRollOnNextBattle = false
            Log.info("Keeping previous random roll for battle retry")
            return self.battleRoll
        end
        self.keepRollOnNextBattle = false
        local roll = {}
        for _, entry in ipairs(Roster.CHARACTERS) do
            roll[entry.id] = self.rngFn() == 1 and Roster.PLAYER_2 or Roster.PLAYER_1
        end
        for slot = 0, Roster.MAX_PARTY_SLOTS - 1 do
            roll["slot_" .. slot] = self.rngFn() == 1 and Roster.PLAYER_2 or Roster.PLAYER_1
        end
        self.battleRoll = roll
        Log.debug("Rolled battle random assignments: Frey=%d Lune=%d Maelle=%d Sciel=%d Monoco=%d Verso=%d",
            roll.Frey, roll.Lune, roll.Maelle, roll.Sciel, roll.Monoco, roll.Verso)
        return roll
    end

    function self.markRetryKeepRoll()
        self.keepRollOnNextBattle = true
        Log.debug("Marked random roll to be kept on next battle (defeat/retry)")
    end

    -- Resolves the concrete player index (0, 1, or 2) to use in battle.
    -- Never returns 3 (Random); clamps to 0 if fewer controllers are active than the assigned player.
    function self.resolveEffectivePlayer(charId, fallbackSlotZeroBased, activeUserCount)
        local configured = self.getConfiguredAssignment(charId, fallbackSlotZeroBased)
        local player = configured
        if configured == Roster.RANDOM_P1_P2 then
            local key = Roster.isKnownCharacter(charId) and charId or ("slot_" .. tostring(fallbackSlotZeroBased or 0))
            if self.battleRoll[key] == nil then
                self.battleRoll[key] = self.rngFn() == 1 and Roster.PLAYER_2 or Roster.PLAYER_1
            end
            player = self.battleRoll[key]
        end
        if type(activeUserCount) == "number" and activeUserCount > 0 and player >= activeUserCount then
            return Roster.PLAYER_1
        end
        if player < 0 or player > Roster.PLAYER_3 then
            return Roster.PLAYER_1
        end
        return player
    end

    -- Badge text for PlayerIndicator on the team screen ("P1", "P2", "P3", or "P?").
    function self.getIndicatorLabel(charId, partySlotZeroBased)
        local configured = self.getConfiguredAssignment(charId, partySlotZeroBased)
        if configured == Roster.RANDOM_P1_P2 then
            return "P?"
        end
        return "P" .. tostring(configured + 1)
    end

    return self
end

return Config

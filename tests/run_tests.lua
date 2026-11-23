-- Automated unit test suite for E33CoopV2 (Lua 5.4).
-- Runs completely offline against mocked UE4SS objects to verify every module and edge case.

local function getTestDir()
    local src = debug.getinfo(1, "S").source
    if type(src) == "string" and src:sub(1, 1) == "@" then
        local path = src:sub(2):gsub("\\", "/")
        return path:match("^(.*)/[^/]+$") or "."
    end
    return "."
end

local testDir = getTestDir()
local repoRoot = testDir:match("^(.*)/tests$") or "."
package.path = repoRoot .. "/ue4ss/Mods/E33CoopV2/Scripts/?.lua;" .. package.path

-- Minimal FText mock for offline testing
_G.FText = function(str)
    return {
        _text = tostring(str),
        ToString = function(self) return self._text end,
    }
end

local Log = require("e33coop.log")
Log.setDebug(false)

local Json = require("e33coop.json")
local Roster = require("e33coop.roster")
local Config = require("e33coop.config")
local Battle = require("e33coop.battle")
local Control = require("e33coop.control")
local Gamepad = require("e33coop.gamepad")
local UI = require("e33coop.ui")

local passed = 0
local failed = 0

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected <%s>, got <%s>", msg or "assertEq", tostring(expected), tostring(actual)), 2)
    end
end

local function assertTrue(cond, msg)
    if not cond then
        error(msg or "expected truthy value", 2)
    end
end

local function runTest(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print(string.format("  [PASS] %s", name))
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s: %s", name, tostring(err)))
    end
end

local function makeParam(initial)
    local val = initial
    return {
        get = function() return val end,
        set = function(_, v) val = v end,
    }
end

-- Mock UE layer for offline tests
local function makeMockUE()
    local state = {
        pc0User = 0,
        primaryId = 0,
        activeUsers = {
            { raw = { InternalId = 0 }, internalId = 0 },
            { raw = { InternalId = 1 }, internalId = 1 },
            { raw = { InternalId = 2 }, internalId = 2 },
        },
        partyNames = { "Frey", "Lune", "Maelle" },
        inBattle = false,
        bm = { BattleEndState = 0 },
        coopConfig = { Character1Assignment = 0, Character2Assignment = 1, Character3Assignment = 2 },
        savedSlots = 0,
        toasts = {},
        setUserLog = {},
        inputType = Roster.INPUT_TYPE_GAMEPAD,
        setInputTypeCalls = {},
    }

    local sub = {
        GetAddress = function() return 0x1234 end,
        GetCurrentInputType = function() return state.inputType end,
        SetCurrentInputType = function(_, t)
            state.inputType = t
            state.setInputTypeCalls[#state.setInputTypeCalls + 1] = t
        end,
    }

    local pc0 = { IsValid = function() return true end, bShowMouseCursor = false, CurrentMouseCursor = 1 }
    local pc1 = { IsValid = function() return true end, bShowMouseCursor = true, CurrentMouseCursor = 1 }
    local pc2 = { IsValid = function() return true end, bShowMouseCursor = true, CurrentMouseCursor = 1 }

    local sub1 = {
        inputType = Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD,
        GetAddress = function() return 0x2234 end,
        GetCurrentInputType = function(self) return self.inputType end,
        SetCurrentInputType = function(self, t) self.inputType = t end,
    }
    local sub2 = {
        inputType = Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD,
        GetAddress = function() return 0x3234 end,
        GetCurrentInputType = function(self) return self.inputType end,
        SetCurrentInputType = function(self, t) self.inputType = t end,
    }

    local ue = {
        state = state,
        sub = sub,
        sub1 = sub1,
        sub2 = sub2,
        pc0 = pc0,
        pc1 = pc1,
        pc2 = pc2,
        isValid = function(o) return o ~= nil end,
        getPlayerController = function(idx)
            if idx == 0 then return pc0 end
            if idx == 1 then return pc1 end
            if idx == 2 then return pc2 end
            return nil
        end,
        getPlatformUserId = function(pc) return pc == pc0 and state.pc0User or nil end,
        getPrimaryPlatformUser = function() return state.activeUsers[1].raw, state.primaryId end,
        getAllActiveUsers = function() return state.activeUsers end,
        setController0User = function(targetId, reason)
            state.setUserLog[#state.setUserLog + 1] = { from = state.pc0User, to = targetId, reason = reason }
            state.pc0User = targetId
            return true
        end,
        getBattleManager = function() return state.bm end,
        getCoopConfig = function() return state.coopConfig end,
        saveCoopConfigSlot = function() state.savedSlots = state.savedSlots + 1; return true end,
        isInBattle = function() return state.inBattle end,
        getCurrentPartyNames = function() return state.partyNames end,
        moreThanOneCharInParty = function(names) return #names > 1 and names[2] ~= "Sophie" end,
        findPartyIndex = function(names, id)
            for i = 1, #names do
                if names[i] == id then return i - 1 end
            end
            return nil
        end,
        getOverrideSoloBattleInfo = function() return false, -1, nil end,
        getSpawnedBattleSpotCharacters = function() return {} end,
        getCharacterNameFromBattleActor = function(actor) return actor.charId end,
        getCommonInputSubsystem = function(pc)
            if pc == pc0 then return sub end
            if pc == pc1 then return sub1 end
            if pc == pc2 then return sub2 end
            return nil
        end,
        isGamepadKeyPressed = function(_, keyName)
            if keyName == "Gamepad_FaceButton_Right" then
                return state.cancelJustPressed == true, state.cancelDown == true
            end
            return state.confirmJustPressed == true, state.confirmDown == true
        end,
        getActiveDialogueWaitingForConfirm = function()
            if state.dialogueWaiting then
                return state.dialogueComp, state.confirmWidget, state.dialogueHasChoices == true
            end
            return nil, nil, false
        end,
        advanceDialogueLine = function()
            state.dialogueAdvances = (state.dialogueAdvances or 0) + 1
            return true
        end,
        getActiveFullscreenNotificationConfirm = function(_, trackedNotif)
            if not state.fsnActive then
                return nil, nil, false
            end
            if state.fsnPromptReady then
                return trackedNotif or state.fsnWidget, state.fsnPrompt, true
            end
            return nil, nil, true
        end,
        confirmFullscreenNotification = function()
            state.fsnConfirms = (state.fsnConfirms or 0) + 1
            state.fsnActive = false
            return true
        end,
        getActiveModalPopupButton = function(_, trackedModal, action)
            if not state.modalActive then
                return nil, nil, false
            end
            if action == "confirm" then
                if state.modalIsHold then
                    return nil, nil, true
                end
                return trackedModal or state.modalWidget, state.modalConfirmBtn, true
            elseif action == "cancel" and state.modalHasCancel then
                return trackedModal or state.modalWidget, state.modalCancelBtn, true
            end
            return nil, nil, true
        end,
        triggerModalPopupButton = function(_, _, action)
            if action == "confirm" then
                state.modalConfirms = (state.modalConfirms or 0) + 1
            elseif action == "cancel" then
                state.modalCancels = (state.modalCancels or 0) + 1
            end
            state.modalActive = false
            return true
        end,
        spawnTurnToast = function(text) state.toasts[#state.toasts + 1] = text; return true end,
    }

    return ue
end

print("=== E33CoopV2 Unit Tests ===")

runTest("json: round-trip object, array, escapes, booleans, numbers", function()
    local original = {
        version = 2,
        debug = false,
        note = 'hello "world"\nline2\\slash',
        legacySlots = { 0, 1, 3 },
        assignments = { Frey = 0, Lune = 1, Maelle = 3 },
    }
    local encoded = Json.encode(original, 2)
    local decoded, err = Json.decode(encoded)
    assertEq(err, nil, "decode error")
    assertEq(decoded.version, 2)
    assertEq(decoded.debug, false)
    assertEq(decoded.note, original.note)
    assertEq(decoded.legacySlots[3], 3)
    assertEq(decoded.assignments.Maelle, 3)
end)

runTest("config: per-character persistence, P1 default for unassigned, guest fallback", function()
    local tmpFile = os.tmpname()
    local seq = { 1, 0, 1, 0, 1, 0 }
    local i = 0
    local cfg = Config.new(tmpFile, function()
        i = (i % #seq) + 1
        return seq[i]
    end)

    -- Before any edit, legacy slot fallback applies
    assertEq(cfg.getConfiguredAssignment("Lune", 1), 1, "legacy slot 1")
    assertEq(cfg.getConfiguredAssignment("Maelle", 2), 2, "legacy slot 2")

    -- Assign Maelle (in slot 2) to Random (3)
    cfg.setSlotAssignment(2, Roster.RANDOM_P1_P2, { "Frey", "Lune", "Maelle" })
    assertEq(cfg.getConfiguredAssignment("Maelle", 0), Roster.RANDOM_P1_P2, "Maelle follows character")
    assertEq(cfg.getConfiguredAssignment("Lune", 0), 1, "Lune snapshot preserved")
    assertEq(cfg.getConfiguredAssignment("Sciel", 2), Roster.PLAYER_1, "unassigned playable defaults to P1")
    assertEq(cfg.getConfiguredAssignment("Sophie", 1), 1, "guest falls back to slot")
    assertEq(cfg.getIndicatorLabel("Maelle", 2), "P?", "random badge")
    assertEq(cfg.getIndicatorLabel("Lune", 1), "P2", "P2 badge")

    -- Reload from disk
    local reloaded = Config.new(tmpFile)
    assertTrue(reloaded.load(), "reloaded from disk")
    assertEq(reloaded.getConfiguredAssignment("Maelle", 0), Roster.RANDOM_P1_P2)
    assertEq(reloaded.getConfiguredAssignment("Sciel", 2), Roster.PLAYER_1)
    os.remove(tmpFile)
end)

runTest("config: 6-character random roll and retry KeepRoll", function()
    local rollVal = 1
    local cfg = Config.new(nil, function() return rollVal end)
    cfg.setSlotAssignment(0, Roster.RANDOM_P1_P2, { "Verso" })

    cfg.rollForBattle()
    assertEq(cfg.resolveEffectivePlayer("Verso", 0, 2), 1, "initial roll P2")

    -- Defeat -> retry must keep the previous roll even if RNG now returns 0
    cfg.markRetryKeepRoll()
    rollVal = 0
    cfg.rollForBattle()
    assertEq(cfg.resolveEffectivePlayer("Verso", 0, 2), 1, "retry keeps previous roll")

    -- Next fresh battle rolls anew
    cfg.rollForBattle()
    assertEq(cfg.resolveEffectivePlayer("Verso", 0, 2), 0, "next battle rolls fresh")

    -- Clamp when only 1 active controller
    cfg.setSlotAssignment(0, Roster.PLAYER_3, { "Lune" })
    assertEq(cfg.resolveEffectivePlayer("Lune", 0, 2), Roster.PLAYER_1, "clamp P3 when only 2 users")
end)

runTest("config: v1 SaveGame migration detects raw 3 for sanitization", function()
    local cfg = Config.new(nil)
    local hadRaw3 = cfg.importFromLegacySave({ 0, 3, 1 }, { Maelle = 4, Lune = 2 })
    assertTrue(hadRaw3, "detected raw 3 in legacy SaveGame")
    assertEq(cfg.getConfiguredAssignment("Maelle", 0), Roster.RANDOM_P1_P2, "migrated v1 Maelle=4 -> Random(3)")
    assertEq(cfg.getConfiguredAssignment("Lune", 0), Roster.PLAYER_2, "migrated v1 Lune=2 -> P2(1)")
end)

runTest("battle: character-first projection handles normal, OverrideParty solo, and Reserve Team", function()
    local cfg = Config.new(nil)
    cfg.setSlotAssignment(0, Roster.PLAYER_1, { "Maelle", "Lune", "Sciel" })
    cfg.setSlotAssignment(1, Roster.PLAYER_1, { "Maelle", "Lune", "Sciel" })
    cfg.setSlotAssignment(2, Roster.PLAYER_1, { "Maelle", "Lune", "Sciel" })
    cfg.data.assignments["Verso"] = Roster.PLAYER_2
    cfg.data.assignments["Monoco"] = Roster.PLAYER_3

    -- Case 1: Reserve team of 1 character (Verso=P2) spawned at spot 0 while CurrentParty has 3 chars (moreThanOne=true)
    -- Unpatched MapBattleSpotToUser(spot=0) reads Character2Assignment (slot 1).
    local slotsReserve1 = Battle.computeProjectedSlots(
        cfg,
        { "Maelle", "Lune", "Sciel" },
        { [0] = "Verso" },
        nil,
        3,
        true
    )
    assertEq(slotsReserve1[1], Roster.PLAYER_2, "spot 0 reserve Verso projected to slot 1")

    -- Case 2: Reserve team of 2 characters (Verso=P2 at spot 2, Monoco=P3 at spot 0)
    -- Unpatched: spot 2 -> slot 0, spot 0 -> slot 1
    local slotsReserve2 = Battle.computeProjectedSlots(
        cfg,
        { "Maelle", "Lune", "Sciel" },
        { [2] = "Verso", [0] = "Monoco" },
        nil,
        3,
        true
    )
    assertEq(slotsReserve2[0], Roster.PLAYER_2, "spot 2 reserve Verso -> slot 0")
    assertEq(slotsReserve2[1], Roster.PLAYER_3, "spot 0 reserve Monoco -> slot 1")

    -- Case 3: Solo OverrideParty (Verso=P2, not in CurrentParty -> soloSlot=0)
    local slotsSolo = Battle.computeProjectedSlots(
        cfg,
        { "Maelle", "Lune", "Sciel" },
        nil,
        { isSolo = true, partyIndex = 0, charId = "Verso" },
        2,
        true
    )
    assertEq(slotsSolo[0], Roster.PLAYER_2, "solo override Verso -> slot 0")

    -- Case 4: Prologue (Frey + Sophie -> moreThanOne=false), spot 0 -> slot 0
    cfg.data.assignments["Frey"] = Roster.PLAYER_2
    local slotsPrologue = Battle.computeProjectedSlots(
        cfg,
        { "Frey", "Sophie" },
        { [0] = "Frey" },
        nil,
        2,
        false
    )
    assertEq(slotsPrologue[0], Roster.PLAYER_2, "prologue Frey at spot 0 -> slot 0")
end)

runTest("battle: legacy per-slot settings follow the party slot, not the battle spot", function()
    assertEq(Battle.spotToSlot(0, true), 1, "spot 0 -> slot 1")
    assertEq(Battle.spotToSlot(1, true), 2, "spot 1 -> slot 2")
    assertEq(Battle.spotToSlot(2, true), 0, "spot 2 -> slot 0")
    assertEq(Battle.spotToSlot(0, false), 0, "solo-ish party: spot 0 -> slot 0")

    -- Fresh install: no per-character choice yet, Character1/2/3Assignment = P1/P2/P3
    local cfg = Config.new(nil)
    local party = { "Frey", "Lune", "Maelle" }
    -- Normal 3-member battle: party[1] on spot 2, party[2] on spot 0, party[3] on spot 1
    local slots = Battle.computeProjectedSlots(cfg, party, { [2] = "Frey", [0] = "Lune", [1] = "Maelle" }, nil, 3, true)
    assertEq(slots[0], Roster.PLAYER_1, "Frey keeps Character1Assignment")
    assertEq(slots[1], Roster.PLAYER_2, "Lune keeps Character2Assignment")
    assertEq(slots[2], Roster.PLAYER_3, "Maelle keeps Character3Assignment")
    -- Forced party in another order (e.g. a boss): each character still keeps its own slot setting
    local forced = Battle.computeProjectedSlots(cfg, party, { [2] = "Maelle", [0] = "Frey", [1] = "Lune" }, nil, 3, true)
    assertEq(forced[0], Roster.PLAYER_3, "Maelle on spot 2 keeps P3")
    assertEq(forced[1], Roster.PLAYER_1, "Frey on spot 0 keeps P1")
    assertEq(forced[2], Roster.PLAYER_2, "Lune on spot 1 keeps P2")

    -- The turn handoff must pick the same player as the projection
    local ue = makeMockUE()
    local ctrl = Control.new(ue, cfg, Gamepad.new(ue))
    local battle = Battle.new(ue, cfg, ctrl)
    ctrl.onBattleBegin()
    battle.onTurnStart({ charId = "Lune", IsPlayerControlledCharacter = true, BattleSpotIndex = 0 })
    assertEq(ue.state.pc0User, 1, "Lune (party slot 2) on spot 0 -> P2")
    assertEq(ue.state.toasts[#ue.state.toasts], "Player 2's Turn (Lune)", "toast names P2")
    battle.onTurnStart({ charId = "Frey", IsPlayerControlledCharacter = true, BattleSpotIndex = 2 })
    assertEq(ue.state.pc0User, 0, "Frey (party slot 1) on spot 2 -> P1")
    battle.onTurnStart({ charId = "Maelle", IsPlayerControlledCharacter = true, BattleSpotIndex = 1 })
    assertEq(ue.state.pc0User, 2, "Maelle (party slot 3) on spot 1 -> P3")
end)

runTest("control: full battle lifecycle, enemy turn reset, START block, one-shot victory, map change", function()
    local ue = makeMockUE()
    local cfg = Config.new(nil)
    local gp = Gamepad.new(ue)
    local ctrl = Control.new(ue, cfg, gp)

    -- P2 takes control during exploration
    ue.state.pc0User = 1
    ctrl.onStartTakeover()
    assertEq(ctrl.getExplorationUserId(), 1, "P2 is explorer")

    -- Battle starts -> PC0 goes to P1 for enemy-first defense
    ctrl.onBattleBegin()
    assertEq(ue.state.pc0User, 0, "battle begin gives PC0 to P1")
    assertEq(ctrl.getExplorationUserId(), 1, "explorer stays P2")

    -- Chained battle begin does not overwrite explorer
    ctrl.onBattleBegin()
    assertEq(ctrl.getExplorationUserId(), 1, "chained battle keeps P2")

    -- P2 accidentally presses START during enemy turn -> blocked and restored to P1
    ue.state.pc0User = 1
    ctrl.onStartTakeover()
    assertEq(ue.state.pc0User, 0, "START blocked during active battle")

    -- P2 character's turn -> PC0 goes to P2
    ctrl.onPlayerTurnStart(1, 1, "Lune")
    assertEq(ue.state.pc0User, 1, "Lune turn hands PC0 to P2")

    -- Boss interrupts / enemy turn starts without OnTurnEnded -> resets PC0 to P1
    ctrl.onEnemyTurnStart()
    assertEq(ue.state.pc0User, 0, "enemy turn resets PC0 to P1")

    -- Victory flow -> hands PC0 to explorer P2 ONCE
    ctrl.onBattleEndFlowStarted(Roster.BATTLE_END_WON)
    assertEq(ue.state.pc0User, 1, "victory screen handed to explorer P2")

    -- Late OnTurnEnded while on victory screen -> restores P2
    ue.state.pc0User = 0
    ctrl.onTurnEnded(true)
    assertEq(ue.state.pc0User, 1, "late OnTurnEnded does not steal victory screen")

    -- P1 intentionally presses START on victory screen -> accepted!
    ue.state.pc0User = 0
    ctrl.onStartTakeover()
    assertEq(ctrl.getExplorationUserId(), 0, "START on victory screen accepted")

    -- Battle ends -> restores exploration user (now P1)
    ctrl.onBattleEnd(Roster.BATTLE_END_WON)
    assertEq(ue.state.pc0User, 0, "exploration restored to P1")

    -- P2 takes over, changes map -> preserved across map load
    ue.state.pc0User = 1
    ctrl.onStartTakeover()
    ue.state.pc0User = 0 -- base PrepareToChangeMap hands PC0 to P1 before our post-hook runs
    ctrl.onPrepareToChangeMap()
    ctrl.onMapReady()
    assertEq(ue.state.pc0User, 1, "map load restores exploration user P2")
end)

runTest("gamepad: click-safe CommonUI blocks MouseAndKeyboard drop for P2 without breaking P1 or held clicks", function()
    local ue = makeMockUE()
    local gp = Gamepad.new(ue)

    -- Player 1 (user 0): MouseAndKeyboard is allowed freely
    ue.state.pc0User = 0
    local p1Req = makeParam(Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD)
    gp.onSetCurrentInputTypePre(ue.sub, p1Req)
    assertEq(p1Req:get(), Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD, "P1 mouse/kb untouched")

    -- Player 2 (user 1), no button held: drop to MouseAndKeyboard is blocked -> rewritten to Gamepad
    ue.state.pc0User = 1
    local p2Req = makeParam(Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD)
    gp.onSetCurrentInputTypePre(ue.sub, p2Req)
    assertEq(p2Req:get(), Roster.INPUT_TYPE_GAMEPAD, "P2 idle drop rewritten to Gamepad")

    -- Player 2 (user 1), button HELD: do NOT touch inputType mid-press; restore cleanly on release
    ue.state.inputType = Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD
    ue.state.setInputTypeCalls = {}
    gp.onButtonPressed()
    assertEq(gp.ensureGamepadIfSafe("dialogue"), false, "deferred while button held")
    assertEq(#ue.state.setInputTypeCalls, 0, "no SetCurrentInputType while button held")

    gp.onButtonReleased()
    assertEq(ue.state.inputType, Roster.INPUT_TYPE_GAMEPAD, "restored to Gamepad after button release")
    assertEq(#ue.state.setInputTypeCalls, 1, "restored exactly once after release")
end)

runTest("gamepad: suppresses center-screen cursor blink on Flag/Rest and locks PC1/PC2 to Gamepad", function()
    local ue = makeMockUE()
    local gp = Gamepad.new(ue)

    -- On map load, extra CoopControllers (PC1, PC2) move from MouseAndKeyboard -> Gamepad with cursor hidden
    gp.onMapReady()
    assertEq(ue.sub1.inputType, Roster.INPUT_TYPE_GAMEPAD, "PC1 locked to Gamepad")
    assertEq(ue.sub2.inputType, Roster.INPUT_TYPE_GAMEPAD, "PC2 locked to Gamepad")
    assertEq(ue.pc1.bShowMouseCursor, false, "PC1 cursor hidden")
    assertEq(ue.pc2.bShowMouseCursor, false, "PC2 cursor hidden")

    -- Any attempt to drop PC2 back to MouseAndKeyboard is blocked
    local pc2Drop = makeParam(Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD)
    gp.onSetCurrentInputTypePre(ue.sub2, pc2Drop)
    assertEq(pc2Drop:get(), Roster.INPUT_TYPE_GAMEPAD, "PC2 MouseAndKeyboard drop blocked")

    -- Player 2 owns PC0 and opens the Expedition Flag: the game sets bShowMouseCursor = true, we hide it
    ue.state.pc0User = 1
    ue.pc0.bShowMouseCursor = true
    gp.syncCursorVisibility("OpenSavePointMenu", true)
    assertEq(ue.pc0.bShowMouseCursor, false, "P2 on PC0: cursor hidden on Flag")
    assertEq(ue.pc0.CurrentMouseCursor, 0, "P2 on PC0: CurrentMouseCursor None")

    -- PC0 goes back to Player 1 inside the menu: the game's cursor comes back, shape included
    ue.state.pc0User = 0
    gp.syncCursorVisibility("start_takeover")
    assertEq(ue.pc0.bShowMouseCursor, true, "P1 gets the menu cursor back")
    assertEq(ue.pc0.CurrentMouseCursor, 1, "P1 CurrentMouseCursor restored to Default")

    -- Player 1 rests: the menu is gone but the game leaves bShowMouseCursor = true -> hidden during Rest
    gp.syncCursorVisibility("SavePointRest", false)
    assertEq(ue.pc0.bShowMouseCursor, false, "P1 cursor hidden during Rest")
    assertEq(ue.pc0.CurrentMouseCursor, 1, "P1 cursor shape never left at None")
    gp.syncCursorVisibility("SavePointActivated", true)
    assertEq(ue.pc0.bShowMouseCursor, true, "P1 cursor back when the Flag menu returns")

    -- Player 1's own input type switches are left to CommonUI (a native switch can't be seen from Lua)
    local p1Pad = makeParam(Roster.INPUT_TYPE_GAMEPAD)
    gp.onSetCurrentInputTypePre(ue.sub, p1Pad)
    assertEq(ue.pc0.bShowMouseCursor, true, "P1 cursor untouched by input type switches")
    local p1Mouse = makeParam(Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD)
    gp.onSetCurrentInputTypePre(ue.sub, p1Mouse)
    assertEq(p1Mouse:get(), Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD, "P1 M&K still allowed")
end)

runTest("ui: Settings menu labels/random option, save sanitization, and PlayerIndicator badges", function()
    local ue = makeMockUE()
    local cfg = Config.new(nil)
    local gp = Gamepad.new(ue)
    local ctrl = Control.new(ue, cfg, gp)
    local battle = Battle.new(ue, cfg, ctrl)
    local ui = UI.new(ue, cfg, battle)

    cfg.setSlotAssignment(1, Roster.RANDOM_P1_P2, { "Frey", "Lune", "Maelle" })

    -- Mock Settings OptionEntry + NamedIntegerSelector for slot 2 (Lune)
    local captured = {}
    local selector = {
        AvailableIntegers = { 0, 1, 2 },
        SetAvailableNames = function(_, arr) captured.names = arr end,
        SetSelectedValue = function(_, v) captured.selected = v end,
    }
    local entry = {
        OptionDescription = FText("Select which player should control character 2."),
        NamedSlot_WidgetSelector = { GetContent = function() return selector end },
        SetOptionName = function(_, t) captured.title = t:ToString() end,
        SetOptionDescription = function(_, t) captured.desc = t:ToString() end,
    }
    local settingsList = {
        ScrollBox = {
            GetChildrenCount = function() return 1 end,
            GetChildAt = function() return entry end,
        },
    }

    ui.onSetupSettingsMenu(settingsList)
    assertEq(captured.title, "Character 2 Assignment (Lune)", "settings option title names character")
    assertTrue(captured.desc:find("remembered for the character", 1, true) ~= nil, "settings description updated")
    assertEq(#selector.AvailableIntegers, 4, "4 options including Random")
    assertEq(selector.AvailableIntegers[4], Roster.RANDOM_P1_P2, "4th integer is Random(3)")
    assertEq(captured.names[4]:ToString(), Roster.RANDOM_LABEL, "4th label is Random (P1/P2)")
    assertEq(captured.selected, Roster.RANDOM_P1_P2, "selected value matches Lune's Random setting")

    -- Updating slot 0 (Frey) to Random must sanitize CoopConfig to 0..2 and re-save slot
    ui.onUpdateCharAssignment(0, Roster.RANDOM_P1_P2)
    assertTrue(ue.state.coopConfig.Character1Assignment <= 2, "CoopConfig never left with raw 3")
    assertEq(ue.state.savedSlots, 1, "re-saved sanitized Coop slot")

    -- PlayerIndicator for Lune (in party, Random) -> "P?", for Verso (not in party) -> unchanged
    local retLune = makeParam(FText("P2"))
    ui.onPlayerIndicatorGetText({ CharacterName = FText("Lune") }, retLune)
    assertEq(retLune:get():ToString(), "P?", "PlayerIndicator shows P? for Random")

    local retVerso = makeParam(FText(""))
    ui.onPlayerIndicatorGetText({ CharacterName = FText("Verso") }, retVerso)
    assertEq(retVerso:get():ToString(), "", "PlayerIndicator hides non-party character")
end)

runTest("gamepad: onTick repairs C++ MouseAndKeyboard drop for P2 dialogue without canceling held clicks", function()
    local ue = makeMockUE()
    local fakeTime = 10.0
    local gp = Gamepad.new(ue, function() return fakeTime end)

    -- P2 owns PC0; C++ FCommonInputPreprocessor silently dropped inputType to 0 (bypassing ProcessEvent)
    ue.state.pc0User = 1
    ue.state.inputType = Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD
    ue.state.setInputTypeCalls = {}

    -- Idle tick repairs immediately so dialogue Confirm works and keyboard icons don't stick
    gp.onTick(ue.pc0)
    assertEq(ue.state.inputType, Roster.INPUT_TYPE_GAMEPAD, "onTick restores Gamepad for P2")
    assertEq(#ue.state.setInputTypeCalls, 1, "restored once")

    -- Next tick when already Gamepad does nothing
    gp.onTick(ue.pc0)
    assertEq(#ue.state.setInputTypeCalls, 1, "no redundant SetCurrentInputType calls")

    -- While a button is held, onTick MUST NOT interrupt the press
    local btn = { GetAddress = function() return 0x9999 end }
    gp.onButtonPressed(btn)
    ue.state.inputType = Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD
    gp.onTick(ue.pc0)
    assertEq(ue.state.inputType, Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD, "onTick respects held button")

    -- If the widget is destroyed/clicked without release, timeout self-heals
    fakeTime = 12.0
    gp.onTick(ue.pc0)
    assertEq(ue.state.inputType, Roster.INPUT_TYPE_GAMEPAD, "stale held button auto-expired and Gamepad restored")
end)

runTest("control: deferred map restore retries on SetupCoopController / tick until PC1 exists", function()
    local ue = makeMockUE()
    local cfg = Config.new(nil)
    local gp = Gamepad.new(ue)
    local ctrl = Control.new(ue, cfg, gp)

    -- P2 is exploring and changes map
    ue.state.pc0User = 1
    ctrl.onStartTakeover()
    ctrl.onPrepareToChangeMap()
    ue.state.pc0User = 0

    -- Simulate PC1 not yet spawned during ModActor::ReceiveBeginPlay
    local origSet = ue.setController0User
    local pc1Spawned = false
    ue.setController0User = function(targetId, reason)
        if not pc1Spawned and targetId == 1 then
            return false
        end
        return origSet(targetId, reason)
    end

    ctrl.onMapReady()
    assertEq(ue.state.pc0User, 0, "still 0 before PC1 exists")

    -- Now SetupCoopController spawns PC1 -> retry immediately restores user 1
    pc1Spawned = true
    ctrl.onCoopControllerReady()
    assertEq(ue.state.pc0User, 1, "restored to user 1 as soon as CoopController exists")
end)

runTest("gamepad: advances P2 dialogue line directly on A press without skipping choices or double-firing", function()
    local ue = makeMockUE()
    local fakeTime = 10.0
    local gp = Gamepad.new(ue, function() return fakeTime end)
    ue.state.pc0User = 1
    ue.state.dialogueWaiting = true
    ue.state.dialogueComp = {}
    ue.state.confirmWidget = {}
    ue.state.dialogueHasChoices = false
    ue.state.dialogueAdvances = 0

    -- Holding A from interaction prompt when dialogue opens must NOT immediately skip line 1
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = false
    gp.onDialoguePromptReady("dialogue_line")
    fakeTime = 10.2
    gp.onTick(ue.pc0)
    assertEq(ue.state.dialogueAdvances, 0, "held A from interaction prompt does not skip line 1")

    -- Release A, then press A -> advances dialogue line once
    ue.state.confirmDown = false
    gp.onTick(ue.pc0)
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = true
    gp.onTick(ue.pc0)
    assertEq(ue.state.dialogueAdvances, 1, "fresh A press advances dialogue line")

    -- Holding A next frame does not double-advance
    ue.state.confirmJustPressed = false
    fakeTime = 10.5
    gp.onTick(ue.pc0)
    assertEq(ue.state.dialogueAdvances, 1, "holding A does not double-advance")

    -- When dialogue choices are showing, never bypass choice selection
    ue.state.confirmDown = false
    gp.onTick(ue.pc0)
    ue.state.dialogueHasChoices = true
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = true
    fakeTime = 11.0
    gp.onTick(ue.pc0)
    assertEq(ue.state.dialogueAdvances, 1, "does not fire OnNextClicked while choices are showing")
end)

runTest("gamepad: confirms P2 fullscreen notifications (RelationshipUp/Generic) over dialogue without skipping animation", function()
    local ue = makeMockUE()
    local fakeTime = 20.0
    local gp = Gamepad.new(ue, function() return fakeTime end)
    ue.state.pc0User = 1
    -- Underlying dialogue is still open while RelationshipUp pops up on top of it
    ue.state.dialogueWaiting = true
    ue.state.dialogueComp = {}
    ue.state.confirmWidget = {}
    ue.state.dialogueHasChoices = false
    ue.state.dialogueAdvances = 0

    local notif = { GetAddress = function() return 0x4444 end }
    ue.state.fsnWidget = notif
    ue.state.fsnPrompt = {}
    ue.state.fsnActive = true
    ue.state.fsnPromptReady = false -- intro animation still playing
    ue.state.fsnConfirms = 0

    -- Holding A as notification activates must not trigger anything
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = false
    gp.onFullscreenNotificationActivated(notif)
    fakeTime = 20.3
    gp.onTick(ue.pc0)
    assertEq(ue.state.fsnConfirms, 0, "held A does not confirm notification")

    -- Pressing A early while intro animation is still playing must neither confirm nor skip underlying dialogue
    ue.state.confirmDown = false
    gp.onTick(ue.pc0)
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = true
    fakeTime = 20.4
    gp.onTick(ue.pc0)
    assertEq(ue.state.fsnConfirms, 0, "early A press during intro does not confirm notification")
    assertEq(ue.state.dialogueAdvances, 0, "early A press during intro does not bleed into underlying dialogue")

    -- Prompt is ready; fresh A press confirms notification WITHOUT advancing underlying dialogue
    ue.state.confirmDown = false
    gp.onTick(ue.pc0)
    ue.state.fsnPromptReady = true
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = true
    fakeTime = 20.8
    gp.onTick(ue.pc0)
    assertEq(ue.state.fsnConfirms, 1, "fresh A confirms ready fullscreen notification")
    assertEq(ue.state.dialogueAdvances, 0, "fullscreen notification consumes A before underlying dialogue")
end)

runTest("gamepad: confirms/cancels P2 non-hold ModalPopup while leaving hold-confirm and P1 untouched", function()
    local ue = makeMockUE()
    local fakeTime = 30.0
    local gp = Gamepad.new(ue, function() return fakeTime end)
    ue.state.pc0User = 1

    local modal = { GetAddress = function() return 0x5555 end }
    ue.state.modalWidget = modal
    ue.state.modalConfirmBtn = {}
    ue.state.modalCancelBtn = {}
    ue.state.modalActive = true
    ue.state.modalIsHold = true
    ue.state.modalHasCancel = true
    ue.state.modalConfirms = 0
    ue.state.modalCancels = 0

    -- Hold-confirm modal must NOT be triggered by a tap of A
    gp.onModalPopupActivated(modal)
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = true
    fakeTime = 30.5
    gp.onTick(ue.pc0)
    assertEq(ue.state.modalConfirms, 0, "hold-confirm modal ignores A tap")

    -- B cancels the modal cleanly
    ue.state.confirmDown = false
    ue.state.confirmJustPressed = false
    ue.state.cancelDown = true
    ue.state.cancelJustPressed = true
    fakeTime = 31.0
    gp.onTick(ue.pc0)
    assertEq(ue.state.modalCancels, 1, "B cancels active modal popup")

    -- Non-hold modal confirms on fresh A press
    ue.state.cancelDown = false
    ue.state.cancelJustPressed = false
    ue.state.modalActive = true
    ue.state.modalIsHold = false
    gp.onModalPopupActivated(modal)
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = true
    fakeTime = 31.5
    gp.onTick(ue.pc0)
    assertEq(ue.state.modalConfirms, 1, "fresh A confirms non-hold modal popup")

    -- Player 1 (user 0) is never intercepted
    ue.state.pc0User = 0
    ue.state.modalActive = true
    ue.state.confirmDown = false
    gp.onTick(ue.pc0)
    ue.state.confirmDown = true
    ue.state.confirmJustPressed = true
    fakeTime = 32.0
    gp.onTick(ue.pc0)
    assertEq(ue.state.modalConfirms, 1, "P1 modal input untouched")
end)

print(string.format("\nResults: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end

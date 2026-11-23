-- Safe, game-thread-only UE4SS wrappers and Unreal Engine queries.
-- All Unreal object/property accesses are wrapped in pcall so invalid/GC'd
-- objects never throw unhandled errors inside hooks.

local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local UE = {}

local cache = {
    activeWorld = nil,
    gameplayStatics = nil,
    inputDeviceLibrary = nil,
    subsystemLibrary = nil,
    commonInputClass = nil,
    userSwitchWidgetClass = nil,
    partySlotNameField = "CharacterHardcodedName_2_2A63D4C5433428900D69748563F50580",
    overridePartyField = "OverrideParty_63_56C3E35647CCE3DAC58BE292F8A3FFC0",
}

local function isValid(obj)
    if not obj then
        return false
    end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

UE.isValid = isValid

local function ensureStatics()
    if not isValid(cache.gameplayStatics) then
        cache.gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    if not isValid(cache.inputDeviceLibrary) then
        cache.inputDeviceLibrary = StaticFindObject("/Script/Engine.Default__InputDeviceLibrary")
    end
    if not isValid(cache.subsystemLibrary) then
        cache.subsystemLibrary = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
    end
    if not isValid(cache.commonInputClass) then
        cache.commonInputClass = StaticFindObject("/Script/CommonInput.CommonInputSubsystem")
    end
    return isValid(cache.gameplayStatics)
end

function UE.getGameplayStatics()
    ensureStatics()
    return cache.gameplayStatics
end

-- Tracks the live UWorld from a known current-map actor (e.g. ModActor, Controller_World)
-- so map transitions never accidentally query an outgoing/dying UWorld via FindFirstOf("World").
function UE.setWorldContext(actorOrWorld)
    if not isValid(actorOrWorld) then
        return
    end
    local ok, w = pcall(function()
        if actorOrWorld.GetWorld then
            return actorOrWorld:GetWorld()
        end
        return actorOrWorld
    end)
    if ok and isValid(w) then
        cache.activeWorld = w
    end
end

function UE.clearWorldContext()
    cache.activeWorld = nil
end

function UE.getWorld()
    if isValid(cache.activeWorld) then
        return cache.activeWorld
    end
    -- Prefer GameInstance->GetWorld() before FindFirstOf("World") to avoid stale worlds during travel
    local okGi, gi = pcall(FindFirstOf, "GameInstance")
    if okGi and isValid(gi) then
        local okW, w = pcall(function() return gi:GetWorld() end)
        if okW and isValid(w) then
            cache.activeWorld = w
            return w
        end
    end
    local ok, world = pcall(FindFirstOf, "World")
    if ok and isValid(world) then
        return world
    end
    return nil
end

function UE.getGameInstance()
    if not ensureStatics() then
        return nil
    end
    local world = UE.getWorld()
    if not world then
        return nil
    end
    local ok, gi = pcall(function() return cache.gameplayStatics:GetGameInstance(world) end)
    if ok and isValid(gi) then
        return gi
    end
    return nil
end

function UE.getPlayerController(index)
    if not ensureStatics() then
        return nil
    end
    local world = UE.getWorld()
    if not world then
        return nil
    end
    local ok, pc = pcall(function() return cache.gameplayStatics:GetPlayerController(world, index or 0) end)
    if ok and isValid(pc) then
        return pc
    end
    return nil
end

function UE.getPlatformUserId(pc)
    if not isValid(pc) then
        return nil
    end
    local ok, id = pcall(function()
        local uid = pc:GetPlatformUserId()
        return uid and uid.InternalId or nil
    end)
    if ok and type(id) == "number" then
        return id
    end
    return nil
end

function UE.getPrimaryPlatformUser()
    ensureStatics()
    if not isValid(cache.inputDeviceLibrary) then
        return nil, 0
    end
    local ok, user, id = pcall(function()
        local u = cache.inputDeviceLibrary:GetPrimaryPlatformUser()
        return u, (u and u.InternalId or 0)
    end)
    if ok and user then
        return user, id
    end
    return nil, 0
end

function UE.getAllActiveUsers()
    -- 1. Prefer reading live PlatformUserIds from the current world's active PlayerControllers (PC0..PC2).
    --    This is immune to UE4SS TArray out-param marshalling quirks and always reflects live controllers.
    local users = {}
    local seen = {}
    for i = 0, Roster.MAX_PARTY_SLOTS - 1 do
        local pc = UE.getPlayerController(i)
        if pc then
            local okPc, u = pcall(function() return pc:GetPlatformUserId() end)
            if okPc and u and type(u.InternalId) == "number" and not seen[u.InternalId] then
                seen[u.InternalId] = true
                users[#users + 1] = { raw = u, internalId = u.InternalId }
            end
        end
    end

    -- 2. Supplement with InputDeviceLibrary::GetAllActiveUsers if available
    ensureStatics()
    if isValid(cache.inputDeviceLibrary) then
        pcall(function()
            local outParams = {}
            cache.inputDeviceLibrary:GetAllActiveUsers(outParams)
            local arr = outParams.OutUsers or outParams
            local function collect(u)
                if u ~= nil and type(u.InternalId) == "number" and not seen[u.InternalId] then
                    seen[u.InternalId] = true
                    users[#users + 1] = { raw = u, internalId = u.InternalId }
                end
            end
            if type(arr) == "table" then
                for i = 1, #arr do
                    collect(arr[i])
                end
            elseif arr and arr.ForEach then
                arr:ForEach(function(_, elem)
                    collect(elem:get())
                end)
            end
        end)
    end

    table.sort(users, function(a, b) return a.internalId < b.internalId end)
    return users
end

function UE.findPlatformUserByInternalId(targetInternalId)
    if targetInternalId == nil then
        return nil
    end
    local primary, primaryId = UE.getPrimaryPlatformUser()
    if primary and primaryId == targetInternalId then
        return primary
    end
    local users = UE.getAllActiveUsers()
    for _, entry in ipairs(users) do
        if entry.internalId == targetInternalId then
            return entry.raw
        end
    end
    return nil
end

-- Safely assigns PlatformUserId `targetInternalId` to PlayerController 0.
-- Always normalizes through PrimaryUser when switching between two non-primary users
-- so 3-player controller swaps never scramble PC1 and PC2.
function UE.setController0User(targetInternalId, reason)
    if targetInternalId == nil or not ensureStatics() then
        return false
    end
    local pc0 = UE.getPlayerController(0)
    if not pc0 then
        return false
    end

    local currentId = UE.getPlatformUserId(pc0)
    if currentId == targetInternalId then
        return true
    end

    local targetUser = UE.findPlatformUserByInternalId(targetInternalId)
    if not targetUser then
        Log.debug("setController0User(%s): user %s not yet among active controllers",
            tostring(reason), tostring(targetInternalId))
        return false
    end

    local primaryUser, primaryId = UE.getPrimaryPlatformUser()
    if primaryUser and currentId ~= primaryId and targetInternalId ~= primaryId then
        pcall(function()
            cache.gameplayStatics:SetPlayerPlatformUserId(pc0, primaryUser)
        end)
    end

    local ok, err = pcall(function()
        cache.gameplayStatics:SetPlayerPlatformUserId(pc0, targetUser)
    end)
    if not ok then
        Log.error("SetPlayerPlatformUserId failed (%s): %s", tostring(reason), tostring(err))
        return false
    end

    Log.debug("PC0 user: %s -> %s (%s)", tostring(currentId), tostring(targetInternalId), tostring(reason))
    return true
end

function UE.getModActor()
    local pc1 = UE.getPlayerController(1)
    if pc1 then
        local ok, ma = pcall(function() return pc1.ModActor end)
        if ok and isValid(ma) then
            return ma
        end
    end
    local ok, ma = pcall(FindFirstOf, "ModActor_C")
    if ok and isValid(ma) then
        return ma
    end
    return nil
end

function UE.getCoopConfig()
    local ma = UE.getModActor()
    if not ma then
        return nil
    end
    local ok, cfg = pcall(function() return ma.CoopConfig end)
    if ok and isValid(cfg) then
        return cfg
    end
    return nil
end

function UE.saveCoopConfigSlot(coopConfig)
    if not isValid(coopConfig) or not ensureStatics() then
        return false
    end
    local ok = pcall(function()
        cache.gameplayStatics:SaveGameToSlot(coopConfig, "Coop", 0)
    end)
    return ok
end

function UE.getBattleManager()
    local pc0 = UE.getPlayerController(0)
    if not pc0 then
        return nil
    end
    local ok, bm = pcall(function() return pc0.AC_jRPG_BattleManager end)
    if ok and isValid(bm) then
        return bm
    end
    return nil
end

function UE.isWorldController(pc)
    if not isValid(pc) then
        return false
    end
    local ok, name = pcall(function() return pc:GetClass():GetFName():ToString() end)
    return ok and name == "BP_jRPG_Controller_World_C"
end

function UE.isInBattle(pc0)
    pc0 = pc0 or UE.getPlayerController(0)
    if not isValid(pc0) then
        return false
    end
    local ok, res = pcall(function() return pc0:IsInBattle() end)
    return ok and res == true
end

local function readSlotHardcodedName(slotStruct)
    if not slotStruct then
        return nil
    end
    local ok, nameVal = pcall(function()
        local n = slotStruct[cache.partySlotNameField]
        if n and n.ToString then
            return n:ToString()
        end
        return nil
    end)
    if ok and type(nameVal) == "string" and nameVal ~= "" and nameVal ~= "None" then
        return nameVal
    end
    return nil
end

local function readPartyArrayNames(tarray)
    local names = {}
    if not tarray then
        return names
    end
    pcall(function()
        if tarray.ForEach then
            tarray:ForEach(function(_, elem)
                local slot = elem:get()
                local name = readSlotHardcodedName(slot)
                if name then
                    names[#names + 1] = name
                end
            end)
        elseif type(tarray) == "table" then
            for i = 1, #tarray do
                local name = readSlotHardcodedName(tarray[i])
                if name then
                    names[#names + 1] = name
                end
            end
        end
    end)
    return names
end

-- Returns 1-indexed array of CharacterHardcodedName strings from GameInstance.CurrentParty.
function UE.getCurrentPartyNames()
    local gi = UE.getGameInstance()
    if not gi then
        return {}
    end
    local ok, party = pcall(function() return gi.CurrentParty end)
    if not ok or not party then
        return {}
    end
    return readPartyArrayNames(party)
end

-- Mirrors ModLibrary::More than 1 Char in Party (handles Prologue with Sophie).
function UE.moreThanOneCharInParty(partyNames)
    return #partyNames > 1 and partyNames[2] ~= "Sophie"
end

function UE.findPartyIndex(partyNames, charId)
    if not charId then
        return nil
    end
    for i = 1, #partyNames do
        if partyNames[i] == charId then
            return i - 1 -- 0-based party index
        end
    end
    return nil
end

function UE.getCharacterNameFromBattleActor(actor)
    if not isValid(actor) then
        return nil
    end
    local ok, name = pcall(function()
        local stats = actor.AC_jRPG_CharacterStats
        if stats and stats:IsValid() then
            local n = stats.CharacterHardcodedName
            if n and n.ToString then
                return n:ToString()
            end
        end
        return nil
    end)
    if ok and type(name) == "string" and name ~= "" and name ~= "None" then
        return name
    end
    return nil
end

-- Returns { [spotIndex] = charId } for all currently spawned player battle actors.
function UE.getSpawnedBattleSpotCharacters(bm)
    local spots = {}
    bm = bm or UE.getBattleManager()
    if not isValid(bm) then
        return spots
    end

    for spot = 0, Roster.MAX_PARTY_SLOTS - 1 do
        local ok, charName = pcall(function()
            local out = {}
            bm:GetPlayerCharacterAtBattleSpot(spot, out)
            local actor = out.Character or out[1]
            if isValid(actor) then
                return UE.getCharacterNameFromBattleActor(actor)
            end
            return nil
        end)
        if ok and charName then
            spots[spot] = charName
        end
    end

    -- Fallback: iterate BattleParty using the game's RemapPartyIndexToBattleSpotIndex table
    if next(spots) == nil then
        local ok, battleParty = pcall(function() return bm.BattleParty end)
        if ok and battleParty then
            local bpNames = readPartyArrayNames(battleParty)
            local count = #bpNames
            if count == 1 then
                spots[0] = bpNames[1]
            elseif count >= 2 then
                -- Game's RemapPartyIndexToBattleSpotIndex for >1 member: [0]->spot 2, [1]->spot 0, [2]->spot 1
                local remap = { [1] = 2, [2] = 0, [3] = 1 }
                for i = 1, math.min(count, Roster.MAX_PARTY_SLOTS) do
                    spots[remap[i]] = bpNames[i]
                end
            end
        end
    end

    return spots
end

-- Mirrors ModLibrary::Is Overriden Solo Battle exactly so our CoopConfig projection matches it.
function UE.getOverrideSoloBattleInfo(bm, partyNames)
    bm = bm or UE.getBattleManager()
    if not isValid(bm) then
        return false, -1, nil
    end
    local ok, overrideNames = pcall(function()
        local params = bm.CurrentBattleStartParams
        if not params then
            return nil
        end
        local override = params[cache.overridePartyField]
        if not override then
            return nil
        end
        return readPartyArrayNames(override)
    end)
    if not ok or type(overrideNames) ~= "table" or #overrideNames ~= 1 then
        return false, -1, nil
    end
    local soloChar = overrideNames[1]
    local partyIdx = UE.findPartyIndex(partyNames or UE.getCurrentPartyNames(), soloChar)
    return true, (partyIdx or 0), soloChar
end

-- Reads gamepad button state directly from PC0's PlayerInput (bypasses Slate/CommonUI/AnalogCursor).
function UE.isGamepadKeyPressed(pc, keyNameStr)
    if not isValid(pc) then
        return false, false
    end
    local ok, justPressed, isDown = pcall(function()
        local key = { KeyName = FName(keyNameStr) }
        local jp = pc:WasInputKeyJustPressed(key) == true
        local down = pc:IsInputKeyDown(key) == true
        return jp, down
    end)
    if ok then
        return justPressed, isDown
    end
    return false, false
end

-- Returns (dialogueComponent, confirmPromptWidget, hasChoices) if PC0 currently has an active dialogue
-- line waiting for Confirm input.
function UE.getActiveDialogueWaitingForConfirm(pc0)
    if not isValid(pc0) then
        return nil, nil, false
    end
    local ok, dlgComp, confirmWidget, hasChoices = pcall(function()
        if ensureStatics() and cache.gameplayStatics:IsGamePaused(pc0) == true then
            return nil, nil, false
        end
        local comp = pc0.BP_DialogueSystemComponent
        if not isValid(comp) then
            return nil, nil, false
        end
        if comp:HasActiveDialogue() ~= true then
            return nil, nil, false
        end
        if comp.IsWaitingForDialogInput ~= true then
            return nil, nil, false
        end

        local hud = pc0.ExplorationHUDWidget
        local overlay = isValid(hud) and hud.WBP_DialogueOverlay or nil
        local container = isValid(overlay) and overlay.WBP_DialogueContainer or nil
        if not isValid(container) then
            return nil, nil, false
        end
        if container:IsActivated() ~= true then
            return nil, nil, false
        end

        local choices = container.CurrentChoiceWidgets
        local choiceCount = 0
        if choices and choices.GetArrayNum then
            choiceCount = choices:GetArrayNum()
        elseif type(choices) == "table" then
            choiceCount = #choices
        end
        local confirm = container.WBP_GM_PromptGeneric_Confirm
        return comp, (isValid(confirm) and confirm or nil), (choiceCount > 0)
    end)
    if ok then
        return dlgComp, confirmWidget, hasChoices
    end
    return nil, nil, false
end

function UE.advanceDialogueLine(dlgComp, confirmWidget)
    if not isValid(dlgComp) then
        return false
    end
    local ok, err = pcall(function()
        local arg = isValid(confirmWidget) and confirmWidget or (CreateInvalidObject and CreateInvalidObject() or nil)
        dlgComp:OnNextClicked(arg)
    end)
    if not ok then
        Log.warn("Dialogue OnNextClicked failed: %s", tostring(err))
        return false
    end
    return true
end

function UE.getCommonInputSubsystem(pc)
    if not isValid(pc) or not ensureStatics() then
        return nil
    end
    if not isValid(cache.subsystemLibrary) or not isValid(cache.commonInputClass) then
        return nil
    end
    local ok, sub = pcall(function()
        return cache.subsystemLibrary:GetLocalPlayerSubSystemFromPlayerController(pc, cache.commonInputClass)
    end)
    if ok and isValid(sub) then
        return sub
    end
    return nil
end

function UE.spawnTurnToast(text)
    if not ensureStatics() then
        return false
    end
    local pc0 = UE.getPlayerController(0)
    if not pc0 then
        return false
    end
    if not isValid(cache.userSwitchWidgetClass) then
        cache.userSwitchWidgetClass = StaticFindObject("/Game/Coop/UserSwitchWidget.UserSwitchWidget_C")
    end
    if not isValid(cache.userSwitchWidgetClass) then
        Log.debug("UserSwitchWidget_C not loaded yet; skipping turn toast")
        return false
    end
    local ok, err = pcall(function()
        local widget = cache.gameplayStatics:SpawnObject(cache.userSwitchWidgetClass, pc0)
        if isValid(widget) then
            widget.Text = FText(text)
            widget:AddToViewport(9999)
        end
    end)
    if not ok then
        Log.warn("Failed to spawn turn toast: %s", tostring(err))
        return false
    end
    return true
end

return UE

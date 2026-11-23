-- E33CoopV2 — Hybrid Coop Runtime for Clair Obscur: Expedition 33
--
-- Runs alongside the unpatched base Kouzukii coop .utoc assets and implements all
-- extended features in clean, modular Lua with zero Kismet bytecode splicing.

local function getScriptDir()
    local src = debug.getinfo(1, "S").source
    if type(src) == "string" and src:sub(1, 1) == "@" then
        local path = src:sub(2):gsub("\\", "/")
        return path:match("^(.*)/[^/]+$") or "."
    end
    return "."
end

local scriptDir = getScriptDir()
package.path = scriptDir .. "/?.lua;" .. scriptDir .. "/?/init.lua;" .. package.path

local modRoot = scriptDir:match("^(.*)/Scripts$") or scriptDir
local configPath = modRoot .. "/config.json"

math.randomseed(os.time())

local Log = require("e33coop.log")
local Config = require("e33coop.config")
local UE = require("e33coop.ue")
local Gamepad = require("e33coop.gamepad")
local Control = require("e33coop.control")
local Battle = require("e33coop.battle")
local UI = require("e33coop.ui")
local Hooks = require("e33coop.hooks")

local config = Config.new(configPath)
config.load()

local gamepad = Gamepad.new(UE)
local control = Control.new(UE, config, gamepad)
local battle = Battle.new(UE, config, control)
local ui = UI.new(UE, config, battle)
local hooks = Hooks.new()

-- ---------------------------------------------------------------------------
-- 1. Native hooks (/Script/...) — safe click tracking & CommonUI gamepad guard
-- ---------------------------------------------------------------------------

hooks.registerNative("/Script/CommonUI.CommonButtonBase:HandleButtonPressed", function()
    gamepad.onButtonPressed()
end)

hooks.registerNative("/Script/CommonUI.CommonButtonBase:HandleButtonReleased", function()
    gamepad.onButtonReleased()
end)

hooks.registerNative("/Script/CommonInput.CommonInputSubsystem:SetCurrentInputType", function(selfObj, newInputType)
    gamepad.onSetCurrentInputTypePre(selfObj:get(), newInputType)
end)

hooks.registerNative("/Script/UMG.WidgetBlueprintLibrary:SetInputMode_GameOnly", function() end, function()
    gamepad.ensureGamepadIfSafe("SetInputMode_GameOnly")
    gamepad.syncCursorVisibility("SetInputMode_GameOnly", false)
end)

for _, modeFn in ipairs({ "SetInputMode_UIOnlyEx", "SetInputMode_GameAndUIEx" }) do
    hooks.registerNative("/Script/UMG.WidgetBlueprintLibrary:" .. modeFn, function() end, function()
        gamepad.ensureGamepadIfSafe(modeFn)
        gamepad.syncCursorVisibility(modeFn, true)
    end)
end

-- ---------------------------------------------------------------------------
-- 2. Blueprint hooks (/Game/...) — registered lazily as classes load
-- ---------------------------------------------------------------------------

local warnedV1Pak = false

local function warnIfV1PatchedPakDetected()
    if warnedV1Pak then
        return
    end
    local pc1 = UE.getPlayerController(1)
    if not pc1 then
        return
    end
    local ok, val = pcall(function() return pc1.CoopExplorationUserId end)
    if ok and val ~= nil then
        warnedV1Pak = true
        Log.warn("Detected v1 bytecode-patched expedition33_coop_P.utoc (CoopController.CoopExplorationUserId exists). "
            .. "Please restore the unpatched upstream expedition33_coop_P.utoc so v1 patches and E33CoopV2 do not collide.")
    end
end

-- Map lifecycle & CoopConfig load
hooks.addBlueprint("/Game/Coop/ModActor.ModActor_C:ReceiveBeginPlay", function()
    warnIfV1PatchedPakDetected()
    control.onMapReady()
    battle.onCoopConfigLoaded()
end)

hooks.addBlueprint("/Game/Coop/ModActor.ModActor_C:Completed_5159FBB749F4C17CA0ECC19333961EAE", function()
    battle.onCoopConfigLoaded()
end)

hooks.addBlueprint("/Game/Coop/CoopController.CoopController_C:InpActEvt_Gamepad_Special_Right_K2Node_InputKeyEvent_0", function()
    control.onStartTakeover()
end)

-- World controller battle & map transitions
hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:PrepareToChangeMap", function()
    control.onPrepareToChangeMap()
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:OnBattleBeginTransitionRequested", function()
    control.onBattleBegin()
    battle.syncConfig("battle_begin")
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:ResumeExplorationOnBattleEnd", function(_, _, battleEndResult)
    local ok, res = pcall(function() return battleEndResult:get() end)
    control.onBattleEnd(ok and res or 0)
    battle.syncConfig("battle_end")
end)

-- BattleManager spawn, turn start, and event-driven Victory/Flee flow
hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Components/AC_jRPG_BattleManager.AC_jRPG_BattleManager_C:Spawn Player Character", function()
    battle.onPlayerCharacterSpawned()
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Components/AC_jRPG_BattleManager.AC_jRPG_BattleManager_C:StartCharacterTurn", function()
    battle.onStartCharacterTurn()
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Components/AC_jRPG_BattleManager.AC_jRPG_BattleManager_C:StartBattleEndFlow", function(_, battleEndResult)
    local ok, res = pcall(function() return battleEndResult:get() end)
    control.onBattleEndFlowStarted(ok and res or 0)
end)

-- Battle character turns (player turn toast/handoff + enemy turn P1 defense safety + late OnTurnEnded guard)
hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_Battle_Base.BP_jRPG_Character_Battle_Base_C:OnTurnStart", function(selfObj)
    battle.onTurnStart(selfObj:get())
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_Battle_Base.BP_jRPG_Character_Battle_Base_C:OnTurnEnded", function(selfObj)
    battle.onTurnEnded(selfObj:get())
end)

-- Settings UI & Team Screen PlayerIndicator (optional: their classes only load when those menus first open)
hooks.addBlueprint("/Game/UI/Widgets/InGame_Menu/Settings/OptionsList/WBP_Settings_GeneralOptionsList.WBP_Settings_GeneralOptionsList_C:SetupAvailableOptions", function(selfObj)
    ui.onSetupSettingsMenu(selfObj:get())
end, true)

for slot = 1, 3 do
    local slotZeroBased = slot - 1
    hooks.addBlueprint(
        string.format("/Game/UI/Widgets/InGame_Menu/Settings/OptionsList/WBP_Settings_GeneralOptionsList.WBP_Settings_GeneralOptionsList_C:UpdateChar%dAssignment", slot),
        function(_, valueParam)
            local ok, val = pcall(function() return valueParam:get() end)
            if ok then
                ui.onUpdateCharAssignment(slotZeroBased, val)
            end
        end,
        true
    )
end

hooks.addBlueprint("/Game/Coop/PlayerIndicator.PlayerIndicator_C:GetText", function(selfObj, returnValueParam)
    ui.onPlayerIndicatorGetText(selfObj:get(), returnValueParam)
end, true)

-- Hardware cursor suppression on menus & Expedition Flag (SavePointMenu / Rest animation)
hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:OpenSavePointMenu", function()
    gamepad.ensureGamepadIfSafe("OpenSavePointMenu")
    gamepad.syncCursorVisibility("OpenSavePointMenu", true)
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:CloseSavePointMenu", function()
    gamepad.syncCursorVisibility("CloseSavePointMenu", false)
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:SetInputModeUI", function(_, uiModeEnabledParam)
    local ok, enabled = pcall(function() return uiModeEnabledParam:get() end)
    gamepad.ensureGamepadIfSafe("SetInputModeUI")
    gamepad.syncCursorVisibility("SetInputModeUI", ok and enabled == true or false)
end)

hooks.addBlueprint("/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:SetInputModeBattle", function(_, isTakingActionParam)
    local ok, takingAction = pcall(function() return isTakingActionParam:get() end)
    gamepad.syncCursorVisibility("SetInputModeBattle", not (ok and takingAction == true))
end)

hooks.addBlueprint("/Game/UI/Widgets/HUD_Exploration/WBP_SavePointMenu.WBP_SavePointMenu_C:BndEvt__WBP_SavePointMenu_RestButton_K2Node_ComponentBoundEvent_9_CommonButtonBaseClicked__DelegateSignature", function()
    gamepad.ensureGamepadIfSafe("SavePointRest")
    gamepad.syncCursorVisibility("SavePointRest", false)
end, true)

hooks.addBlueprint("/Game/UI/Widgets/HUD_Exploration/WBP_SavePointMenu.WBP_SavePointMenu_C:BP_OnDeactivated", function()
    gamepad.syncCursorVisibility("SavePointDeactivated", nil)
end, true)

-- Dialogue & Fullscreen Notification Gamepad safety nets (e.g. Dialogue Confirm, RelationshipUp)
hooks.addBlueprint("/Game/UI/Widgets/DialogueSystem/WBP_DialogueContainer.WBP_DialogueContainer_C:BP_OnActivated", function()
    gamepad.ensureGamepadIfSafe("dialogue_activated")
end, true)

hooks.addBlueprint("/Game/UI/Widgets/DialogueSystem/WBP_DialogueContainer.WBP_DialogueContainer_C:ShowDialogueLine", function()
    gamepad.ensureGamepadIfSafe("dialogue_line")
end, true)

hooks.addBlueprint("/Game/UI/Widgets/FullScreenNotificationSystem/WBP_FullScreenNotificationContainer.WBP_FullScreenNotificationContainer_C:OnRelationshipUp", function()
    gamepad.ensureGamepadIfSafe("notification_relationship_up")
end, true)

hooks.addBlueprint("/Game/UI/Widgets/FullScreenNotificationSystem/WBP_FullScreenNotificationContainer.WBP_FullScreenNotificationContainer_C:PushNotificationFromGameAction", function()
    gamepad.ensureGamepadIfSafe("notification_game_action")
end, true)

hooks.addBlueprint("/Game/UI/Widgets/FullScreenNotificationSystem/WBP_FullScreenNotificationContainer.WBP_FullScreenNotificationContainer_C:OnWorldMapCapacityUnlocked", function()
    gamepad.ensureGamepadIfSafe("notification_worldmap_capacity")
end, true)

hooks.installLazyWatchers()
Log.info("Loaded E33CoopV2 (config=%s)", configPath)

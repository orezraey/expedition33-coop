-- Click-safe CommonUI Gamepad mode keeper & multi-controller hardware cursor suppressor.
--
-- Why this exists (two related CommonUI + multi-LocalPlayer bugs in UE5.4):
--   1. Non-primary player (P2/P3) on PC0: CommonUI / Slate drops PC0's CommonInputSubsystem
--      back to MouseAndKeyboard (0), showing keyboard prompts and blocking Confirm actions in
--      dialogues and fullscreen notifications (e.g. RelationshipUp). Forcing Gamepad every tick
--      breaks menu clicks because SetCurrentInputType mid-press cancels CommonButton clicks.
--   2. Center-screen blinking mouse cursor (e.g. resting at an Expedition Flag for 2-3s):
--      The game unconditionally sets PC0.bShowMouseCursor = true when opening menus
--      (OpenSavePointMenu, SetInputModeUI, SetInputModeBattle) and relies on CommonUI's
--      FCommonAnalogCursor to hide and center the hardware cursor in Gamepad mode. In co-op,
--      the extra CoopControllers (PC1/PC2) sit in MouseAndKeyboard (0) on the same fullscreen
--      viewport, AND during Rest (Anim_Rest) WBP_SavePointMenu deactivates while bShowMouseCursor
--      stays true, causing Slate to flicker the hardware cursor at Viewport/2 for 2-3 seconds.
--
-- Solution:
--   - Keep extra CoopControllers (PC1/PC2) locked to Gamepad (1) with hardware cursor disabled.
--   - Keep PC0.bShowMouseCursor = false & CurrentMouseCursor = None (0) while P2/P3 own PC0.
--   - Hide P1's cursor during Rest (the menu is gone but bShowMouseCursor stays true); otherwise
--     give P1 the game's own cursor behaviour, restored whenever PC0 comes back to P1.
--   - Track held buttons via HandleButtonPressed / HandleButtonReleased so input-type switches
--     never cancel held clicks.

local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local Gamepad = {}

local CURSOR_NONE = 0    -- EMouseCursor::None
local CURSOR_DEFAULT = 1 -- EMouseCursor::Default

function Gamepad.new(ue)
    local self = {
        heldButtons = 0,
        deferredRestore = false,
        -- Last cursor visibility the game asked for at a hooked point (restored when P1 gets PC0 back)
        menuWantsCursor = false,
        -- Guards against re-entrant SetCurrentInputType hook calls triggered by us
        suppressHook = false,
    }

    local function sameUObject(a, b)
        if not a or not b then
            return false
        end
        if a == b then
            return true
        end
        local okEq, same = pcall(function()
            return a:GetAddress() == b:GetAddress()
        end)
        return okEq and same == true
    end

    local function isNonPrimaryOnPC0()
        local pc0 = ue.getPlayerController(0)
        if not pc0 then
            return false, nil
        end
        local _, primaryId = ue.getPrimaryPlatformUser()
        local currentId = ue.getPlatformUserId(pc0)
        if currentId == nil or currentId == primaryId then
            return false, pc0
        end
        return true, pc0
    end

    -- Hides the cursor of a controller driven by a gamepad-only player (PC1/PC2, or P2/P3 on PC0).
    -- The cursor shape is set to None too: the game toggles bShowMouseCursor on its own in places
    -- we don't hook, but it never touches CurrentMouseCursor.
    local function hideCursor(pc)
        if not ue.isValid(pc) then
            return
        end
        pcall(function()
            pc.bShowMouseCursor = false
            pc.CurrentMouseCursor = CURSOR_NONE
        end)
    end

    -- Player 1 on PC0 gets the game's own behaviour back: the default cursor shape (the game never
    -- restores it after hideCursor) and the visibility the game last asked for. With a gamepad,
    -- CommonUI's analog cursor hides it as in single player; with a mouse it stays usable, because
    -- a native switch to MouseAndKeyboard can't be seen from Lua to restore it later.
    local function showPrimaryCursor(pc0, visible)
        if not ue.isValid(pc0) then
            return
        end
        pcall(function()
            pc0.CurrentMouseCursor = CURSOR_DEFAULT
            pc0.bShowMouseCursor = visible
        end)
    end

    function self.resetButtonState()
        self.heldButtons = 0
        self.deferredRestore = false
    end

    -- Forces extra CoopControllers (PC1, PC2) into Gamepad mode with cursor hidden so they
    -- never sit in MouseAndKeyboard (0) and fight PC0's FCommonAnalogCursor on the shared viewport.
    function self.syncExtraControllersToGamepad(reason)
        for idx = 1, Roster.MAX_PARTY_SLOTS - 1 do
            local pc = ue.getPlayerController(idx)
            if pc then
                hideCursor(pc)
                local sub = ue.getCommonInputSubsystem(pc)
                if sub then
                    local okGet, curType = pcall(function() return sub:GetCurrentInputType() end)
                    if okGet and curType ~= Roster.INPUT_TYPE_GAMEPAD then
                        self.suppressHook = true
                        pcall(function()
                            sub:SetCurrentInputType(Roster.INPUT_TYPE_GAMEPAD)
                        end)
                        self.suppressHook = false
                        Log.debug("Set PC%d CommonUI inputType %s -> Gamepad (%s)",
                            idx, tostring(curType), tostring(reason))
                    end
                end
            end
        end
    end

    -- Applies cursor visibility after the game changed it (menuRequestedCursor = the value the game
    -- just wrote, false to hide it during Rest) or after PC0 changed owner (nil: keep the last request).
    -- P2/P3 on PC0 never see it; Player 1 gets what the game asked for.
    function self.syncCursorVisibility(reason, menuRequestedCursor)
        if menuRequestedCursor ~= nil then
            self.menuWantsCursor = not not menuRequestedCursor
        end

        self.syncExtraControllersToGamepad(reason)

        local nonPrimary, pc0 = isNonPrimaryOnPC0()
        if not pc0 then
            return
        end

        if nonPrimary then
            hideCursor(pc0)
            Log.debug("Hid PC0 cursor for non-primary player (%s)", tostring(reason))
        else
            showPrimaryCursor(pc0, self.menuWantsCursor)
        end
    end

    function self.onMapReady()
        self.resetButtonState()
        self.menuWantsCursor = false
        self.syncExtraControllersToGamepad("map_ready")
        self.ensureGamepadIfSafe("map_ready")
        self.syncCursorVisibility("map_ready", false)
    end

    function self.ensureGamepadIfSafe(reason)
        self.syncExtraControllersToGamepad(reason)

        local nonPrimary, pc0 = isNonPrimaryOnPC0()
        if not nonPrimary or not pc0 then
            self.deferredRestore = false
            return false
        end

        -- Even while a button is held, hiding PC0's hardware cursor is safe and doesn't fire OnInputMethodChanged
        hideCursor(pc0)

        if self.heldButtons > 0 then
            self.deferredRestore = true
            Log.debug("Deferring CommonUI Gamepad restore (%s): heldButtons=%d",
                tostring(reason), self.heldButtons)
            return false
        end

        local sub = ue.getCommonInputSubsystem(pc0)
        if not sub then
            return false
        end

        local okGet, curType = pcall(function() return sub:GetCurrentInputType() end)
        if not okGet then
            return false
        end
        if curType == Roster.INPUT_TYPE_GAMEPAD then
            self.deferredRestore = false
            return true
        end

        self.suppressHook = true
        local okSet, err = pcall(function()
            sub:SetCurrentInputType(Roster.INPUT_TYPE_GAMEPAD)
        end)
        self.suppressHook = false
        self.deferredRestore = false

        if okSet then
            Log.debug("Restored CommonUI inputType %s -> Gamepad (%s)", tostring(curType), tostring(reason))
            return true
        end
        Log.warn("SetCurrentInputType(Gamepad) failed (%s): %s", tostring(reason), tostring(err))
        return false
    end

    function self.onButtonPressed()
        self.heldButtons = self.heldButtons + 1
    end

    function self.onButtonReleased()
        if self.heldButtons > 0 then
            self.heldButtons = self.heldButtons - 1
        end
        if self.heldButtons == 0 and self.deferredRestore then
            self.ensureGamepadIfSafe("button_released_deferred")
        elseif self.heldButtons == 0 then
            -- Also repair quietly if inputType dropped to MouseAndKeyboard right before release
            self.ensureGamepadIfSafe("button_released")
        end
    end

    -- Pre-hook on /Script/CommonInput.CommonInputSubsystem:SetCurrentInputType(NewInputType)
    function self.onSetCurrentInputTypePre(subObj, newInputTypeParam)
        if self.suppressHook then
            return
        end

        local okVal, requested = pcall(function() return newInputTypeParam:get() end)
        if not okVal then
            return
        end

        -- 1. Extra CoopControllers (PC1, PC2) are gamepad-only: never allow MouseAndKeyboard (0)
        for idx = 1, Roster.MAX_PARTY_SLOTS - 1 do
            local extraPc = ue.getPlayerController(idx)
            if extraPc then
                local extraSub = ue.getCommonInputSubsystem(extraPc)
                if sameUObject(subObj, extraSub) then
                    hideCursor(extraPc)
                    if requested == Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD then
                        pcall(function()
                            newInputTypeParam:set(Roster.INPUT_TYPE_GAMEPAD)
                        end)
                        Log.debug("Blocked PC%d CommonUI drop to MouseAndKeyboard", idx)
                    end
                    return
                end
            end
        end

        -- 2. PC0 handling
        local nonPrimary, pc0 = isNonPrimaryOnPC0()
        if not pc0 then
            return
        end

        local pc0Sub = ue.getCommonInputSubsystem(pc0)
        if not sameUObject(subObj, pc0Sub) then
            return
        end

        if not nonPrimary then
            -- Player 1 (primary user) on PC0: CommonUI handles it as in single player
            return
        end

        hideCursor(pc0)
        if requested ~= Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD then
            return
        end
        if self.heldButtons > 0 then
            -- Do not interfere while a button is held; restore cleanly after release
            self.deferredRestore = true
            return
        end
        local okSet = pcall(function()
            newInputTypeParam:set(Roster.INPUT_TYPE_GAMEPAD)
        end)
        if okSet then
            Log.debug("Blocked PC0 CommonUI drop to MouseAndKeyboard while non-primary player owns PC0")
        end
    end

    return self
end

return Gamepad

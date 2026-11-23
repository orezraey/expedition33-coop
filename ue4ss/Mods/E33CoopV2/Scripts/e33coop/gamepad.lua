-- Click-safe CommonUI Gamepad mode keeper for non-primary players (Player 2 / Player 3).
--
-- Why this exists:
--   When a non-primary user owns PC0 (user != 0), CommonUI / Slate frequently drops PC0's
--   CommonInputSubsystem back to MouseAndKeyboard (0), causing keyboard prompts and blocking
--   CommonUI Confirm actions in dialogues and fullscreen notifications (e.g. RelationshipUp).
--   Forcing Gamepad blindly every tick breaks menu clicks because calling SetCurrentInputType
--   while a CommonButton is pressed cancels the press before HandleButtonClicked fires.
--
-- Solution:
--   1. Track active held buttons via HandleButtonPressed / HandleButtonReleased.
--   2. Intercept SetCurrentInputType(0) for PC0 when owned by user != 0 and no button is held.
--   3. Restore Gamepad on UI transitions (dialogue lines, fullscreen notifications, input mode
--      changes, and after button release) — never mid-press and never interfering with Player 1.

local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local Gamepad = {}

function Gamepad.new(ue)
    local self = {
        heldButtons = 0,
        deferredRestore = false,
        -- Guards against re-entrant SetCurrentInputType hook calls triggered by us
        suppressHook = false,
    }

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

    function self.resetButtonState()
        self.heldButtons = 0
        self.deferredRestore = false
    end

    function self.ensureGamepadIfSafe(reason)
        local nonPrimary, pc0 = isNonPrimaryOnPC0()
        if not nonPrimary or not pc0 then
            self.deferredRestore = false
            return false
        end

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
        local nonPrimary, pc0 = isNonPrimaryOnPC0()
        if not nonPrimary or not pc0 then
            return
        end

        local pc0Sub = ue.getCommonInputSubsystem(pc0)
        if not pc0Sub or subObj ~= pc0Sub then
            -- Compare underlying UObject addresses if userdata proxies differ
            local okEq, same = pcall(function()
                return subObj:GetAddress() == pc0Sub:GetAddress()
            end)
            if not (okEq and same) then
                return
            end
        end

        local okVal, requested = pcall(function() return newInputTypeParam:get() end)
        if not okVal or requested ~= Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD then
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

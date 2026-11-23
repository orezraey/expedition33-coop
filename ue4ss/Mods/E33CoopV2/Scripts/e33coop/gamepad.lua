-- Click-safe CommonUI Gamepad mode keeper & multi-controller hardware cursor suppressor.
--
-- Why this exists (two related CommonUI + multi-LocalPlayer bugs in UE5.4):
--   1. Non-primary player (P2/P3) on PC0: CommonUI's C++ FCommonInputPreprocessor calls
--      UCommonInputSubsystem::SetCurrentInputType(MouseAndKeyboard) directly in C++ (bypassing
--      UObject::ProcessEvent), causing keyboard icons to appear and blocking CommonUI Confirm
--      actions in dialogues and fullscreen notifications. Blindly forcing Gamepad every tick
--      cancels held menu buttons before HandleButtonClicked fires.
--   2. Center-screen blinking mouse cursor (e.g. resting at an Expedition Flag for 2-3s):
--      The game unconditionally sets PC0.bShowMouseCursor = true on menus and relies on CommonUI's
--      FCommonAnalogCursor to hide/center the cursor in Gamepad mode, while extra CoopControllers
--      (PC1/PC2) sit in MouseAndKeyboard (0) on the same shared viewport.
--
-- Solution:
--   - Track live held buttons by UObject key (with GC/timeout self-healing + Clicked/Released
--     cleanup so a destroyed widget can never leave held state stuck).
--   - Run a lightweight click-safe check in ReceiveTick: while PC0 belongs to a non-primary user
--     and NO button is held, immediately restore CommonInputSubsystem to Gamepad (1) on the same
--     frame C++ drops it — eliminating keyboard icon flicker and keeping dialogue Confirm working
--     100% reliably without ever canceling menu clicks!
--   - Keep extra CoopControllers (PC1/PC2) locked to Gamepad (1) with hardware cursor hidden,
--     and suppress PC0.bShowMouseCursor whenever PC0 is in Gamepad mode (preserving P1 M&K).

local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local Gamepad = {}

local CURSOR_NONE = 0    -- EMouseCursor::None
local CURSOR_DEFAULT = 1 -- EMouseCursor::Default
local HELD_TIMEOUT_SEC = 1.5

function Gamepad.new(ue, clockFn)
    local nowFn = clockFn or os.clock

    local self = {
        -- Map of [buttonKey] = { obj = buttonObj, pressedAt = number }
        heldButtons = {},
        deferredRestore = false,
        -- Tracks whether the currently active game UI originally requested a cursor (for M&K fallback)
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

    local function buttonKey(btnObj)
        if not btnObj then
            return "unknown"
        end
        local ok, addr = pcall(function() return btnObj:GetAddress() end)
        if ok and addr ~= nil then
            return addr
        end
        return tostring(btnObj)
    end

    local function hasHeldButton()
        local now = nowFn()
        local anyHeld = false
        for k, entry in pairs(self.heldButtons) do
            local stale = (now - entry.pressedAt) > HELD_TIMEOUT_SEC
            local invalid = entry.obj ~= nil and not ue.isValid(entry.obj)
            if stale or invalid then
                self.heldButtons[k] = nil
            else
                anyHeld = true
            end
        end
        return anyHeld
    end

    local function isNonPrimaryOnPC0(pc0)
        pc0 = pc0 or ue.getPlayerController(0)
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

    local function setHardwareCursorVisible(pc, visible, cursorShape)
        if not ue.isValid(pc) then
            return
        end
        pcall(function()
            local desiredCursor = cursorShape ~= nil and cursorShape or (visible and CURSOR_DEFAULT or CURSOR_NONE)
            if pc.bShowMouseCursor ~= visible then
                pc.bShowMouseCursor = visible
            end
            if pc.CurrentMouseCursor ~= desiredCursor then
                pc.CurrentMouseCursor = desiredCursor
            end
        end)
    end

    local function isPC0UsingGamepad(pc0, nonPrimary)
        if nonPrimary then
            return true
        end
        local sub = ue.getCommonInputSubsystem(pc0)
        if not sub then
            return false
        end
        local okGet, curType = pcall(function() return sub:GetCurrentInputType() end)
        return okGet and curType == Roster.INPUT_TYPE_GAMEPAD
    end

    function self.resetButtonState()
        self.heldButtons = {}
        self.deferredRestore = false
    end

    -- Forces extra CoopControllers (PC1, PC2) into Gamepad mode with cursor hidden so they
    -- never sit in MouseAndKeyboard (0) and fight PC0's FCommonAnalogCursor on the shared viewport.
    function self.syncExtraControllersToGamepad(reason)
        for idx = 1, Roster.MAX_PARTY_SLOTS - 1 do
            local pc = ue.getPlayerController(idx)
            if pc then
                setHardwareCursorVisible(pc, false)
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

    -- Suppresses the blinking center-screen hardware cursor:
    --   - Extra CoopControllers (PC1/PC2) stay in Gamepad mode with cursor hidden.
    --   - Non-primary player (P2/P3) on PC0 always keeps hardware cursor hidden (None).
    --   - Primary player (P1) on PC0 keeps CurrentMouseCursor = Default and follows menuWantsCursor
    --     (hidden during SavePointRest / gameplay, visible in menus where CommonUI manages M&K vs Gamepad).
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
            setHardwareCursorVisible(pc0, false, CURSOR_NONE)
            Log.debug("Suppressed PC0 hardware cursor for non-primary user (%s)", tostring(reason))
        else
            setHardwareCursorVisible(pc0, self.menuWantsCursor, CURSOR_DEFAULT)
        end
    end

    function self.onMapReady()
        self.resetButtonState()
        self.menuWantsCursor = false
        self.syncExtraControllersToGamepad("map_ready")
        self.ensureGamepadIfSafe("map_ready")
        self.syncCursorVisibility("map_ready", false)
    end

    function self.ensureGamepadIfSafe(reason, pc0Override)
        local nonPrimary, pc0 = isNonPrimaryOnPC0(pc0Override)
        if not nonPrimary or not pc0 then
            self.deferredRestore = false
            return false
        end

        -- Even while a button is held, hiding PC0's hardware cursor is safe and doesn't fire OnInputMethodChanged
        setHardwareCursorVisible(pc0, false, CURSOR_NONE)

        if hasHeldButton() then
            self.deferredRestore = true
            Log.debug("Deferring CommonUI Gamepad restore (%s): button held", tostring(reason))
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

    -- Lightweight per-frame guard called from BP_jRPG_Controller_World::ReceiveTick.
    -- Catches direct C++ FCommonInputPreprocessor drops to MouseAndKeyboard on the same frame
    -- while strictly respecting held buttons so menu clicks are never canceled.
    function self.onTick(pc0)
        local nonPrimary, controller = isNonPrimaryOnPC0(pc0)
        if not controller or not nonPrimary then
            return
        end
        self.ensureGamepadIfSafe("tick", controller)
    end

    -- Called when entering a dialogue line/overlay: clear any stale held prompt button that opened it
    -- so Confirm works immediately on the very first line.
    function self.onDialoguePromptReady(reason)
        self.resetButtonState()
        self.syncExtraControllersToGamepad(reason)
        self.ensureGamepadIfSafe(reason)
    end

    function self.onButtonPressed(btnObj)
        local key = buttonKey(btnObj)
        self.heldButtons[key] = { obj = btnObj, pressedAt = nowFn() }
    end

    function self.onButtonReleased(btnObj)
        if btnObj ~= nil then
            self.heldButtons[buttonKey(btnObj)] = nil
        else
            self.heldButtons = {}
        end
        if not hasHeldButton() then
            if self.deferredRestore then
                self.ensureGamepadIfSafe("button_released_deferred")
            else
                self.ensureGamepadIfSafe("button_released")
            end
        end
    end

    function self.onButtonClicked(btnObj)
        if btnObj ~= nil then
            self.heldButtons[buttonKey(btnObj)] = nil
        end
        if not hasHeldButton() and self.deferredRestore then
            self.ensureGamepadIfSafe("button_clicked_deferred")
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
                    setHardwareCursorVisible(extraPc, false)
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

        if nonPrimary then
            setHardwareCursorVisible(pc0, false)
            if requested ~= Roster.INPUT_TYPE_MOUSE_AND_KEYBOARD then
                return
            end
            if hasHeldButton() then
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
            return
        end

        -- Player 1 (primary user) on PC0: leave input-type switches completely to CommonUI
    end

    return self
end

return Gamepad

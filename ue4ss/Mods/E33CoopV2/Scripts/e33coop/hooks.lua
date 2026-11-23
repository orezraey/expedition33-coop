-- Game-thread-only UE4SS hook manager.
--
-- Safety invariants (learned from E33CoopDiag deadlock debugging):
--   1. NEVER use LoopAsync, ExecuteInGameThread, or RegisterKeyBind (avoids Lua-lock deadlock).
--   2. NEVER call RegisterHook from inside a RegisterHook callback (UE4SS holds its script-hook lock).
--   3. Register native /Script/... hooks immediately; queue lazy /Game/... Blueprint hooks and
--      retry them from RegisterInitGameStatePostHook, RegisterLoadMapPostHook, and NotifyOnNewObject.
--
-- UE4SS v3.0.1 RegisterHook(path, callback, postCallback):
--   /Script/ paths: callback runs before the function, the optional postCallback after it.
--   /Game/ paths:   callback runs after the function; a third parameter does nothing.

local Log = require("e33coop.log")

local Hooks = {}

function Hooks.new()
    local self = {
        pending = {},
        -- every required (non-optional) Blueprint hook is registered
        requiredRegistered = false,
        allRegistered = false,
    }

    -- Register a native (/Script/...) hook immediately, with an optional post-callback.
    function self.registerNative(funcPath, preCallback, postCallback)
        local ok, err = pcall(function()
            if postCallback then
                RegisterHook(funcPath, preCallback or function() end, postCallback)
            else
                RegisterHook(funcPath, preCallback)
            end
        end)
        if ok then
            Log.info("Hooked native: %s", funcPath)
        else
            Log.warn("Failed to hook native %s: %s", funcPath, tostring(err))
        end
        return ok
    end

    -- Queue a Blueprint (/Game/...) hook to be registered as soon as its class is loaded.
    -- Optional hooks (menus and popups that may never load in a session) are only retried on map loads
    -- and when a CommonActivatableWidget is created, so a missing one never keeps the frequent
    -- UserWidget / ActorComponent watchers busy.
    function self.addBlueprint(funcPath, callback, optional)
        self.pending[#self.pending + 1] = {
            path = funcPath,
            callback = callback,
            optional = not not optional,
            done = false,
        }
        if not optional then
            self.requiredRegistered = false
        end
        self.allRegistered = false
    end

    -- Attempt to register still-pending Blueprint hooks (optional ones only when includeOptional).
    -- Safe to call from top-level startup, InitGameState, LoadMap, and NotifyOnNewObject.
    function self.tryRegisterPending(includeOptional)
        if self.allRegistered then
            return true
        end
        local missingRequired, missingOptional = 0, 0
        for _, entry in ipairs(self.pending) do
            if not entry.done and (includeOptional or not entry.optional) then
                if pcall(RegisterHook, entry.path, entry.callback) then
                    entry.done = true
                    Log.info("Hooked BP: %s", entry.path)
                end
            end
            if not entry.done then
                if entry.optional then
                    missingOptional = missingOptional + 1
                else
                    missingRequired = missingRequired + 1
                end
            end
        end
        if missingRequired == 0 and not self.requiredRegistered then
            self.requiredRegistered = true
            Log.info("All required Blueprint hooks registered (%d optional still pending)", missingOptional)
        end
        if missingRequired == 0 and missingOptional == 0 then
            self.allRegistered = true
            Log.info("All %d Blueprint hooks registered", #self.pending)
        end
        return self.allRegistered
    end

    function self.installLazyWatchers()
        local function retryAll()
            if not self.allRegistered then
                self.tryRegisterPending(true)
            end
        end
        -- NotifyOnNewObject fires for every new UserWidget / ActorComponent and v3.0.1 cannot unregister
        -- it: once the required hooks are in, this must cost nothing.
        local function retryOnNewObject()
            if not self.requiredRegistered then
                self.tryRegisterPending(false)
            end
        end

        self.tryRegisterPending(true)

        pcall(RegisterInitGameStatePostHook, retryAll)
        pcall(RegisterLoadMapPostHook, retryAll)
        pcall(NotifyOnNewObject, "/Script/Engine.PlayerController", retryOnNewObject)
        pcall(NotifyOnNewObject, "/Script/Engine.ActorComponent", retryOnNewObject)
        pcall(NotifyOnNewObject, "/Script/UMG.UserWidget", retryOnNewObject)
        -- menus, dialogues and popups are activatable widgets: rare enough to also retry optional hooks
        pcall(NotifyOnNewObject, "/Script/CommonUI.CommonActivatableWidget", retryAll)
    end

    return self
end

return Hooks

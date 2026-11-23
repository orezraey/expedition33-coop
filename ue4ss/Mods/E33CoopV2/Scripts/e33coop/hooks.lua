-- Game-thread-only UE4SS hook manager.
--
-- Safety invariants (learned from E33CoopDiag deadlock debugging):
--   1. NEVER use LoopAsync, ExecuteInGameThread, or RegisterKeyBind (avoids Lua-lock deadlock).
--   2. NEVER call RegisterHook from inside a RegisterHook callback (UE4SS holds its script-hook lock).
--   3. Register native /Script/... hooks immediately; queue lazy /Game/... Blueprint hooks and
--      retry them from RegisterInitGameStatePostHook, RegisterLoadMapPostHook, and NotifyOnNewObject.

local Log = require("e33coop.log")

local Hooks = {}

function Hooks.new()
    local self = {
        pending = {},
        allRegistered = false,
    }

    -- Register a native (/Script/...) hook immediately.
    -- In UE4SS v3.0.1, RegisterHook(name, preFn) runs post-hooks by returning a function from preFn.
    function self.registerNative(funcPath, preCallback, postCallback)
        local ok, err = pcall(function()
            if postCallback then
                RegisterHook(funcPath, function(...)
                    if preCallback then
                        preCallback(...)
                    end
                    return postCallback
                end)
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
    function self.addBlueprint(funcPath, callback, optional)
        self.pending[#self.pending + 1] = {
            path = funcPath,
            callback = callback,
            optional = not not optional,
            done = false,
        }
        self.allRegistered = false
    end

    -- Attempt to register any still-pending Blueprint hooks.
    -- Safe to call from top-level startup, InitGameState, LoadMap, and NotifyOnNewObject.
    function self.tryRegisterPending()
        if self.allRegistered then
            return true
        end
        local remaining = 0
        for _, entry in ipairs(self.pending) do
            if not entry.done then
                local ok = pcall(RegisterHook, entry.path, entry.callback)
                if ok then
                    entry.done = true
                    Log.info("Hooked BP: %s", entry.path)
                else
                    remaining = remaining + 1
                end
            end
        end
        if remaining == 0 then
            self.allRegistered = true
            Log.info("All %d Blueprint hooks registered", #self.pending)
        end
        return self.allRegistered
    end

    function self.installLazyWatchers()
        local function retry()
            if not self.allRegistered then
                self.tryRegisterPending()
            end
        end

        self.tryRegisterPending()

        pcall(RegisterInitGameStatePostHook, retry)
        pcall(RegisterLoadMapPostHook, retry)
        pcall(NotifyOnNewObject, "/Script/Engine.PlayerController", retry)
        pcall(NotifyOnNewObject, "/Script/Engine.ActorComponent", retry)
        pcall(NotifyOnNewObject, "/Script/UMG.UserWidget", retry)
        pcall(NotifyOnNewObject, "/Script/CommonUI.CommonActivatableWidget", retry)
    end

    return self
end

return Hooks

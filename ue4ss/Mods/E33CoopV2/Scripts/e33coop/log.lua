-- Structured logger for E33CoopV2 (writes to UE4SS.log).

local Log = {
    prefix = "[E33CoopV2]",
    debugEnabled = false,
}

local function formatSafe(fmt, ...)
    if select("#", ...) == 0 then
        return tostring(fmt)
    end
    local ok, msg = pcall(string.format, tostring(fmt), ...)
    if ok then
        return msg
    end
    return tostring(fmt) .. " (format error: " .. tostring(msg) .. ")"
end

function Log.setDebug(enabled)
    Log.debugEnabled = not not enabled
end

function Log.info(fmt, ...)
    print(Log.prefix .. " " .. formatSafe(fmt, ...) .. "\n")
end

function Log.warn(fmt, ...)
    print(Log.prefix .. " [WARN] " .. formatSafe(fmt, ...) .. "\n")
end

function Log.error(fmt, ...)
    print(Log.prefix .. " [ERROR] " .. formatSafe(fmt, ...) .. "\n")
end

function Log.debug(fmt, ...)
    if not Log.debugEnabled then
        return
    end
    print(Log.prefix .. " [DEBUG] " .. formatSafe(fmt, ...) .. "\n")
end

return Log

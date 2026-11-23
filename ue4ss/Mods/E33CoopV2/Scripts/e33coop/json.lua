-- Minimal, dependency-free JSON encoder/decoder for Lua 5.4.
-- Used to persist E33CoopV2 configuration cleanly on disk.

local Json = {}

local ESCAPE_MAP = {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local UNESCAPE_MAP = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
}

local function escapeString(str)
    return '"' .. str:gsub('[\\"\b\f\n\r\t%c]', function(ch)
        return ESCAPE_MAP[ch] or string.format("\\u%04x", string.byte(ch))
    end) .. '"'
end

local function isArray(tbl)
    local count = 0
    local maxIdx = 0
    for k in pairs(tbl) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            return false
        end
        count = count + 1
        if k > maxIdx then
            maxIdx = k
        end
    end
    return count > 0 and maxIdx == count
end

local function encodeValue(val, indent, depth)
    local t = type(val)
    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            error("Cannot encode non-finite number to JSON")
        end
        if math.type and math.type(val) == "integer" then
            return tostring(val)
        end
        return string.format("%.14g", val)
    elseif t == "string" then
        return escapeString(val)
    elseif t == "table" then
        local pad = indent and string.rep(" ", (depth + 1) * indent) or ""
        local closePad = indent and string.rep(" ", depth * indent) or ""
        local sep = indent and ",\n" or ","
        local colon = indent and ": " or ":"

        if isArray(val) then
            local parts = {}
            for i = 1, #val do
                parts[i] = pad .. encodeValue(val[i], indent, depth + 1)
            end
            if indent then
                return "[\n" .. table.concat(parts, sep) .. "\n" .. closePad .. "]"
            end
            return "[" .. table.concat(parts, sep) .. "]"
        end

        local keys = {}
        for k in pairs(val) do
            if type(k) ~= "string" then
                error("JSON object keys must be strings, got " .. type(k))
            end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        if #keys == 0 then
            return "{}"
        end

        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[i] = pad .. escapeString(k) .. colon .. encodeValue(val[k], indent, depth + 1)
        end
        if indent then
            return "{\n" .. table.concat(parts, sep) .. "\n" .. closePad .. "}"
        end
        return "{" .. table.concat(parts, sep) .. "}"
    end
    error("Unsupported JSON type: " .. t)
end

function Json.encode(val, indent)
    return encodeValue(val, indent or 2, 0)
end

local function skipWhitespace(str, pos)
    local _, nextPos = str:find("^[ \t\r\n]*", pos)
    return (nextPos or (pos - 1)) + 1
end

local parseValue

local function parseString(str, pos)
    pos = pos + 1 -- skip opening quote
    local out = {}
    local len = #str
    while pos <= len do
        local ch = str:sub(pos, pos)
        if ch == '"' then
            return table.concat(out), pos + 1
        elseif ch == "\\" then
            pos = pos + 1
            local esc = str:sub(pos, pos)
            local mapped = UNESCAPE_MAP[esc]
            if mapped then
                out[#out + 1] = mapped
                pos = pos + 1
            elseif esc == "u" then
                local hex = str:sub(pos + 1, pos + 4)
                local code = tonumber(hex, 16)
                if not code then
                    error("Invalid unicode escape at position " .. pos)
                end
                if utf8 and utf8.char then
                    out[#out + 1] = utf8.char(code)
                else
                    out[#out + 1] = code < 128 and string.char(code) or "?"
                end
                pos = pos + 5
            else
                error("Invalid escape '\\" .. esc .. "' at position " .. pos)
            end
        else
            out[#out + 1] = ch
            pos = pos + 1
        end
    end
    error("Unterminated JSON string")
end

local function parseNumber(str, pos)
    local numStr = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not numStr or #numStr == 0 then
        error("Invalid JSON number at position " .. pos)
    end
    local num = tonumber(numStr)
    if not num then
        error("Invalid JSON number '" .. numStr .. "' at position " .. pos)
    end
    return num, pos + #numStr
end

local function parseArray(str, pos)
    pos = skipWhitespace(str, pos + 1)
    local arr = {}
    if str:sub(pos, pos) == "]" then
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = parseValue(str, pos)
        arr[#arr + 1] = val
        pos = skipWhitespace(str, pos)
        local ch = str:sub(pos, pos)
        if ch == "]" then
            return arr, pos + 1
        elseif ch ~= "," then
            error("Expected ',' or ']' in JSON array at position " .. pos)
        end
        pos = skipWhitespace(str, pos + 1)
    end
end

local function parseObject(str, pos)
    pos = skipWhitespace(str, pos + 1)
    local obj = {}
    if str:sub(pos, pos) == "}" then
        return obj, pos + 1
    end
    while true do
        if str:sub(pos, pos) ~= '"' then
            error("Expected string key in JSON object at position " .. pos)
        end
        local key
        key, pos = parseString(str, pos)
        pos = skipWhitespace(str, pos)
        if str:sub(pos, pos) ~= ":" then
            error("Expected ':' in JSON object at position " .. pos)
        end
        pos = skipWhitespace(str, pos + 1)
        local val
        val, pos = parseValue(str, pos)
        obj[key] = val
        pos = skipWhitespace(str, pos)
        local ch = str:sub(pos, pos)
        if ch == "}" then
            return obj, pos + 1
        elseif ch ~= "," then
            error("Expected ',' or '}' in JSON object at position " .. pos)
        end
        pos = skipWhitespace(str, pos + 1)
    end
end

parseValue = function(str, pos)
    pos = skipWhitespace(str, pos)
    local ch = str:sub(pos, pos)
    if ch == '"' then
        return parseString(str, pos)
    elseif ch == "{" then
        return parseObject(str, pos)
    elseif ch == "[" then
        return parseArray(str, pos)
    elseif ch == "t" and str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif ch == "f" and str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif ch == "n" and str:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    elseif ch == "-" or (ch >= "0" and ch <= "9") then
        return parseNumber(str, pos)
    end
    error("Unexpected character '" .. ch .. "' in JSON at position " .. pos)
end

function Json.decode(str)
    if type(str) ~= "string" then
        return nil, "input is not a string"
    end
    local ok, result, nextPos = pcall(parseValue, str, 1)
    if not ok then
        return nil, result
    end
    nextPos = skipWhitespace(str, nextPos)
    if nextPos <= #str then
        return nil, "trailing characters at position " .. nextPos
    end
    return result, nil
end

return Json

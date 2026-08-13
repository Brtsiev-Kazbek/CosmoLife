-- Table <-> Lua source serialisation for save games.
--
-- Only plain data survives a round trip: numbers, strings, booleans, and
-- tables of those.  Functions, userdata and cycles are rejected loudly instead
-- of silently producing a broken save.

local serialize = {}

local fmt, rep, concat = string.format, string.rep, table.concat

local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

local function isIdentifier(s)
    return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil and not KEYWORDS[s]
end

local function encodeNumber(v)
    if v ~= v then return "0/0" end
    if v == math.huge then return "math.huge" end
    if v == -math.huge then return "-math.huge" end
    if v == math.floor(v) and math.abs(v) < 1e15 then return fmt("%d", v) end
    return fmt("%.17g", v)
end

local function encode(v, out, indent, seen)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = encodeNumber(v)
    elseif t == "string" then
        out[#out + 1] = fmt("%q", v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif t == "nil" then
        out[#out + 1] = "nil"
    elseif t == "table" then
        if seen[v] then error("serialize: cyclic reference in save data", 0) end
        seen[v] = true
        local pad = rep("  ", indent + 1)
        out[#out + 1] = "{\n"
        -- array part first, so saves stay readable and diffable
        local n = 0
        for i, item in ipairs(v) do
            out[#out + 1] = pad
            encode(item, out, indent + 1, seen)
            out[#out + 1] = ",\n"
            n = i
        end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return tostring(a) < tostring(b) end
            return type(a) < type(b)
        end)
        for _, k in ipairs(keys) do
            out[#out + 1] = pad
            if isIdentifier(k) then
                out[#out + 1] = k .. " = "
            else
                out[#out + 1] = "["
                encode(k, out, indent + 1, seen)
                out[#out + 1] = "] = "
            end
            encode(v[k], out, indent + 1, seen)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = rep("  ", indent) .. "}"
        seen[v] = nil
    else
        error("serialize: cannot serialise a " .. t, 0)
    end
end

--- Encodes a value as a chunk of Lua source ("return { ... }").
function serialize.encode(value)
    local out = { "return " }
    encode(value, out, 0, {})
    out[#out + 1] = "\n"
    return concat(out)
end

--- Decodes a chunk produced by `encode`.  Returns nil, err on failure.
function serialize.decode(text)
    if type(text) ~= "string" then return nil, "expected a string" end
    local chunk, err
    if setfenv then                       -- Lua 5.1 / LuaJIT
        chunk, err = loadstring(text, "savegame")
        if chunk then setfenv(chunk, { math = math }) end
    else                                  -- Lua 5.2+
        chunk, err = load(text, "savegame", "t", { math = math })
    end
    if not chunk then return nil, err end
    local ok, result = pcall(chunk)
    if not ok then return nil, result end
    return result
end

return serialize

-- Undefined-global lint.
--
--     luajit tools/lint_globals.lua
--
-- Lua has no compile-time error for `cos(a)`: an undeclared name is a read of
-- a global that happens to be nil, and it only blows up on the frame that
-- executes it. That is exactly how `Flight:submitCanisters` shipped calling a
-- global `cos` -- the function returns early unless loose cargo is in the
-- world, so 6869 head-less checks and 52 rendered steps all passed while the
-- game crashed the moment a wreck spilled anything.
--
-- Coverage is the wrong tool for that: a renderer has too many branches that
-- only run in one situation. So this reads the compiled bytecode instead.
-- Every global *read* in a chunk shows up as a GGET instruction naming it, and
-- every global *write* as GSET, whether or not the line ever runs. Anything
-- not in ALLOWED below is either a typo or a missing local.
--
-- Returns a module when required, so tests/run.lua can run the same scan.

package.path = "./?.lua;./?/init.lua;" .. package.path

local lint = {}

-- Standard Lua 5.1 / LuaJIT globals, plus the one LOVE provides.
local ALLOWED = {}
for name in ([[
    _G _VERSION arg assert collectgarbage coroutine debug dofile error getfenv
    getmetatable io ipairs jit load loadfile loadstring math module newproxy
    next os package pairs pcall print rawequal rawget rawlen rawset require
    select setfenv setmetatable string table tonumber tostring type unpack
    xpcall love
]]):gmatch("%S+") do ALLOWED[name] = true end

lint.ALLOWED = ALLOWED

local DIRS = { "src", "tests", "tools" }
local FILES = { "main.lua", "conf.lua" }

--- Every .lua file the project ships, as repository-relative paths.
function lint.sources()
    local out = {}
    for _, f in ipairs(FILES) do
        local fh = io.open(f, "r")
        if fh then fh:close() out[#out + 1] = f end
    end
    for _, dir in ipairs(DIRS) do
        local p = io.popen('find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null')
        if p then
            for line in p:lines() do out[#out + 1] = line end
            p:close()
        end
    end
    table.sort(out)
    return out
end

-- jit.bc writes to a file-like object; collect the listing in memory instead.
local function bytecodeOf(fn)
    local buf = {}
    local sink = {
        write = function(_, ...)
            for i = 1, select("#", ...) do buf[#buf + 1] = tostring((select(i, ...))) end
        end,
        flush = function() end,
        close = function() end,
    }
    require("jit.bc").dump(fn, sink, true)     -- true: nested prototypes too
    return table.concat(buf)
end

--- Globals touched by one file: { {name = , mode = "read"|"write"}, ... }
function lint.globalsIn(path)
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    local listing = bytecodeOf(chunk)
    local found, seen = {}, {}
    for op, name in listing:gmatch('(G[GS]ET)%s+%d+%s+%d+%s*;%s*"([^"]+)"') do
        local mode = (op == "GGET") and "read" or "write"
        local key = name .. mode
        if not seen[key] then
            seen[key] = true
            found[#found + 1] = { name = name, mode = mode }
        end
    end
    return found
end

--- Offences across the whole project: { {file = , name = , mode = }, ... }
function lint.scan()
    local bad = {}
    for _, path in ipairs(lint.sources()) do
        local globals, err = lint.globalsIn(path)
        if not globals then
            bad[#bad + 1] = { file = path, name = tostring(err), mode = "syntax" }
        else
            for _, g in ipairs(globals) do
                -- a write to a global is a leak even when the name is a real
                -- one, so only reads are allowed to match the list
                if g.mode == "write" or not ALLOWED[g.name] then
                    bad[#bad + 1] = { file = path, name = g.name, mode = g.mode }
                end
            end
        end
    end
    return bad
end

if arg and arg[0] and arg[0]:find("lint_globals%.lua$") then
    local bad = lint.scan()
    for _, b in ipairs(bad) do
        io.write(string.format("%s: %s global '%s'\n", b.file, b.mode, b.name))
    end
    local files = #lint.sources()
    io.write(string.format("%d files scanned, %d offences\n", files, #bad))
    os.exit(#bad > 0 and 1 or 0)
end

return lint

-- A Lua 5.1-compatible lexer for the runtime subset of Luau.
local M = {}
local keywords = {}
for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%S+") do keywords[word] = true end

local function decimalnumber(text)
    local value = tonumber(text)
    if value ~= nil then return value + 0.0 end
    -- An embedding Lua application may have selected a comma-decimal locale.
    -- Use its native conversion for correct rounding without changing its locale.
    local marker = string.format("%.1f", 0.5):match("^0(.-)5$")
    if marker and marker ~= "." then
        value = tonumber((text:gsub("%.", function() return marker end)))
        if value ~= nil then return value + 0.0 end
    end
end

local function basednumber(text, base)
    -- Luau converts integer-base literals through an unsigned 64-bit value,
    -- saturating on overflow. Lua 5.4's tonumber(text, base) can wrap a signed
    -- integer. Two exact 32-bit limbs avoid that and round to double only once.
    local high, low = 0.0, 0.0
    local radix, maximum = 4294967296.0, 4294967295.0
    for digit in text:gmatch("[^_]") do
        local value = tonumber(digit, base)
        if value == nil then return nil end
        local product = low * base + value
        low = product % radix
        high = high * base + math.floor(product / radix)
        if high >= radix then return maximum * radix + maximum end
    end
    return high * radix + low
end

local function utf8char(n)
    if n < 0 or n > 1114111 or (n >= 55296 and n <= 57343) then return nil end
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64) end
    if n < 65536 then return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64) end
    return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64, 128 + math.floor(n / 64) % 64, 128 + n % 64)
end

function M.lex(source, chunkname, initialLine)
    assert(type(source) == "string", "source must be a string")
    local tokens, pos, line, len = {}, 1, initialLine or 1, #source
    local lineStart = 1
    chunkname = chunkname or "input"
    local function fail(message, atline)
        error(chunkname .. ":" .. (atline or line) .. ":" .. (pos - lineStart + 1) .. ": " .. message, 0)
    end
    local function advance(to)
        if to == pos + 1 and source:byte(pos) ~= 10 and source:byte(pos) ~= 13 then pos = to; return end
        local text = source:sub(pos, to - 1)
        local lastNewline = text:match(".*()[\r\n]")
        if lastNewline then lineStart = pos + lastNewline end
        -- CRLF is one newline; a bare CR is also a newline.
        text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
        local _, n = text:gsub("\n", "")
        line, pos = line + n, to
    end
    local function add(kind, value, start, startline, startcolumn)
        tokens[#tokens + 1] = {kind=kind, value=value, raw=source:sub(start, pos - 1), line=startline, column=startcolumn}
    end
    local function longbracket(at)
        return source:match("^%[(=*)%[", at)
    end
    local function readlong(start, startline)
        local eq = longbracket(start)
        local first = start + #eq + 2
        local close = "]" .. eq .. "]"
        local finish = source:find(close, first, true)
        if not finish then fail("unfinished long string or comment", startline) end
        local value = source:sub(first, finish - 1):gsub("\r\n", "\n"):gsub("\r", "\n")
        if value:sub(1, 1) == "\n" then value = value:sub(2) end
        advance(finish + #close)
        return value
    end
    local function readescape(interpolated)
        advance(pos + 1)
        local c = source:sub(pos, pos)
        local escapes = {a="\a", b="\b", f="\f", n="\n", r="\r", t="\t", v="\v", ["\\"]="\\", ['"']='"', ["'"]="'"}
        if escapes[c] or (interpolated and (c == "`" or c == "{" or c == "}")) then
            local value = escapes[c] or c; advance(pos + 1); return value
        elseif c == "\n" or c == "\r" then
            advance(pos + ((c == "\r" and source:sub(pos + 1, pos + 1) == "\n") and 2 or 1)); return "\n"
        elseif c == "z" then
            advance(pos + 1)
            local whitespace = source:match("^%s*", pos)
            advance(pos + #whitespace); return ""
        elseif c == "x" then
            local hex = source:sub(pos + 1, pos + 2)
            if not hex:match("^%x%x$") then fail("expected two hexadecimal digits after \\x") end
            advance(pos + 3); return string.char(tonumber(hex, 16))
        elseif c == "u" then
            local hex = source:match("^u{(%x+)}", pos)
            if not hex then fail("invalid Unicode escape") end
            local encoded = utf8char(basednumber(hex, 16))
            if not encoded then fail("invalid Unicode codepoint") end
            advance(pos + #hex + 3); return encoded
        elseif c:match("%d") then
            local digits = source:match("^%d%d?%d?", pos)
            local byte = tonumber(digits)
            if byte > 255 then fail("decimal escape exceeds 255") end
            advance(pos + #digits); return string.char(byte)
        else fail("invalid string escape \\" .. c) end
    end
    local function readstring(quote, start, startline)
        local out = {}
        advance(pos + 1)
        while pos <= len do
            local c = source:sub(pos, pos)
            if c == quote then advance(pos + 1); return table.concat(out) end
            if c == "\n" or c == "\r" then fail("unfinished string", startline) end
            if c == "\\" then out[#out + 1] = readescape(false)
            else out[#out + 1] = c; advance(pos + 1) end
        end
        fail("unfinished string", startline)
    end
    local readinterp
    local function interpolationexpression(startline)
        local first, depth = pos, 1
        while pos <= len do
            local c = source:sub(pos, pos)
            if c == "'" or c == '"' then readstring(c, pos, line)
            elseif c == "[" and longbracket(pos) then readlong(pos, line)
            elseif c == "`" then readinterp(pos, line)
            elseif source:sub(pos, pos + 1) == "--" then
                advance(pos + 2)
                if longbracket(pos) then readlong(pos, line)
                else advance(source:find("[\r\n]", pos) or (len + 1)) end
            elseif c == "{" then depth = depth + 1; advance(pos + 1)
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    local text = source:sub(first, pos - 1)
                    advance(pos + 1)
                    return {kind="expression", source=text, line=startline}
                end
                advance(pos + 1)
            elseif c == "\r" and source:sub(pos + 1, pos + 1) == "\n" then advance(pos + 2)
            else advance(pos + 1) end
        end
        fail("unfinished interpolation expression", startline)
    end
    readinterp = function(start, startline)
        local parts, text = {}, {}
        local textline = startline
        local function flush()
            -- Retain empty literal parts: compiler can distinguish interpolation
            -- expressions yielding strings from actual string literal segments.
            parts[#parts + 1] = {kind="text", value=table.concat(text), line=textline}
            text = {}
        end
        advance(pos + 1)
        while pos <= len do
            local c = source:sub(pos, pos)
            if c == "`" then flush(); advance(pos + 1); return parts
            elseif c == "\n" or c == "\r" then fail("unfinished interpolated string", startline)
            elseif c == "\\" then text[#text + 1] = readescape(true)
            elseif c == "{" then
                if source:sub(pos + 1, pos + 1) == "{" then fail("double braces in interpolation; escape a literal brace with \\{") end
                flush(); advance(pos + 1)
                parts[#parts + 1] = interpolationexpression(line)
                textline = line
            else text[#text + 1] = c; advance(pos + 1) end
        end
        fail("unfinished interpolated string", startline)
    end
    -- Accept UTF-8 BOM and the conventional first-line interpreter directive.
    if source:sub(1, 3) == "\239\187\191" then pos = 4 end
    if source:sub(pos, pos + 1) == "#!" then advance((source:find("[\r\n]", pos) or (len + 1))) end
    while pos <= len do
        local start, startline, startcolumn = pos, line, pos - lineStart + 1
        local c = source:sub(pos, pos)
        if c:match("%s") then advance(pos + #source:match("^%s+", pos))
        elseif source:sub(pos, pos + 1) == "--" then
            advance(pos + 2)
            if longbracket(pos) then readlong(pos, startline)
            else advance(source:find("[\r\n]", pos) or (len + 1)) end
        elseif c == "'" or c == '"' then local value = readstring(c, start, startline); add("string", value, start, startline, startcolumn)
        elseif c == "[" and longbracket(pos) then local value = readlong(pos, startline); add("string", value, start, startline, startcolumn)
        elseif c == "`" then local value = readinterp(start, startline); add("interp", value, start, startline, startcolumn)
        elseif c:match("[%a_]") then
            local word = source:match("^[%a_][%w_]*", pos)
            advance(pos + #word); add(keywords[word] and word or "name", word, start, startline, startcolumn)
        elseif c:match("%d") or (c == "." and source:sub(pos + 1, pos + 1):match("%d")) then
            local raw, value = nil, nil
            if source:match("^0[xX]", pos) then
                raw = source:match("^0[xX][%x_]+", pos)
                if not raw then fail("malformed hexadecimal literal") end
                local clean = raw:gsub("_", "")
                if #clean <= 2 then fail("malformed hexadecimal literal: expected a digit") end
                value = basednumber(clean:sub(3), 16)
            elseif source:match("^0[bB]", pos) then
                raw = source:match("^0[bB][01_]+", pos)
                if not raw then fail("malformed binary literal") end
                local clean = raw:gsub("_", "")
                if #clean <= 2 then fail("malformed binary literal: expected a digit") end
                value = basednumber(clean:sub(3), 2)
            else
                raw = source:match("^%d[%d_]*", pos) or source:match("^%.[%d_]+", pos)
                local after = pos + #raw
                if source:sub(after, after) == "." and source:sub(after + 1, after + 1) ~= "." then
                    raw = raw .. (source:match("^%.[%d_]*", after) or "")
                end
                after = pos + #raw
                if source:match("^[eE]", after) then
                    local exponent = source:match("^[eE][+-]?[%d_]+", after)
                    if not exponent then fail("malformed exponent") end
                    raw = raw .. exponent
                end
                value = decimalnumber((raw:gsub("_", "")))
            end
            if not value then fail("malformed numeric literal") end
            if source:sub(pos + #raw, pos + #raw):match("[%w_]") then fail("malformed numeric literal") end
            advance(pos + #raw); add("number", value, start, startline, startcolumn)
        else
            local three, two = source:sub(pos, pos + 2), source:sub(pos, pos + 1)
            local operators3 = {["..."]=true,["..="]=true,["//="]=true}
            local operators2 = {["=="]=true,["~="]=true,["<="]=true,[">="]=true,[".."]=true,["//"]=true,["::"]=true,["->"]=true,["+="]=true,["-="]=true,["*="]=true,["/="]=true,["%="]=true,["^="]=true}
            local symbol = operators3[three] and three or (operators2[two] and two or c)
            if #symbol == 1 and not c:find("[%+%-%*/%%%^#=<>;:,%.%(%){%}%[%]%?%|&@]") then fail("unexpected character '" .. c .. "'") end
            advance(pos + #symbol); add(symbol, symbol, start, startline, startcolumn)
        end
    end
    tokens[#tokens + 1] = {kind="eof", value="<eof>", raw="", line=line, column=pos - lineStart + 1}
    return tokens
end

return M

local lexer = require('src.lexer')
local util = require('src.util')
local M = {}

local privateFields = {
    constants=true,upvalues=true,params=true,children=true,slots=true,
    registers=true,vararg=true,kind=true,index=true,count=true,offset=true,id=true,
}
local alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local reserved = {}
for word in ('and break do else elseif end false for function if in local nil not or repeat return then true until while continue const type export read write declare class native checked deprecated buffer bit32 math string table utf8 coroutine debug io os game workspace script task Enum require assert error ipairs pairs next pcall xpcall getfenv setfenv select tonumber tostring type typeof unpack newproxy loadstring print warn rawget rawset rawequal rawlen getmetatable setmetatable collectgarbage gcinfo settings UserSettings shared _G _VERSION'):gmatch('%S+') do
    reserved[word] = true
end

local function operatorPairNeedsSpace(left, right, cache)
    local key = left .. '\0' .. right
    if cache[key] ~= nil then return cache[key] end
    local ok, joined = pcall(lexer.lex, left .. right, '<minifier boundary>')
    local separated = not ok or #joined ~= 3 or joined[1].raw ~= left or joined[2].raw ~= right
    cache[key] = separated
    return separated
end

local function reserveInterpolationNames(tokens, used, fixed, fields)
    for _, token in ipairs(tokens) do
        if token.kind == 'interp' then
            for _, part in ipairs(token.value) do
                if part.kind == 'expression' then
                    local nested = lexer.lex(part.source, '<interpolation>', part.line)
                    for _, inner in ipairs(nested) do
                        if inner.kind == 'name' then used[inner.value], fixed[inner.value] = true, true end
                        if inner.kind == 'string' and (fields[inner.value] or inner.value:match('^__ovm_')) then
                            used[inner.value],fixed[inner.value] = true,true
                        end
                    end
                    reserveInterpolationNames(nested, used, fixed, fields)
                end
            end
        end
    end
end

local function newNames(rng, used)
    local width = 2
    return function()
        local attempts = 0
        while true do
            local chars = {}
            for i=1,width do
                local index = rng:int(1,#alphabet)
                chars[i] = alphabet:sub(index,index)
            end
            local value = table.concat(chars)
            if not used[value] then used[value] = true; return value end
            attempts = attempts + 1
            if attempts == 64 and width < 4 then width = width + 1; attempts = 0 end
        end
    end
end

local function literal(token)
    return token.kind == 'name' or token.kind == 'number' or token.kind == 'string' or token.kind == 'interp'
end

function M.compact(source, options)
    assert(type(source) == 'string', 'source must be a string')
    options = options or {}
    local tokens = lexer.lex(source, options.chunkname or '<generated VM>')
    local names, used, fixed = {}, {}, {}
    -- Reuse field aliases across the native helpers and the source that will
    -- be VM packed. Their private tables cross this boundary at runtime.
    for name,value in pairs(options.names or {}) do
        assert(type(name)=='string' and type(value)=='string' and value:match('^[%a_][%w_]*$')
            and not reserved[value] and not used[value],'invalid shared minifier alias')
        names[name],used[value]=value,true
    end
    local fields = options.privateFields or privateFields
    for name in pairs(reserved) do used[name] = true end
    for _, token in ipairs(tokens) do if token.kind == 'name' then used[token.value] = true end end
    reserveInterpolationNames(tokens, used, fixed, fields)
    local rename = options.rename ~= false
    local rng = options.rng or util.rng(1)
    assert(not rename or (type(rng) == 'table' and type(rng.int) == 'function'), 'renaming requires rng:int(lo,hi)')
    local generate = rename and newNames(rng,used)
    local output, previous, previousRaw, bracketEquals = {}, nil, nil, false
    local cache, spaces, renamed, count = {}, 0, 0, 0
    for _, token in ipairs(tokens) do
        if token.kind ~= 'eof' then
            local raw = token.raw
            if rename and token.kind == 'name' and not fixed[token.value] and ((not options.fieldsOnly and token.value:match('^__ovm_')) or fields[token.value]) then
                if not names[token.value] then names[token.value] = generate(); renamed = renamed + 1 end
                raw = names[token.value]
            end
            local space = false
            if previous then
                local ending, beginning = previousRaw:sub(-1), raw:sub(1,1)
                if ending:match('[%w_]') and beginning:match('[%w_]') then
                    space = true
                elseif previous.kind == 'number' and beginning == '.' then
                    -- Luau rejects 1..2 as a malformed number even though the
                    -- portable lexer can split it into a number and concat.
                    space = true
                elseif previousRaw == '.' and token.kind == 'number' then space = true
                elseif ending == '-' and beginning == '-' then space = true
                elseif ending == '.' and beginning == '.' then space = operatorPairNeedsSpace(previousRaw,raw,cache)
                elseif bracketEquals and beginning == '[' then space = true
                elseif not literal(previous) and not literal(token) then
                    space = operatorPairNeedsSpace(previousRaw,raw,cache)
                end
            end
            if space then output[#output+1] = ' '; spaces = spaces + 1; bracketEquals = false end
            output[#output+1] = raw
            if raw == '[' then bracketEquals = true
            elseif not (bracketEquals and raw:match('^=+$')) then bracketEquals = false end
            previous, previousRaw = token, raw
            count = count + 1
        end
    end
    local result = table.concat(output)
    return result, {names=names,renamed=renamed,spaces=spaces,tokens=count,inputBytes=#source,outputBytes=#result}
end

return M

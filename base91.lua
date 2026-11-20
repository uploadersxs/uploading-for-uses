local util = require('src.util')
local M = {}

local function checkedAlphabet(alphabet)
    assert(type(alphabet) == 'string' and #alphabet == 91,
        'base91: alphabet must contain exactly 91 bytes')
    local indices = {}
    for i=1,91 do
        local character = alphabet:sub(i,i)
        assert(indices[character] == nil, 'base91: alphabet contains a duplicate byte at position '..i)
        indices[character] = i-1
    end
    return indices
end

function M.alphabet(seed)
    local rng = util.rng(util.seed(seed))
    local characters = {}
    for code=33,126 do
        if code ~= 34 and code ~= 39 and code ~= 92 then
            characters[#characters+1] = string.char(code)
        end
    end
    -- Initial order and the exact RNG consumption are shared with the runtime.
    for i=91,2,-1 do
        local j = rng:int(1,i)
        characters[i],characters[j] = characters[j],characters[i]
    end
    return table.concat(characters)
end

function M.encode(binary, alphabet)
    assert(type(binary) == 'string', 'base91: input must be a binary string')
    checkedAlphabet(alphabet)
    local output, queue, bits = {}, 0, 0
    for i=1,#binary do
        queue = queue + binary:byte(i) * 2^bits
        bits = bits + 8
        if bits > 13 then
            local value = queue % 8192
            if value > 88 then
                queue = math.floor(queue / 8192)
                bits = bits - 13
            else
                value = queue % 16384
                queue = math.floor(queue / 16384)
                bits = bits - 14
            end
            local first, second = value % 91 + 1, math.floor(value / 91) + 1
            output[#output+1] = alphabet:sub(first,first)
            output[#output+1] = alphabet:sub(second,second)
        end
    end
    if bits > 0 then
        local first = queue % 91 + 1
        output[#output+1] = alphabet:sub(first,first)
        if bits > 7 or queue > 90 then
            local second = math.floor(queue / 91) + 1
            output[#output+1] = alphabet:sub(second,second)
        end
    end
    return table.concat(output)
end

function M.decode(text, alphabet)
    assert(type(text) == 'string', 'base91: encoded input must be a string')
    local indices = checkedAlphabet(alphabet)
    local output, queue, bits, pending = {}, 0, 0, nil
    for i=1,#text do
        local value = indices[text:sub(i,i)]
        assert(value ~= nil, 'base91: invalid character at byte '..i)
        if pending == nil then pending = value
        else
            value = pending + value * 91
            queue = queue + value * 2^bits
            bits = bits + (value % 8192 > 88 and 13 or 14)
            while bits > 7 do
                output[#output+1] = string.char(queue % 256)
                queue = math.floor(queue / 256)
                bits = bits - 8
            end
            pending = nil
        end
    end
    if pending ~= nil then
        output[#output+1] = string.char((queue + pending * 2^bits) % 256)
    end
    local binary = table.concat(output)
    -- Reject ignored tail bits and truncated/noncanonical spellings, rather
    -- than silently returning a plausible but corrupted host-side payload.
    assert(M.encode(binary,alphabet) == text, 'base91: invalid or truncated encoded text')
    return binary
end

return M

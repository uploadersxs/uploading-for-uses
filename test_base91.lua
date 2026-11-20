package.path='./?.lua;'..package.path
local base91 = require('src.base91')
local util = require('src.util')

local standard = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()*+,./:;<=>?@[]^_`{|}~"'
assert(#standard == 91)
assert(base91.encode('',standard) == '' and base91.decode('',standard) == '')
assert(base91.encode('test',standard) == 'fPNKd')
assert(base91.encode('Hello World!',standard) == '>OwJh>Io0Tv!8PE')
assert(base91.decode('>OwJh>Io0Tv!8PE',standard) == 'Hello World!')

local function roundtrip(binary, alphabet)
    local encoded = base91.encode(binary,alphabet)
    assert(base91.decode(encoded,alphabet) == binary, 'roundtrip mismatch at '..#binary..' bytes')
    for i=1,#encoded do assert(alphabet:find(encoded:sub(i,i),1,true), 'encoded character outside alphabet') end
end

local bytes = {}
for i=0,255 do bytes[#bytes+1] = string.char(i) end
local allBytes = table.concat(bytes)
for _,seed in ipairs({1,2,12345,2147483646}) do
    local alphabet = base91.alphabet(seed)
    assert(#alphabet == 91 and alphabet == base91.alphabet(seed), 'alphabet must be reproducible')
    local seen = {}
    for i=1,91 do
        local byte = alphabet:byte(i)
        assert(byte>=33 and byte<=126 and byte~=34 and byte~=39 and byte~=92 and not seen[byte])
        seen[byte] = true
    end
    roundtrip(allBytes,alphabet)
    for size=0,128 do
        roundtrip(string.rep('\0',size),alphabet)
        roundtrip(string.rep('\255',size),alphabet)
        roundtrip(allBytes:sub(1,size),alphabet)
    end
    roundtrip(string.rep('\0\255Luau\128',8192),alphabet)
    local rng, random = util.rng(seed), {}
    for i=1,4096 do random[i] = string.char(rng:int(0,255)) end
    roundtrip(table.concat(random),alphabet)
end
assert(base91.alphabet(1) ~= base91.alphabet(2), 'different seeds must diversify alphabet')
-- Codec accepts any 91 distinct byte characters, independently of the generated
-- alphabet's printable/no-escape policy.
roundtrip(allBytes,allBytes:sub(1,91))

local function rejects(fn, pattern)
    local ok,err = pcall(fn)
    assert(not ok and tostring(err):find(pattern,1,true), 'expected error: '..pattern)
end
rejects(function() base91.encode('',string.rep('A',91)) end,'duplicate')
rejects(function() base91.decode('',standard:sub(1,90)) end,'exactly 91')
rejects(function() base91.decode('\0',standard) end,'invalid character')
rejects(function() base91.decode('A',standard) end,'truncated')
rejects(function() base91.decode('B',standard) end,'truncated')
rejects(function() base91.encode(false,standard) end,'binary string')
rejects(function() base91.decode(false,standard) end,'must be a string')
for _,seed in ipairs({0,-1,2147483647,0.5,'invalid'}) do
    rejects(function() base91.alphabet(seed) end,'seed must be an integer')
end
print('Base91 host checks OK')

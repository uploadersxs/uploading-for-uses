package.path='./?.lua;'..package.path
local minify = require('src.minify')
local lexer = require('src.lexer')
local util = require('src.util')

local function sameTokens(source, compact)
    local before, after = lexer.lex(source), lexer.lex(compact)
    assert(#before == #after, 'token count changed')
    for i,token in ipairs(before) do
        assert(token.kind == after[i].kind and token.raw == after[i].raw,
            'token changed at '..i..': '..token.raw..' / '..after[i].raw)
    end
end

local boundaries = {
    'return 1 .. 2', 'return 1 .. .2', 'return 1. .. 2',
    'return 1 - - 2', 'return not not true', 'local a = 1 e = 2',
    'local function f(...) return ... .. "x" end return f("v")',
    'x + = y', 'x / / y', 'x : : y', 'x < = y', 'x . . y',
    '[ = [', '[ == [', '[ == == = [', '[ [=[text]=] ]',
    'local e = 1 local x = 2 return e + x',
    'local t = { [ [==[key]==] ] = [=[value]=] } return t',
    'local x = 0x10 local y = 0b10 local z = 1e2 return x+y+z',
    'local f = function() return "x" end return f "argument"',
    'return `{ "}" }:{`nested {2}`}`',
    'local __ovm_x=1 return `{__ovm_x}`',
}
for _,source in ipairs(boundaries) do
    sameTokens(source,minify.compact(source,{rename=false}))
end
local operators={'+','-','*','/','//','%','^','#','..','...','=','==','~=','<','<=','>','>=',':','::','[',']','(',')','{','}',',',';','?','|','&','@','+=','-=','*=','/=','//=','%=','^=','..='}
for _,left in ipairs(operators) do
    for _,right in ipairs(operators) do
        local source = 'a '..left..' '..right..' z'
        sameTokens(source,minify.compact(source,{rename=false}))
    end
end
assert(minify.compact('local x = 1 ; return x + 2',{rename=false}) == 'local x=1;return x+2')
assert(minify.compact('return 1 .. 2',{rename=false}) == 'return 1 ..2')
assert(minify.compact('return 1 - - 2',{rename=false}) == 'return 1- -2')
assert(minify.compact('return "x"',{rename=false}) == 'return"x"')
assert(minify.compact('return ... .. "x"',{rename=false}) == 'return....."x"')

local private = 'local __ovm_a={n=1,constants=2}; local __ovm_b=__ovm_a.constants; return __ovm_b,__ovm_a.n'
local first, stats = minify.compact(private,{rng=util.rng(12345)})
local second = minify.compact(private,{rng=util.rng(12345)})
local third = minify.compact(private,{rng=util.rng(12346)})
assert(first == second and first ~= third, 'seeded names must be reproducible and diverse')
assert(stats.renamed == 3 and not first:find('__ovm_',1,true))
assert(first:find('.n',1,true), 'native pack count field must remain n')
for _,name in pairs(stats.names) do assert(name:match('^[a-zA-Z][a-zA-Z]+$') and #name>=2 and #name<=4) end
local evaluate = loadstring or load
local a,b = assert(evaluate(first))()
assert(a == 2 and b == 1, 'renaming must preserve metadata and native pack fields')
local occupied = stats.names.__ovm_a
local collision = 'local '..occupied..'=1; local __ovm_a=2; return '..occupied..',__ovm_a'
local collisionOut,collisionStats = minify.compact(collision,{rng=util.rng(12345)})
assert(collisionStats.names.__ovm_a ~= occupied, 'generated name collided with an existing local')
local c,d = assert(evaluate(collisionOut))()
assert(c == 1 and d == 2)
local interpolation = 'local __ovm_x=1; local __ovm_y=2; return `{__ovm_x}:{`nested {__ovm_y}`}`'
local stable = minify.compact(interpolation,{rng=util.rng(3)})
assert(stable:find('__ovm_x',1,true) and stable:find('__ovm_y',1,true), 'opaque interpolation references must keep their names')
sameTokens(interpolation,stable)
local indexedInterpolation = 'local __ovm_p={constants=7}; return `{__ovm_p["constants"]}`'
sameTokens(indexedInterpolation,minify.compact(indexedInterpolation,{rng=util.rng(3)}))

for _,name in ipairs({'core','loops','luau','interpolation','types','minify'}) do
    local source = util.read('tests/fixtures/'..name..'.luau')
    sameTokens(source,minify.compact(source,{rename=false}))
end
local fixture = util.read('tests/fixtures/minify.luau')
util.write('tests/.generated/minify_compact.luau',minify.compact(fixture,{rename=false}))
local bytes = {}
for i=0,255 do bytes[#bytes+1] = string.format('\\%03d',i) end
local packed = 'local __ovm_bytes = buffer.fromstring("'..table.concat(bytes)..'"); local __ovm_offset = 0; return buffer.readu8(__ovm_bytes, __ovm_offset)'
sameTokens(packed,minify.compact(packed,{rename=false}))
assert(#minify.compact(packed,{rename=false}) < #packed)
local generatedFile = io.open('tests/.generated/core_12345.luau','rb')
if generatedFile then
    local generated = generatedFile:read('*a'); generatedFile:close()
    sameTokens(generated,minify.compact(generated,{rename=false}))
end
print('Minifier host checks OK')

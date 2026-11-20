local a, b = 12, .5
assert(a .. b == '120.5')
assert(a - - b == 12.5)
assert(not not a)
local tableValue = { [ [==[key]==] ] = [=[value]=] }
assert(tableValue[ [==[key]==] ] == 'value')
local binary, hex, exponent = 0b1010, 0x10, 1e2
assert(binary + hex + exponent == 126)
local function echo(value) return value end
assert(echo 'value' == 'value')
assert(`{"}"}:{`nested {2}`}` == '}:nested 2')
local __ovm_private = 42
assert(`{__ovm_private}` == '42')
for i = 1, 3 do
    if i == 2 then continue end
    a += i
end
assert(a == 16)
print('minify OK')

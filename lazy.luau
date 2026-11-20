local function pack(...) return {n=select('#', ...), ...} end
local function constants()
    return nil, false, 0, -0.0, '', '\0\255binary\128', 1e309, -1e309
end
local first, second = pack(constants()), pack(constants())
assert(first.n == 8 and second.n == 8)
assert(first[1] == nil and first[2] == false and first[3] == 0)
assert(1 / first[4] == -math.huge and first[5] == '')
assert(first[6] == '\0\255binary\128' and first[7] == math.huge and first[8] == -math.huge)
for i=2,8 do assert(first[i] == second[i]) end
local integers={-2147483648,2147483647,-32768,32767,-128,127,128,65535,65536,2147483648,-2147483649}
assert(integers[1]+integers[2]==-1)
assert(integers[3]+integers[4]==-1 and integers[5]+integers[6]==-1)
assert(integers[7]==128 and integers[8]+1==integers[9])
assert(integers[10]+integers[11]==-1)

local function neverCalled()
    return 'VERITY_UNUSED_CONSTANT_SENTINEL_8c96', 918273645.125
end
assert(type(neverCalled) == 'function')

local function make()
    local value = 'start'
    return function(nextValue)
        local old = value
        value = nextValue
        return old, 'closure-constant', nil, false
    end
end
local update = make()
local a = pack(update('next'))
local b = pack(update(false))
assert(a.n == 4 and a[1] == 'start' and a[2] == 'closure-constant' and a[3] == nil and a[4] == false)
assert(b.n == 4 and b[1] == 'next' and b[4] == false)

local function recurse(n)
    if n == 0 then return 'recursive-leaf', nil, false end
    local value, missing, boolean = recurse(n-1)
    assert(missing == nil and boolean == false)
    return value, missing, boolean
end
assert(pack(recurse(4)).n == 3)

local co = coroutine.create(function()
    local input = coroutine.yield('suspended-constant', nil, false)
    return input, 'resumed-constant', nil
end)
local suspended = pack(coroutine.resume(co))
assert(suspended.n == 4 and suspended[1] == true and suspended[2] == 'suspended-constant' and suspended[4] == false)
local resumed = pack(coroutine.resume(co, 'input-constant'))
assert(resumed.n == 4 and resumed[2] == 'input-constant' and resumed[3] == 'resumed-constant' and resumed[4] == nil)
print('lazy OK')

local name = 'Luau'
local count = 42
assert(`name={name}; count={count}; nil={nil}; bool={false}` == 'name=Luau; count=42; nil=nil; bool=false')
assert(`literal 100% \{brace\} \`tick\` }` == 'literal 100% {brace} `tick` }')
assert(`A\x42\u{1F600}\z   C` == 'AB\u{1F600}C')
assert(`` == '' and `plain` == 'plain')
assert(`{`nested {2 + 3}`}` == 'nested 5')
assert(`{"}"}` == '}')
assert(`{({value=7}).value}` == '7')
local commented = `value={-- } this brace belongs to a comment
    7 -- { this brace also belongs to a comment
}`
assert(commented == 'value=7')
assert(`{(function() --[==[ { } ` ignored ]==]
    return 'result'
end)()}` == 'result')
local function results() return 'first', nil, 'third' end
assert(`{results()}` == 'first')
local function vararg(...) return `{...}` end
assert(vararg(nil, 2) == 'nil' and vararg('one', 'two') == 'one')
local events = {}
local object = setmetatable({value='old'}, {__tostring=function(self)
    events[#events+1] = 'T'
    return self.value
end})
local function mutate()
    events[#events+1] = 'E'
    object.value = 'new'
    return 8
end
assert(`{object}:{mutate()}:{object}` == 'new:8:new')
assert(table.concat(events) == 'ETT')
local nativeTostring = tostring
tostring = function() return 'overridden' end
local function shadowed()
    local tostring = function() return 'shadowed' end
    return `{12}:{true}:{object}`
end
assert(shadowed() == '12:true:new')
tostring = nativeTostring
local converted = 0
local deferred = setmetatable({}, {__tostring=function()
    converted += 1
    return 'converted'
end})
local function bad() error('interpolation expression failure') end
local ok = pcall(function() return `{deferred}:{bad()}` end)
assert(not ok and converted == 0)
print('interpolation OK')

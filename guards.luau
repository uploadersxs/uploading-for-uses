local function pack(...) return {n=select('#',...),...} end
local function equal(actual,...)
    local expected=pack(...)
    assert(actual.n==expected.n,'guarded return count')
    for index=1,expected.n do assert(actual[index]==expected[index],'guarded return value') end
end

local function relay(...) return ... end
equal(pack(relay(nil,false,9,nil)),nil,false,9,nil)
local function owner(start)
    local current=start
    return function(amount) current+=amount; return current,nil end,
        function() return current end
end
local add,read=owner(4)
equal(pack(add(3)),7,nil)
assert(read()==7)

local callable=setmetatable({}, {__call=function(_,...) return ... end})
equal(pack(callable(nil,8,nil)),nil,8,nil)
local co=coroutine.create(function(...)
    local arguments=pack(...)
    local response=pack(coroutine.yield(arguments.n,nil,arguments[1]))
    return response.n,response[1],response[2],nil
end)
equal(pack(coroutine.resume(co,false,nil)),true,2,nil,false)
equal(pack(coroutine.resume(co,nil,12)),true,2,nil,12,nil)
assert(coroutine.status(co)=='dead')

local firstError=pcall(function() error('guard user error') end)
assert(not firstError)
print('guards normal OK')

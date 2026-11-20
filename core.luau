local function pack(...) return {n=select('#',...),...} end
local function eq(actual, ...)
    local expected=pack(...)
    assert(actual.n==expected.n, 'result count')
    for i=1,expected.n do assert(actual[i]==expected[i], 'result value') end
end
local function values() return 1,nil,3,nil end
eq(pack(values()),1,nil,3,nil)
local a,b,c,d=values()
eq(pack(a,b,c,d),1,nil,3,nil)
local x,y,z=8,values()
eq(pack(x,y,z),8,1,nil)
eq(pack((values())),1)
local function spread(first,...) return first,... end
eq(pack(spread(false,values())),false,1,nil,3,nil)
local t={99,values()}
assert(t[1]==99 and t[2]==1 and t[3]==nil and t[4]==3)
local index=1
local indexed={4,5}
index,indexed[index]=2,9
assert(index==2 and indexed[1]==9)
local p,q=1,2
p,q=q,p
assert(p==2 and q==1)
local n=7
do local n=n+1; assert(n==8) end
assert(n==7)
local called=0
local function side() called=called+1; return 123 end
assert((false and side())==false)
assert((true or side())==true)
assert((nil or side())==123 and called==1)
assert(2^3^2==512 and -2^2==-4)
assert('a'..'b'..3=='ab3')
local function fact(n)
    if n<=1 then return 1 end
    return n*fact(n-1)
end
assert(fact(6)==720)
local function factory()
    local value=0
    return function(n) value=value+n; return value end,
        function() return value end
end
local add,get=factory()
assert(add(3)==3 and add(4)==7 and get()==7)
local function deep()
    local v=2
    return function() return function() v=v+1; return v end end
end
local nested=deep()()
assert(nested()==3 and nested()==4)
local keyCalls=0
local function key() keyCalls=keyCalls+1; return 'value' end
local object={value=10}
object[key()] += 7
assert(object.value==17 and keyCalls==1)
local function obj() keyCalls=keyCalls+1; return object end
obj().value *= 2
assert(object.value==34 and keyCalls==2)
function object:plus(amount) return self.value+amount end
assert(object:plus(6)==40)
local mt={__add=function(a,b) return a.v+b.v end,
    __index=function(_,k) return k..'!' end,
    __call=function(_,...) return ... end}
local left=setmetatable({v=5},mt)
local right=setmetatable({v=6},mt)
assert(left+right==11 and left.missing=='missing!')
eq(pack(left(values())),1,nil,3,nil)
local writes={}
local target=setmetatable({}, {__newindex=function(_,k,v) writes[k]=v end})
target.answer=42
assert(writes.answer==42)
local co=coroutine.create(function(a)
    local b,c=coroutine.yield(a,nil)
    return b,c
end)
eq(pack(coroutine.resume(co,8)),true,8,nil)
eq(pack(coroutine.resume(co,9,nil)),true,9,nil)
local ok,err=pcall(function() error('expected') end)
assert(not ok and string.find(tostring(err),'expected',1,true))
print('core OK')

local function pack(...) return {n=select('#',...),...} end
local function equal(actual, ...)
    local expected=pack(...)
    assert(actual.n==expected.n, 'runtime return count')
    for i=1,expected.n do assert(actual[i]==expected[i], 'runtime return value') end
end

local concatEvents={}
local concatMeta={}
local function item(name) return setmetatable({name=name},concatMeta) end
concatMeta.__concat=function(left,right)
    local joined=left.name..right.name
    concatEvents[#concatEvents+1]=joined
    return item(joined)
end
assert((item('a')..item('b')..item('c')).name=='abc')
assert(concatEvents[1]=='bc' and concatEvents[2]=='abc')
local divMeta={__idiv=function(left,right) return left.value-right.value end}
assert(setmetatable({value=21},divMeta)//setmetatable({value=8},divMeta)==13)
local lenProxy=newproxy(true)
getmetatable(lenProxy).__len=function() return 73 end
assert(#lenProxy==73 and #'buffer'==6)
assert(#{1,nil,3}==3 and #{nil,2,3}==3 and #{1,nil,nil,4}==4)
local function sparseValues() return 1,nil,3 end
assert(#{sparseValues()}==3 and #{99,sparseValues()}==4)
assert(#{[1]=1,[3]=3}==1)

local intercepted=0
local indirectMeta=setmetatable({}, {__index=function()
    intercepted=intercepted+1
    error('iteration must look up metamethods without __index')
end})
local plain=setmetatable({first=4,second=7},indirectMeta)
local total=0
for _,value in plain do total=total+value end
assert(total==11 and intercepted==0)

local iterEvents={}
local iterObject=setmetatable({}, {
    __iter=function(object)
        assert(object~=nil)
        iterEvents[#iterEvents+1]='iter'
        local function advance(state,control)
            if control==nil then return false,state,nil end
            if control==false then return 2,nil,'tail' end
            return nil
        end
        return advance,9,nil
    end,
    __call=function() error('__iter must take priority') end,
})
local iterations=0
for key,a,b in iterObject do
    iterations=iterations+1
    if iterations==1 then assert(key==false and a==9 and b==nil)
    else assert(key==2 and a==nil and b=='tail') end
end
assert(iterations==2 and iterEvents[1]=='iter')
local calls=0
local callable=setmetatable({}, {__call=function(_,state,control)
    assert(state=='state')
    calls=calls+1
    if control==nil then return 1,'callable' end
    return nil
end})
for key,value in callable,'state',nil do assert(key==1 and value=='callable') end
assert(calls==2)

local function configured() return answer end
local env=setmetatable({answer=91},{__index=getfenv(configured)})
setfenv(configured,env)
assert(getfenv(configured)==env and configured()==91)
local function factory() return function() return answer end end
setfenv(factory,env)
local child=factory()
assert(getfenv(child)==env and child()==91)
env.answer=92
assert(configured()==92 and child()==92)

local many={}
for i=1,1024 do many[i]=i end
local function large(...)
    local values=pack(...)
    return values.n,values[1],values[1024],nil
end
equal(pack(large(table.unpack(many,1,1024))),1024,1,1024,nil)
local function returnMany(...) return ... end
local manyResults=pack(returnMany(table.unpack(many,1,1024)))
assert(manyResults.n==1024 and manyResults[1024]==1024)

local yieldMeta={__add=function(left,right)
    local resumed=coroutine.yield('metamethod',nil)
    return left.value+right.value+resumed
end}
local co=coroutine.create(function()
    return setmetatable({value=3},yieldMeta)+setmetatable({value=4},yieldMeta)
end)
local success,message=coroutine.resume(co)
assert(not success and string.find(message,'metamethod',1,true))
local iterYield=setmetatable({}, {__iter=function()
    coroutine.yield('iter metamethod')
    return next,{},nil
end})
local iterCo=coroutine.create(function() for _ in iterYield do end end)
local iterSuccess,iterMessage=coroutine.resume(iterCo)
assert(not iterSuccess and string.find(iterMessage,'metamethod',1,true))
local nameProxy=newproxy(true)
local nameMeta=getmetatable(nameProxy)
nameMeta.__namecall=function(self,...)
    assert(self==nameProxy)
    return 'initial',select('#',...),...
end
equal(pack(nameProxy:hello(7,nil)),'initial',2,7,nil)
local function replaceNamecall()
    nameMeta.__namecall=function(self,value)
        assert(self==nameProxy)
        return 'replacement',value,nil
    end
    return 8
end
equal(pack(nameProxy:hello(replaceNamecall())),'replacement',8,nil)
nameMeta.__namecall=setmetatable({}, {__call=function(_,self,a,b)
    assert(self==nameProxy)
    return a,nil,b,nil
end})
equal(pack(nameProxy:callable(false,9)),false,nil,9,nil)
nameMeta.__namecall=function(self,value)
    assert(self==nameProxy)
    local resumed=coroutine.yield(value,nil)
    return resumed,nil
end
local nameCo=coroutine.create(function() return nameProxy:yielding(10) end)
equal(pack(coroutine.resume(nameCo)),true,10,nil)
equal(pack(coroutine.resume(nameCo,11)),true,11,nil)
print('runtime OK')

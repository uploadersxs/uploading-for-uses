package.path = './?.lua;' .. package.path
local obfuscator = require('src.obfuscator')
local util = require('src.util')

for index,source in ipairs({'local x=0x_', 'local x=0b___', 'return; print(1)',
    'while false do break; print(1) end', 'while false do continue; print(1) end'}) do
    util.write('tests/.generated/syntax_invalid_'..index..'.luau',source)
end

-- Bounded generated programs exercise values and observable effects rather
-- than merely repeating the bytecode implementation in a unit test.
for case=1,6 do
    local rng = util.rng(271828 + case)
    local a, b, length = rng:int(-20,20), rng:int(1,13), rng:int(3,9)
    local source = string.format([=[
local function pack(...) return {n=select('#',...),...} end
local trace={}
local base=%d
local function mark(label,...)
    trace[#trace+1]=label
    return ...
end
local snapshots={}
for i=1,%d do
    if i%%3==0 then continue end
    local capture=i
    snapshots[#snapshots+1]=function(delta)
        capture+=delta
        return capture, nil, false
    end
    base+=i*%d
end
local values=pack(mark('values',nil,false,0,'','\0\255'))
assert(values.n==5 and values[1]==nil and values[2]==false and values[3]==0 and values[4]=='')
local one=mark('one',nil,9)
local x,y,z=mark('many',false,nil,'tail')
assert(one==nil and x==false and y==nil and z=='tail')
local result=0
for _,f in snapshots do
    local v,missing,flag=f(2)
    assert(missing==nil and flag==false)
    result+=v
end
local meta=setmetatable({v=base},{__add=function(left,right) return left.v+right end})
result+=meta+%d
local co=coroutine.create(function()
    local v=coroutine.yield('yield',nil,false)
    return v+result,nil
end)
local suspended=pack(coroutine.resume(co))
assert(suspended.n==4 and suspended[3]==nil and suspended[4]==false)
local finished=pack(coroutine.resume(co,3))
assert(finished.n==3 and finished[3]==nil)
print(base,result,finished[2],table.concat(trace,','),string.byte(values[5],1,2))
]=], a, length, b, case)
    util.write('tests/.generated/diff_' .. case .. '_native.luau', source)
    for _, profile in ipairs({'fast','balanced','max'}) do
        local output=obfuscator.obfuscate(source,{seed=31415+case,profile=profile})
        util.write('tests/.generated/diff_' .. case .. '_' .. profile .. '.luau',output)
    end
end

local source=util.read('tests/fixtures/lazy.luau')
local variants={
    {'fast',{profile='fast'}}, {'balanced',{profile='balanced'}}, {'max',{profile='max'}},
    {'legacy',{compact=false,lazyConstants=false,main=false}},
    {'eager',{lazyConstants=false}}, {'execution',{constantCache='execution'}},
    {'none',{constantCache='none'}}, {'unoptimized',{optimize=false,main=false}},
    {'debug',{debug=true}},
}
for _,variant in ipairs(variants) do
    variant[2].seed=12345
    local output=obfuscator.obfuscate(source,variant[2])
    util.write('tests/.generated/lazy_' .. variant[1] .. '.luau',output)
end

local probe=[=[
local function used()
    local a='materialization-probe-used'
    local b='materialization-probe-used'
    return a,b,nil,false
end
local function unused() return 'materialization-probe-never' end
used()
used()
]=]
for _,mode in ipairs({'prototype','execution','none'}) do
    local output=obfuscator.obfuscate(probe,{seed=13579,main=false,debugConstants=true,constantCache=mode})
    local expected=mode=='prototype' and 1 or (mode=='execution' and 2 or 4)
    local prefix=[=[
local usedCount=0
local nilCount,falseCount=0,0
__verity_constant=function(layer,prototype,constant,value)
    assert(layer==1 and prototype>=1 and constant>=1)
    assert(value~='materialization-probe-never','unused constant was decrypted')
    if value=='materialization-probe-used' then usedCount+=1 end
    if value==nil then nilCount+=1 end
    if value==false then falseCount+=1 end
end
local function protected(...)
]=]
    local suffix='\nend\nprotected()\n__verity_constant=nil\nassert(usedCount=='..expected..', "wrong constant-cache behavior")\nassert(nilCount>0 and falseCount>0, "nil/false materialization missing")\nprint("materialization '..mode..' OK")\n'
    util.write('tests/.generated/materialization_'..mode..'.luau',prefix..output..suffix)
end
for _,main in ipairs({false,true}) do
    local label=main and 'main' or 'single'
    local output=obfuscator.obfuscate('local function crash()\n local value=nil\n return value.noSuchField\nend\ncrash()\n',
        {seed=24680,main=main,debug=true,chunkname='trace_probe.luau'})
    local suffix=[=[
end
local ok,message=pcall(protected)
assert(not ok and type(message)=='string')
assert(string.find(message,'trace_probe.luau:3',1,true),message)
]=]
    util.write('tests/.generated/trace_'..label..'.luau','local function protected(...)\n'..output..'\n'..suffix..
        'print("trace '..label..' OK")\n')
end
print('Differential inputs generated')

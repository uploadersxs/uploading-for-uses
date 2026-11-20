package.path='./?.lua;./?/init.lua;'..package.path
local parser=require('src.parser')
local compiler=require('src.compiler')
local optimizer=require('src.optimizer')
local verify=require('src.verify')
local serialize=require('src.serialize')
local runtime=require('src.runtime')
local util=require('src.util')
local instructions=require('src.instructions')

local fallback=[=[
local function __ovm_guardtuple(row,a,b,c,d,e)
    if a~=row[1] or b~=row[2] or c~=row[3] or d~=row[4] or e~=row[5] then error('',0) end
end
]=]
local trusted=fallback..[=[
local order={}
local expected={11,false,nil,14,15}
local function argument(index)
    table.insert(order,index)
    return expected[index]
end
__ovm_guardtuple(expected,argument(1),argument(2),argument(3),argument(4),(argument(5)))
assert(#order==5)
for index=1,5 do assert(order[index]==index,'tuple arguments changed order or evaluated twice') end
local a,b=__ovm_guardtuple(expected,11,false,nil,14,15)
assert(a==nil and b==nil,'tuple primitive returned a value')
local packed=table.pack(__ovm_guardtuple(expected,11,false,nil,14,15))
assert(packed.n==0,'tuple primitive must return zero values')
for index=1,5 do
    local values={11,false,nil,14,15}
    values[index]=99
    local ok=pcall(function()
        __ovm_guardtuple(expected,values[1],values[2],values[3],values[4],values[5])
    end)
    assert(not ok,'tuple primitive missed a mismatched field')
end
local reads={}
local short=setmetatable({}, {__index=function(_,index)
    table.insert(reads,index)
    return index
end})
local ok=pcall(function() __ovm_guardtuple(short,99,2,3,4,5) end)
assert(not ok and #reads==1 and reads[1]==1,'tuple comparisons lost short-circuit order')
print('guard tuple trusted OK')
]=]
local untrusted=[=[
local calls=0
local function __ovm_guardtuple(row,a,b,c,d,e)
    calls+=1
    return 'custom',nil,c,e
end
local a,b,c,d=__ovm_guardtuple({},1,2,3,4,5)
assert(calls==1 and a=='custom' and b==nil and c==3 and d==5,'user function was replaced with an intrinsic')
print('guard tuple untrusted OK')
]=]
local function count(proto)
    local total=0
    for _,ins in ipairs(proto.code) do if ins.op=='GUARDTUPLE' then total=total+1 end end
    for _,child in ipairs(proto.children) do total=total+count(child) end
    return total
end
local function emit(name,source,enabled)
    local proto=compiler.compile(parser.parse(source,'guard-tuple'),{trustedRuntime=enabled})
    assert((count(proto)>0)==enabled,'trusted tuple primitive scope changed')
    assert(verify.check(proto))
    optimizer.apply(proto,{unbox=false})
    assert(verify.check(proto))
    local rng=util.rng(12345)
    local opcodes,order,aliases=serialize.opcodes(rng)
    local payload,checksum,_,_,entry,wire=serialize.encode(proto,opcodes,12345,{rng=rng,aliases=aliases})
    local output=runtime.render({payload=payload,checksum=checksum,seed=12345,opcodes=opcodes,
        order=order,aliases=aliases,entry=entry,limits=wire.limits,antiTamper=true})
    util.write('tests/.generated/guard_tuple_'..name..'.luau',output)
end
emit('trusted',trusted,true)
emit('untrusted',untrusted,false)
util.write('tests/.generated/guard_tuple_untrusted_max.luau',
    require('src.obfuscator').obfuscate(untrusted,{seed=12345,profile='max',trustedRuntime=true}))
local spread=compiler.compile(parser.parse('return function(...) __ovm_guardtuple(row,1,2,3,4,...) end'),{trustedRuntime=true})
assert(count(spread)==0,'variable arity guard calls must retain their regular function behavior')
local method=compiler.compile(parser.parse('object:__ovm_guardtuple(row,1,2,3,4,5)'),{trustedRuntime=true})
assert(count(method)==0,'method calls must never use the reserved Name intrinsic')
local malformed={code={{op='GUARDTUPLE',1,2,4,0},{op='RETURN0',0,0,0,0}},
    constants={},children={},upvalues={},params={},slots=0,registers=6,vararg=false}
local ok,diagnostic=pcall(verify.check,malformed)
assert(not ok and tostring(diagnostic):find('tuple guard requires five values',1,true),'tuple arity must be checked')
for _,kind in ipairs({'arity','range'}) do
    malformed.code[1][3]=kind=='arity' and 4 or 5
    malformed.registers=kind=='arity' and 6 or 5
    local rng=util.rng(12345)
    local opcodes,order,aliases=serialize.opcodes(rng)
    local payload,checksum,_,_,entry,wire=serialize.encode(malformed,opcodes,12345,{rng=rng,aliases=aliases})
    local output=runtime.render({payload=payload,checksum=checksum,seed=12345,opcodes=opcodes,
        order=order,aliases=aliases,entry=entry,limits=wire.limits,antiTamper=true})
    util.write('tests/.generated/guard_tuple_invalid_'..kind..'.luau',
        'local run=function(...)\n'..output..'\nend\nassert(not pcall(run),"malformed tuple contract escaped")\nprint("guard tuple invalid '..kind..' OK")\n')
end
print('Guard tuple host checks OK')

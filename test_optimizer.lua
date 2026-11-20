package.path='./?.lua;./?/init.lua;'..package.path
local parser=require('src.parser')
local compiler=require('src.compiler')
local optimizer=require('src.optimizer')
local verify=require('src.verify')
local specs=require('src.instructions').specs

local function compile(source)
    local proto=compiler.compile(parser.parse(source,'optimizer-test'),{chunkname='optimizer-test'})
    assert(verify.check(proto))
    return proto
end

-- Branch joins, loop-carried values, and fixed native argument windows all
-- survive allocation. The runtime fixture suite checks their actual execution.
local sample=[[
local shared=0
local function read() return shared end
local total=0
for index=1,5 do
    local current=index*2
    if index%2==0 then total+=current else total+=1 end
    shared=total
    print(index,total,(read()))
end
return total
]]
local proto=compile(sample)
local stats=optimizer.apply(proto)
assert(verify.check(proto))
assert(stats.registersSaved>0 and stats.unboxedSlots>0 and stats.boxedSlots==1)
assert(stats.fixedCalls>0)
assert(proto.chunkname=='optimizer-test')
assert(proto.boxed[proto.children[1].upvalues[1].index],'captured slot must remain boxed')
for pc,ins in ipairs(proto.code) do
    assert(proto.lines[pc]==ins.line and ins.line>=1,'source lines must survive optimization')
    local range=specs[ins.op].range
    if range and ins[range.count]>0 then
        assert(ins[range.first]>=1 and ins[range.first]+ins[range.count]-1<=proto.registers)
    end
end

local plain=compile('local x=3; return x')
local disabled=optimizer.apply(plain,{enabled=false})
assert(verify.check(plain))
assert(disabled.registersSaved==0 and disabled.instructionsSaved==0)
assert(disabled.unboxedSlots==0 and plain.boxed[1])
local callsDisabled=compiler.compile(parser.parse('print(1)'),{optimize=false})
for _,ins in ipairs(callsDisabled.code) do assert(not specs[ins.op].range) end
local callsExplicit=compiler.compile(parser.parse('print(1)'),{optimize=false,fixedCalls=true})
local explicit=false
for _,ins in ipairs(callsExplicit.code) do if specs[ins.op].range then explicit=true end end
assert(explicit,'explicit fixedCalls must override disabled optimization')

-- A branch entering NEWLOCAL prevents LOADK/NEWLOCAL fusion. The LOADK value
-- is still defined along the branch's path, so both instructions must remain.
local guarded=compile('local x=1; return x')
guarded.code[4]={op='JMP',2,0,0,0,line=1}
local guardedStats=optimizer.apply(guarded,{reuse=false})
assert(verify.check(guarded))
assert(guardedStats.fusedLoadLocals==0)

local literal=compile('local x=1; return x')
assert(optimizer.apply(literal).fusedLoadLocals==1)
assert(verify.check(literal))
assert(literal.code[1].op=='LOADLOCAL')

local function rejected(source,mutate)
    local bad=compile(source)
    mutate(bad)
    assert(not pcall(verify.check,bad),'malformed IR must be rejected')
end
rejected('return 1',function(p) p.code[1][1]=p.registers+1 end)
rejected('return 1',function(p) p.code[1][2]=#p.constants+1 end)
rejected('return 1',function(p) p.code[1].op='UNKNOWN' end)
rejected('return 1',function(p) p.code[1][1]=-1 end)
rejected('return 1',function(p) p.code[1][1]=false end)
rejected('return 1',function(p) p.code[1]={op='JMP',#p.code+1,0,0,0} end)
rejected('print(1,2)',function(p)
    for _,ins in ipairs(p.code) do
        if ins.op=='CALLF0' then ins[2]=p.registers; ins[3]=2; break end
    end
end)
rejected('local x=1; return function() return x end',function(p)
    optimizer.apply(p)
    p.boxed[p.children[1].upvalues[1].index]=false
end)
rejected('return 1',function(p) p.code[2]=nil; p.code[5]={op='RETURN0',0,0,0,0} end)
local disjoint=compile('do local a=1; print(a) end; do local b=2; print(b) end')
local savings=optimizer.apply(disjoint)
assert(verify.check(disjoint) and savings.slotsSaved==1 and disjoint.slots==1)
local parameters=compile('return function(unused,value) return value end')
optimizer.apply(parameters)
assert(verify.check(parameters) and parameters.children[1].params[1]~=parameters.children[1].params[2])
local captured=compile('local saved; do local x=3; saved=function() return x end end; do local y=4; print(y) end; return saved')
optimizer.apply(captured)
assert(verify.check(captured) and captured.boxed[captured.children[1].upvalues[1].index])
local ok,diagnostic=pcall(compiler.compile,parser.parse('const x=1; x=2','diagnostic-source.luau'))
assert(not ok and tostring(diagnostic):find('diagnostic-source.luau:1:',1,true),'compiler diagnostic missing source')
print('Optimizer and IR checks OK')

package.path='./?.lua;./?/init.lua;'..package.path
local parser=require('src.parser')
local compiler=require('src.compiler')
local optimizer=require('src.optimizer')
local verify=require('src.verify')
local obfuscator=require('src.obfuscator')
local util=require('src.util')
local instructions=require('src.instructions')

local source=[=[
local calls=0
local function many(value)
    calls+=1
    return nil,value,false,nil,5,nil,'discarded'
end
local a,b,c,d,e,f=many(17)
assert(a==nil and b==17 and c==false and d==nil and e==5 and f==nil and calls==1)
local x,y=many(19)
assert(x==nil and y==19 and calls==2)
local q,r,s,t=many(23)
assert(q==nil and r==23 and s==false and t==nil and calls==3)
local object={Value=29}
function object:many(delta) calls+=1; return self.Value+delta,nil,false,nil end
local m,n,o,p=object:many(2)
assert(m==31 and n==nil and o==false and p==nil and calls==4)
local function spread(...)
    local h,i,j,k,l,z=many(...)
    return h,i,j,k,l,z
end
local packed=table.pack(spread(31,nil))
assert(packed.n==6 and packed[1]==nil and packed[2]==31 and packed[3]==false and packed[4]==nil and packed[5]==5 and packed[6]==nil and calls==5)
local once=0
local function argument() once+=1; return 37 end
local u,v,w=many(argument())
assert(u==nil and v==37 and w==false and once==1 and calls==6)
local fu,fv,fw=many(39)
assert(fu==nil and fv==39 and fw==false and calls==7)
local fa,fb,fc,fd,fe=many(40)
assert(fa==nil and fb==40 and fc==false and fd==nil and fe==5 and calls==8)
local short=function() return false end
local sa,sb,sc,sd,se,sf=short()
assert(sa==false and sb==nil and sc==nil and sd==nil and se==nil and sf==nil)
local worker=coroutine.create(function()
    local function suspended()
        coroutine.yield('before results',nil)
        return nil,41,false,nil,43,nil
    end
    local wa,wb,wc,wd,we,wf=suspended()
    assert(wa==nil and wb==41 and wc==false and wd==nil and we==43 and wf==nil)
    return wa,wb,wc,wd,we,wf
end)
local first=table.pack(coroutine.resume(worker))
assert(first.n==3 and first[1] and first[2]=='before results' and first[3]==nil)
local resumed=table.pack(coroutine.resume(worker))
assert(resumed.n==7 and resumed[1] and resumed[2]==nil and resumed[3]==41 and resumed[4]==false and resumed[5]==nil and resumed[6]==43 and resumed[7]==nil)
local got=0
local function owner()
    local initial=47
    return function() got+=1; return initial,nil,false,nil,53,nil end
end
local ca,cb,cc,cd,ce,cf=owner()()
assert(ca==47 and cb==nil and cc==false and cd==nil and ce==53 and cf==nil and got==1)
local snapshot=57
local function mutateSnapshot() snapshot=59;return 61 end
local function receive(left,middle,right) return left,middle,right end
local aa,ab,ac=receive(snapshot,mutateSnapshot(),67)
assert(aa==57 and ab==61 and ac==67 and snapshot==59,'later argument changed an earlier snapshot')
local target={Value=71}
function target:inspect(left,middle,right) return self.Value,left,middle,right end
local function replaceTarget() target.Value=73;return 79 end
local ma,mb,mc,md=target:inspect(target.Value,replaceTarget(),83)
assert(ma==73 and mb==71 and mc==79 and md==83 and target.Value==73,'method receiver or argument snapshot changed')
print('fixed results OK')
]=]
local proto=compiler.compile(parser.parse(source,'fixed-results'))
local seen={}
for _,ins in ipairs(proto.code) do if ins.op:match('^CALLF[2-6]$') then seen[ins.op]=true end end
assert(seen.CALLF2 and seen.CALLF3 and seen.CALLF4 and seen.CALLF5 and seen.CALLF6,'finite initializer calls were not specialized')
assert(verify.check(proto))
optimizer.apply(proto)
assert(verify.check(proto))
local function inspect(p)
    for _,ins in ipairs(p.code) do
        local spec=instructions.specs[ins.op]
        if spec.writeRange then
            assert(ins[spec.writeRange.first]>=1 and ins[spec.writeRange.first]+spec.writeRange.size-1<=p.registers,
                'allocated fixed result span exceeds registers')
        end
    end
    for _,child in ipairs(p.children) do inspect(child) end
end
inspect(proto)
local legacy=compiler.compile(parser.parse('local a,b,c,d,e,f=fn(1)'),{fixedReturns=false})
for _,ins in ipairs(legacy.code) do assert(not instructions.specs[ins.op].writeRange,'disabled fixed returns emitted a result span') end
local unbounded=compiler.compile(parser.parse('local a,b,c,d,e,f,g=fn(1)'))
for _,ins in ipairs(unbounded.code) do assert(not instructions.specs[ins.op].writeRange,'wide finite calls must keep the supported fallback') end
local malformed={code={{op='CALLF6',2,1,0,0},{op='RETURN0',0,0,0,0}},
    constants={},children={},upvalues={},params={},slots=0,registers=2,vararg=false}
local ok,diagnostic=pcall(verify.check,malformed)
assert(not ok and tostring(diagnostic):find('result register range out of bounds',1,true),
    'verifier accepted an overflowing fixed result span')
util.write('tests/.generated/fixed_results_native.luau',source)
for _,profile in ipairs({'fast','balanced','max'}) do
    util.write('tests/.generated/fixed_results_'..profile..'.luau',
        obfuscator.obfuscate(source,{seed=12345,profile=profile}))
end
-- Encode deliberately invalid IR directly to prove the emitted loader rejects
-- the whole result span before calling a native function with side effects.
do
    local serialize=require('src.serialize')
    local runtime=require('src.runtime')
    local opcodes,order,aliases=serialize.opcodes(util.rng(12345))
    malformed.constants={{kind='string',value='touch'}}
    malformed.code={{op='GETGLOBAL',1,1,0,0},{op='CALLF6',2,1,0,0},{op='RETURN0',0,0,0,0}}
    local payload,checksum,_,_,entry,wire=serialize.encode(malformed,opcodes,12345,{aliases=aliases,rng=util.rng(12345)})
    local output=runtime.render({payload=payload,checksum=checksum,seed=12345,opcodes=opcodes,
        order=order,aliases=aliases,entry=entry,limits=wire.limits,antiTamper=true})
    util.write('tests/.generated/fixed_results_invalid.luau',[=[
local touched=0
local environment=setmetatable({touch=function() touched+=1 end},{__index=getfenv()})
local run=function(...)
]=]..output..[=[
end
setfenv(run,environment)
local ok=pcall(run)
assert(not ok and touched==0,'malformed result span reached the native callee')
print('fixed results invalid OK')
]=])
end
print('Fixed results host checks OK')

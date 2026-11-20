package.path='./?.lua;./?/init.lua;'..package.path
local fetch=require('src.fetch')
local nativeModule=require('src.native')
local util=require('src.util')
local evaluate=loadstring or load
local function pack(...) return {n=select('#',...),...} end

local disabled=fetch.render({antiTamper=false},nativeModule.new(true))
assert(not disabled.enabled and disabled.helpers=='' and disabled.frame=='' and disabled.fetch=='')
assert(not pcall(fetch.render,{antiTamper=true,lazyInstructions=true,instructionCache='invalid'}))

local function constructor(config)
    local native=nativeModule.new(config.nativeHelpers)
    local rendered=fetch.render(config,native)
    assert(rendered.enabled and rendered.frame=='local __ovm_fetch=__ovm_instructionframe(__ovm_p)')
    assert(rendered.fetch:find('__ovm_expected=__ovm_fetch',1,true),'fetch must return the frozen expected record')
    local factories=assert(evaluate('return '..native:source()))()
    local build=assert(evaluate('return function(__ovm_bytes,__ovm_buffer,__ovm_floor,__ovm_error,__ovm_type,'
        ..'__ovm_instructioncaches,__ovm_materializeblock,__ovm_checkedinstruction,__ovm_accelerators)\n'
        ..rendered.helpers..'\nreturn __ovm_instructionframe end'))()
    return function(bytes,caches,materialize,checked)
        return build(bytes,nil,math.floor,error,type,caches,materialize,checked,factories)
    end
end

local function rejected(fetcher,before,after)
    for _,bad in ipairs({0,-1,0.5,5,'1',false,{},1/0,0/0}) do assert(not pcall(fetcher,bad),'invalid PC accepted') end
    assert(not pcall(fetcher),'nil PC accepted')
    assert(after()==before,'invalid PC reached cache/materializer/byte checks')
end

for _,native in ipairs({false,true}) do
    for _,policy in ipairs({'prototype','execution','none'}) do
        local make=constructor({antiTamper=true,lazyInstructions=true,instructionCache=policy,nativeHelpers=native})
        local calls,checks,caches=0,0,{}
        local function materialize(_,index,cache)
            calls=calls+1
            local first=index==1 and 'A' or 'C'
            local second=index==1 and 'B' or 'D'
            local base=index==1 and 10 or 20
            local entry={data={[0]=first,[1]=second},sites={0,1},checks={
                {base,101,0,0,0,first},{base+1,102,0,0,0,second}}}
            if cache then cache[index]=entry end
            return entry
        end
        local function checked(data,at,record)
            checks=checks+1
            assert(data[at]==record[6],'instruction bytes changed')
            return record[1],record[2],record[3],record[4],record[5]
        end
        local frame=make(nil,caches,materialize,checked)
        local p={id=1,count=4,blockSize=2}
        local first=frame(p)
        local values=pack(first(1))
        assert(values.n==6 and values[1]==10 and values[2]==101 and values[6][6]=='A')
        first(2);first(1);first(3);first(1)
        local second=frame(p)
        second(1);second(3);first(1);first(3);second(3)
        local expected=policy=='prototype' and 2 or policy=='execution' and 4 or 6
        assert(calls==expected,'cache policy/frame isolation caused repeated materialization: '..policy)
        assert(checks==10,'every fetch must still check instruction bytes')
        rejected(first,calls+checks,function() return calls+checks end)

        -- Alternate coroutines using independent frames; their active block
        -- cannot be confused even though prototype caches are shared.
        calls,checks,caches=0,0,{}
        frame=make(nil,caches,materialize,checked)
        local left,right=frame(p),frame(p)
        local workers={coroutine.create(function() for _,pc in ipairs({1,3,1}) do left(pc);coroutine.yield() end end),
            coroutine.create(function() for _,pc in ipairs({3,1,3}) do right(pc);coroutine.yield() end end)}
        for _=1,4 do for _,worker in ipairs(workers) do assert(coroutine.resume(worker)) end end
        assert(checks==6 and calls==expected,'coroutine frames changed cache lifetime: '..policy)
    end
    for _,compact in ipairs({false,true}) do
        local make=constructor({antiTamper=true,lazyInstructions=false,compact=compact,nativeHelpers=native})
        local checks=0
        local sites=compact and {2,4,6} or {2,19,36}
        local bytes,records={},{}
        for index,at in ipairs(sites) do
            local text='E'..index
            bytes[at]=text;records[index]={index,101,0,0,0,text}
        end
        local frame=make(bytes,nil,nil,function(data,at,record)
            checks=checks+1;assert(data[at]==record[6])
            return record[1],record[2],record[3],record[4],record[5]
        end)
        local stream=frame({count=3,offset=2,sites=compact and sites or nil,checks=records})
        for index=1,3 do local values=pack(stream(index));assert(values.n==6 and values[1]==index and values[6]==records[index]) end
        rejected(stream,checks,function() return checks end)
    end
end

-- The production checked-byte contract uses real buffers and frozen records.
-- Corrupt both the active block and an earlier prototype-cached block.
local runtime={}
for _,native in ipairs({false,true}) do
    local renderer=nativeModule.new(native)
    local rendered=fetch.render({antiTamper=true,lazyInstructions=true,instructionCache='prototype',nativeHelpers=native},renderer)
    runtime[#runtime+1]='do\nlocal __ovm_accelerators='..renderer:source()..[=[
local __ovm_bytes,__ovm_buffer,__ovm_floor,__ovm_error,__ovm_type=nil,buffer,math.floor,error,type
local __ovm_instructioncaches={}
local calls=0
local function __ovm_materializeblock(_,index,cache)
    calls+=1
    local raw=index==1 and 'AB' or 'CD'
    local record={index,101,0,0,0,raw};table.freeze(record)
    local checks={record};table.freeze(checks)
    local sites={0};table.freeze(sites)
    local entry={data=buffer.fromstring(raw),checks=checks,sites=sites};table.freeze(entry)
    if cache then cache[index]=entry end
    return entry
end
local function __ovm_checkedinstruction(data,at,record)
    if buffer.readstring(data,at,#record[6])~=record[6] then error('',0) end
    return record[1],record[2],record[3],record[4],record[5]
end
]=]..rendered.helpers..[=[
local p={id=1,count=2,blockSize=1};table.freeze(p)
local stream=__ovm_instructionframe(p)
local a,b,c,d,e,record=stream(1)
assert(a==1 and b==101 and c==0 and d==0 and e==0 and table.isfrozen(record))
stream(2)
local first=__ovm_instructioncaches[1][1]
buffer.writeu8(first.data,0,255)
assert(not pcall(stream,1),'cached previous block corruption escaped')
assert(calls==2,'cache hit unnecessarily called materializer')
buffer.writeu8(first.data,0,string.byte('A'))
stream(1)
buffer.writeu8(first.data,1,255)
assert(not pcall(stream,1),'active block corruption escaped')
assert(calls==2,'active block unnecessarily called materializer')
end
]=]
end
util.write('tests/.generated/fetch.luau',table.concat(runtime,'\n')..'\nprint("fetch OK")\n')
print('Fetch host checks passed')

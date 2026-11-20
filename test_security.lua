package.path='./?.lua;./?/init.lua;'..package.path
local obfuscator=require('src.obfuscator')
local build=require('src.build')
local runtime=require('src.runtime')
local serialize=require('src.serialize')
local instructions=require('src.instructions')
local cipher=require('src.cipher')
local protection=require('src.protection')
local guards=require('src.guards')
local util=require('src.util')

local manifest={}
local function fixture(name,source)
    assert(not name:find('[^%w_]'),'unsafe security fixture name')
    util.write('tests/.generated/security_'..name..'.luau',source..'\nprint('..string.format('%q','security '..name..' OK')..')\n')
    manifest[#manifest+1]=name
end
local function settings(overrides)
    local result={seed=12345,profile='fast',main=false,junk=0,cff=false,opaque=false,
        antiTamper=true,antiHooks='off',lazyInstructions=true,perPrototypeOpcodes=true,
        instructionBlockSize=4,instructionCache='prototype',debugBlocks=true,debugGuards=true}
    for key,value in pairs(overrides or {}) do result[key]=value end
    return result
end
local function harness(name,source,options,setup,body,rendered)
    local output=rendered or obfuscator.obfuscate(source,options)
    fixture(name,[[
local nativeEnvironment=getfenv()
local environment=setmetatable({}, {__index=nativeEnvironment})
]]..(setup or '')..'\nlocal function protected(...)\n'..output
        ..'\nend\nsetfenv(protected,environment)\n'..body)
end
local function plainPrototype()
    return {code={{op='LOADK',1,1,0,0},{op='RETURN1',1,0,0,0}},
        constants={{kind='number',value=42}},children={},upvalues={},params={},
        slots=0,registers=1,vararg=false,boxed={},chunkname='security-wire.luau'}
end
local function checksum(source)
    local hash=5381
    for index=1,#source do hash=(hash*33+source:byte(index))%4294967296 end
    return hash
end
local function replace(source,offset,bytes)
    assert(offset>=0 and offset+#bytes<=#source,'mutation out of range')
    return source:sub(1,offset)..bytes..source:sub(offset+#bytes+1)
end
local function u32(value)
    local out={}
    for index=1,4 do out[index]=string.char(value%256); value=math.floor(value/256) end
    assert(value==0)
    return table.concat(out)
end
local function wire(prototype,options)
    options=options or {}
    local rng=util.rng(12345)
    local opcodes,order,aliases=serialize.opcodes(rng,instructions.used(prototype))
    local outerCipher={key=314159,multiplier=48271}
    local version=options.version or 3
    local compact=options.compact~=false
    local lazyInstructions=version==3 and options.lazyInstructions~=false
    local perPrototypeOpcodes=version==3 and options.perPrototypeOpcodes~=false
    local payload,hash,size,_,entry,meta=serialize.encode(prototype,opcodes,12345,
        {version=version,compact=compact,lazyConstants=false,constantKey=271828,
            cipher=outerCipher,rng=rng,aliases=aliases,fields={'op','a','b','c','d'},
            lazyInstructions=lazyInstructions,perPrototypeOpcodes=perPrototypeOpcodes,
            instructionBlockSize=2,compression=options.compression==true})
    local configuration={payload=payload,checksum=hash,seed=12345,opcodes=opcodes,order=order,
        aliases=aliases,layout={op=0,a=1,b=5,c=9,d=13},fields={'op','a','b','c','d'},
        version=version,compact=compact,lazyConstants=false,constantKey=271828,
        cipher=outerCipher,transport='literal',compressed=meta.compressed,unpackedSize=size,entry=entry,
        maskOnLoad=false,antiTamper=true,antiHooks='off',lazyInstructions=lazyInstructions,
        perPrototypeOpcodes=perPrototypeOpcodes,instructionBlockSize=2,instructionCache='prototype',
        limits=meta.limits,layer=1}
    return cipher.crypt(payload,outerCipher,true),configuration,meta
end

local function capFixture(name,configuration,capKey,cap,watchedSize,operation)
    local copied={}
    for key,value in pairs(configuration) do copied[key]=value end
    copied.limits={}
    for key,value in pairs(configuration.limits) do copied.limits[key]=value end
    copied.limits[capKey]=cap
    copied.antiTamper=false
    local setup=[[
local attempts=0
local originalBuffer=buffer
local bufferCopy={}
for key,value in pairs(buffer) do bufferCopy[key]=value end
]]
    if operation=='allocation' then
        setup=setup..'bufferCopy.create=function(size) if size=='..watchedSize..' then attempts+=1 end; return originalBuffer.create(size) end\n'
            ..'bufferCopy.fromstring=function(value) if #value=='..watchedSize..' then attempts+=1 end; return originalBuffer.fromstring(value) end\n'
    else setup=setup..'bufferCopy.readstring=function(data,offset,size) if size=='..watchedSize..' then attempts+=1 end; return originalBuffer.readstring(data,offset,size) end\n' end
    setup=setup..'environment.buffer=bufferCopy\n'
    harness(name,nil,nil,setup,
        'local outcome=table.pack(pcall(protected)); assert(not outcome[1] and attempts==0,"size cap checked after allocation or read")',runtime.render(copied))
end
local function mutated(name,source,configuration,acceptSame)
    local copied={}
    for key,value in pairs(configuration) do copied[key]=value end
    copied.payload=cipher.crypt(source,copied.cipher)
    copied.checksum=checksum(source)
    copied.unpackedSize=#source
    local output=runtime.render(copied)
    local body='local outcome=table.pack(pcall(protected)); '
    if acceptSame then
        body=body..'if outcome[1] then assert(outcome.n==2 and outcome[2]==42,"mutation changed successful result") end'
    else body=body..'assert(not outcome[1] and not marked,"malformed wire escaped validation before user effects")' end
    harness(name,nil,nil,'local marked=false\nenvironment.touch=function(...) marked=true; return 42 end',body,output)
end

-- Portable host checks exercise nonlinear mixing independently of the VM.
assert(protection.xor(0,4294967295)==4294967295)
assert(protection.xor(23063,42405)==65458)
local first,second=protection.digest('operand-block',12345)
local changedFirst,changedSecond=protection.digest('operane-block',12345)
assert(first~=changedFirst or second~=changedSecond,'paired block hash failed to notice a byte change')
local keyedFirst,keyedSecond=protection.digest('operand-block',12346)
assert(first~=keyedFirst or second~=keyedSecond,'block domain key had no effect')
local vectorSource='local __ovm_buffer,__ovm_bxor,__ovm_floor=buffer,bit32.bxor,math.floor\n'..protection.runtimeSource()
for _,vector in ipairs({{'',0},{'operand-block',12345},{string.rep('\0',17),1},
    {string.rep('\255',31),4294967295},{'\0\255\128\1\127\254',2147483646}}) do
    local data,key=vector[1],vector[2]
    local expectedFirst,expectedSecond=protection.digest(data,key)
    local literal='"'..data:gsub('.',function(byte) return string.format('\\%03d',byte:byte()) end)..'"'
    vectorSource=vectorSource..'\ndo local data=buffer.fromstring('..literal..'); local first,second=__ovm_blockdigest(data,0,buffer.len(data),'
        ..string.format('%.0f',key)..'); assert(first=='..string.format('%.0f',expectedFirst)
        ..' and second=='..string.format('%.0f',expectedSecond)..',"host/runtime digest mismatch") end'
end
fixture('digest_vectors',vectorSource)
local hookSetup=guards.hooks('identity','getfenv()')
fixture('frozen_hook_references',hookSetup..[[
assert(table.isfrozen(__ovm_guardrefs),'anti-hook expected references remained mutable')
local success=pcall(function() __ovm_guardrefs[1]=function() end end)
assert(not success,'anti-hook snapshot accepted replacement')
]])

for _,profile in ipairs({'fast','balanced','max'}) do
    local _,stats=obfuscator.obfuscate('return 42',{seed=1,profile=profile,main=false})
    assert(stats.settings.lazyInstructions==(profile~='fast'),'instruction laziness profile default')
    assert(stats.settings.perPrototypeOpcodes==(profile~='fast'),'prototype opcode profile default')
    assert(stats.settings.instructionCache=='prototype','instruction cache default')
end
for _,invalid in ipairs({{lazyInstructions=1},{perPrototypeOpcodes='yes'},
    {instructionBlockSize=0},{instructionBlockSize=257},{instructionBlockSize=1.5},
    {instructionCache='invalid'}}) do
    invalid.seed=1; invalid.profile='fast'; invalid.main=false
    assert(not pcall(obfuscator.obfuscate,'return 42',invalid),'invalid instruction protection options accepted')
end
local noDiagnostic=obfuscator.obfuscate('return 42',settings({debugBlocks=false,debugGuards=false}))
assert(not noDiagnostic:find('__verity_block',1,true),'block observer leaked without opt-in')

local observe=[[
local observed={}
environment.__verity_block=function(layer,prototype,block,data)
    assert(typeof(data)=='buffer')
    if layer~=1 then return end
    observed[prototype]=observed[prototype] or {}
    observed[prototype][block]=(observed[prototype][block] or 0)+1
end
local function observations()
    local count=0
    for _,blocks in pairs(observed) do for _,hits in pairs(blocks) do count+=hits end end
    return count
end
]]
for _,cache in ipairs({'prototype','execution','none'}) do
    for _,main in ipairs({false,true}) do
        local name='cache_'..cache..(main and '_main' or '_single')
        harness(name,'return function() return 42,nil end',settings({instructionCache=cache,main=main,instructionBlockSize=main and 32 or 4}),observe,
            'local returned=protected(); local before=observations(); '
            ..'local first=table.pack(returned()); local afterFirst=observations(); '
            ..'assert(first.n==2 and first[1]==42 and first[2]==nil and afterFirst>before); '
            ..'local second=table.pack(returned()); local afterSecond=observations(); '
            ..'assert(second.n==2 and second[1]==42 and second[2]==nil); '
            ..(cache=='prototype' and 'assert(afterSecond==afterFirst,"prototype block cache was not reused")'
                or 'assert(afterSecond-afterFirst==afterFirst-before,"frame block cache escaped its activation")'))
    end
end

local unusedChild=plainPrototype()
local cold={code={{op='LOADK',1,1,0,0},{op='JMP',6,0,0,0},
    {op='LOADK',1,2,0,0},{op='JMP',6,0,0,0},{op='LOADK',1,3,0,0},{op='RETURN1',1,0,0,0}},
    constants={{kind='number',value=42},{kind='number',value=99},{kind='number',value=111}},
    children={unusedChild},upvalues={},params={},slots=0,registers=1,vararg=false,boxed={},chunkname='cold-blocks.luau'}
local coldSettings=settings({instructionBlockSize=2,optimize=false})
local coldCode=build.render(cold,util.rng(12345),coldSettings)
harness('cold_blocks',nil,nil,observe..[[
local rootPrototype,childPrototype
environment.__verity_guard=function(layer,prototypes)
    assert(layer==1)
    for _,prototype in ipairs(prototypes) do
        if #prototype.children>0 then
            rootPrototype=prototype.id; childPrototype=prototype.children[1]
        end
    end
end
]],[[
assert(protected()==42)
assert(rootPrototype and childPrototype)
assert(observed[rootPrototype][1]==1 and observed[rootPrototype][2]==nil and observed[rootPrototype][3]==1,
    'unreachable instruction block was materialized')
assert(observed[childPrototype]==nil,'unused prototype was materialized')
]],coldCode)

local loopChild={code={{op='LOADK',1,1,0,0},{op='LOADK',2,2,0,0},{op='LOADK',3,3,0,0},
    {op='BIN',1,1,2,1},{op='BIN',4,1,3,11},{op='JMPIF',4,4,1,0},{op='RETURN1',1,0,0,0}},
    constants={{kind='number',value=0},{kind='number',value=1},{kind='number',value=3}},
    children={},upvalues={},params={},slots=0,registers=4,vararg=false,boxed={},chunkname='cache-loop.luau'}
for _,cache in ipairs({'prototype','execution','none'}) do
    local root={code={{op='CLOSURE',1,1,0,0},{op='RETURN1',1,0,0,0}},constants={},children={loopChild},
        upvalues={},params={},slots=0,registers=1,vararg=false,boxed={},chunkname='cache-loop-root.luau'}
    local code=build.render(root,util.rng(12345),settings({instructionCache=cache,instructionBlockSize=2,optimize=false}))
    local repeats=cache=='none' and 3 or 1
    harness('loop_cache_'..cache,nil,nil,observe..[[
local childPrototype
environment.__verity_guard=function(layer,prototypes)
    assert(layer==1)
    for _,prototype in ipairs(prototypes) do if #prototype.children>0 then childPrototype=prototype.children[1] end end
end
]],'local returned=protected(); assert(returned()==3); assert(childPrototype); '
        ..'assert(observed[childPrototype][2]=='..repeats..' and observed[childPrototype][3]=='..repeats
        ..',"cache mode did not retain or discard visited loop blocks"); '
        ..'assert(returned()==3); assert(observed[childPrototype][2]=='..(cache=='prototype' and repeats or repeats*2)
        ..',"cache mode escaped its intended lifetime")',code)
end

for _,compact in ipairs({true,false}) do
    for _,perPrototype in ipairs({true,false}) do
        local name=(compact and 'compact' or 'fixed')..(perPrototype and '_mapped' or '_identity')
        harness(name,'local function f(n) if n==0 then return 42,nil end; return f(n-1) end; return f(4)',
            settings({compact=compact,perPrototypeOpcodes=perPrototype}),nil,
            'local result=table.pack(protected()); assert(result.n==2 and result[1]==42 and result[2]==nil)')
    end
end
for _,compact in ipairs({true,false}) do
    harness('mapped_eager_'..(compact and 'compact' or 'fixed'),'return 42,nil',
        settings({lazyInstructions=false,perPrototypeOpcodes=true,compact=compact}),nil,
        'local result=table.pack(protected()); assert(result.n==2 and result[1]==42 and result[2]==nil)')
end
for _,seed in ipairs({1,2147483646}) do
    harness('seed_'..seed,'return 42',settings({seed=seed}),nil,'assert(protected()==42)')
end
harness('yield_resume','return coroutine.create(function() coroutine.yield("pause",nil); return 42,nil end)',
    settings({instructionCache='execution'}),nil,[[
local co=protected()
local paused=table.pack(coroutine.resume(co))
assert(paused.n==3 and paused[1] and paused[2]=='pause' and paused[3]==nil)
local returned=table.pack(coroutine.resume(co))
assert(returned.n==3 and returned[1] and returned[2]==42 and returned[3]==nil)
]])

local markerSetup=[[
local marked=false
environment.mark=function() marked=true end
]]
harness('tamper_decoded','mark(); return 42',settings(),markerSetup..[[
local observed=false
environment.__verity_block=function(layer,prototype,block,data)
    if layer~=1 then return end
    observed=true
    buffer.writeu8(data,0,(buffer.readu8(data,0)+1)%256)
end
]],'local result=table.pack(pcall(protected)); assert(observed and not result[1] and not marked,"decoded block ran before its guard")')
harness('tamper_decoded_operand','mark(); return 42',settings(),markerSetup..[[
local observed=false
environment.__verity_block=function(layer,prototype,block,data)
    if layer~=1 then return end
    observed=true
    assert(buffer.len(data)>1)
    buffer.writeu8(data,1,(buffer.readu8(data,1)+1)%256)
end
]],'local result=table.pack(pcall(protected)); assert(observed and not result[1] and not marked,"altered operand ran before its guard")')
harness('tamper_cipher','mark(); return 42',settings({minify=false}),markerSetup..[[
local observed=false
environment.__verity_guard=function(layer,prototypes,data)
    if layer~=1 then return end
    observed=true
    for _,prototype in ipairs(prototypes) do
        if prototype.blocks and prototype.blocks[1] then
            local offset=prototype.blocks[1].offset
            buffer.writeu8(data,offset,(buffer.readu8(data,offset)+1)%256)
        end
    end
end
]],'local result=table.pack(pcall(protected)); assert(observed and not result[1] and not marked,"corrupt cipher block ran")')

-- Rebuild the outer transport checksum so corruption reaches the structural
-- loader and block checks rather than stopping at the transport checksum.
for _,version in ipairs({2,3}) do
    local source,configuration,meta=wire(plainPrototype(),{version=version,compact=false})
    local details=meta.protection.prototypes[1]
    local offsets=details.offsets
    harness('wire_valid_'..version,nil,nil,nil,'assert(protected()==42)',runtime.render(configuration))
    local fields={'paramsCount','slots','registers','boxedCount','upvaluesCount','childrenCount','constantsCount','codeCount'}
    for _,field in ipairs(fields) do
        mutated('wire_'..version..'_'..field,replace(source,assert(offsets[field]),u32(4294967295)),configuration)
    end
    mutated('wire_'..version..'_prototypes',replace(source,9,u32(4294967295)),configuration)
    mutated('wire_'..version..'_vararg',replace(source,offsets.vararg,string.char(2)),configuration)
    local tagOffset=offsets.constantsCount+4
    mutated('wire_'..version..'_constant_tag',replace(source,tagOffset,string.char(6)),configuration)
    mutated('wire_'..version..'_constant_width',replace(source,tagOffset+1,string.char(3)),configuration)
    if version==3 then
        for _,field in ipairs({'mapCount','blockSize','blockCount'}) do
            mutated('wire_3_'..field,replace(source,offsets[field],u32(4294967295)),configuration)
        end
        mutated('wire_3_width',replace(source,offsets.width,string.char(3)),configuration)
        mutated('wire_3_duplicate_map',replace(source,offsets.mapEntries+2,source:sub(offsets.mapEntries+1,offsets.mapEntries+1)),configuration)
        local invalidCanonical=0
        local valid={}
        for _,ids in pairs(configuration.aliases) do for _,id in ipairs(ids) do valid[id]=true end end
        while valid[invalidCanonical] do invalidCanonical=invalidCanonical+1 end
        mutated('wire_3_invalid_map',replace(source,offsets.mapEntries+1,string.char(invalidCanonical)),configuration)
        local block=details.blocks[1]
        mutated('wire_3_block_bytes',replace(source,block.headerOffset,u32(4294967295)),configuration)
        mutated('wire_3_block_digest',replace(source,block.headerOffset+4,u32((block.digest1+1)%4294967296)),configuration)
        mutated('wire_3_key_zero',replace(source,offsets.key,u32(0)),configuration)
        for case=1,16 do
            local rng=util.rng(104729+case)
            local offset=block.offset+rng:int(0,block.size-1)
            local changed=(source:byte(offset+1)+rng:int(1,255))%256
            mutated('fuzz_cipher_'..case,replace(source,offset,string.char(changed)),configuration)
        end
    else
        local offset=assert(details.instructionOffset)
        mutated('wire_2_register_zero',replace(source,offset+1,u32(0)),configuration)
        mutated('wire_2_constant_index',replace(source,offset+5,u32(2)),configuration)
        mutated('wire_2_unknown_opcode',replace(source,offset,string.char(0)),configuration)
    end
    for case=1,8 do
        local cut=util.rng(version*65537+case):int(0,#source-1)
        mutated('fuzz_truncate_'..version..'_'..case,source:sub(1,cut),configuration)
    end
end

local child=plainPrototype()
child.upvalues={{kind='local',index=1}}
local tree=plainPrototype()
tree.slots=1; tree.children={child}
local treeSource,treeConfig,treeMeta=wire(tree,{version=3,compact=true})
local rootDetails,childDetails=treeMeta.protection.prototypes[1],treeMeta.protection.prototypes[2]
mutated('tree_root_cycle',replace(treeSource,rootDetails.offsets.childrenCount+4,u32(1)),treeConfig)
mutated('tree_child_missing',replace(treeSource,rootDetails.offsets.childrenCount+4,u32(3)),treeConfig)
mutated('tree_capture_range',replace(treeSource,childDetails.offsets.upvaluesCount+5,u32(2)),treeConfig)

-- The branch/range contract must be checked even when the attacker recomputes
-- the transport checksum; these are well-formed bytes with invalid IR values.
local invalidIR={
    {name='branch_outside',constants={{kind='string',value='touch'}},
        code={{op='GETGLOBAL',1,1,0,0},{op='CALLF0',1,0,0,0},{op='JMP',5,0,0,0},{op='RETURN1',1,0,0,0}}},
    {name='argument_range',registers=2,constants={{kind='string',value='touch'},{kind='number',value=42}},
        code={{op='GETGLOBAL',1,1,0,0},{op='LOADK',2,2,0,0},{op='CALLF0',1,2,2,0},{op='RETURN1',2,0,0,0}}},
    {name='stream_fallthrough',code={{op='LOADK',1,1,0,0}}},
    {name='vararg_disabled',code={{op='VARARG',1,0,0,0},{op='RETURN1',1,0,0,0}}},
    {name='global_name',code={{op='GETGLOBAL',1,1,0,0},{op='RETURN1',1,0,0,0}}},
}
for _,case in ipairs(invalidIR) do
    local prototype=plainPrototype(); prototype.code=case.code
    prototype.constants=case.constants or prototype.constants
    prototype.registers=case.registers or prototype.registers
    local source,configuration=wire(prototype,{version=2,compact=false})
    mutated('ir_'..case.name,source,configuration)
end

local _,transportConfig=wire(plainPrototype(),{version=2,compact=false})
for _,transport in ipairs({'literal','base91'}) do
    transportConfig.transport=transport
    capFixture('cap_transport_'..transport,transportConfig,'payloadBytes',#transportConfig.payload-1,#transportConfig.payload,'allocation')
end
local expanded=plainPrototype()
expanded.constants={{kind='string',value=string.rep('A',4096)}}
local _,compressedConfig=wire(expanded,{version=2,compact=false,compression=true})
assert(compressedConfig.compressed and #compressedConfig.payload<compressedConfig.unpackedSize,'compression cap probe needs expansion')
capFixture('cap_decompression',compressedConfig,'payloadBytes',#compressedConfig.payload,compressedConfig.unpackedSize,'allocation')
local _,legacyTextConfig=wire(expanded,{version=1,compact=false})
capFixture('cap_legacy_text',legacyTextConfig,'constantBytes',4095,4096,'read')

util.write('tests/.generated/security_manifest.txt',table.concat(manifest,'\n')..'\n')
print('Security host checks and '..#manifest..' fixtures OK')

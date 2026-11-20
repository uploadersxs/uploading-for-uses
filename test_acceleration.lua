package.path='./?.lua;./?/init.lua;'..package.path
local obfuscator=require('src.obfuscator')
local util=require('src.util')
local lexer=require('src.lexer')
local manifest={}

local privateLimits={payloadBytes=true,prototypes=true,instructions=true,
    constantBytes=true,blockBytes=true,mapEntries=true,tableEntries=true,
    arrayIndex=true,totalConstants=true,totalInstructions=true,deadline=true,ticks=true}
local function verifyInternalNames(output,stats)
    for _,token in ipairs(lexer.lex(output,'<native helper output>')) do
        if token.kind=='name' then
            assert(not privateLimits[token.value], 'generated private field retained '..token.value)
            assert(not token.value:match('^__ovm_'),'generated local retained '..token.value)
        end
    end
    -- Public statistics remain readable even though emitted metadata is renamed.
    assert(type(stats.loaderLimits.payloadBytes)=='number' and type(stats.loaderLimits.instructions)=='number')
end

local function fixture(name,output,setup,body)
    local source=[[
local nativeEnvironment=getfenv()
local environment=setmetatable({}, {__index=nativeEnvironment})
]]..(setup or '')..'\nlocal function protected(...)\n'..output
        ..'\nend\nsetfenv(protected,environment)\n'..body
        ..'\nprint('..string.format('%q','acceleration '..name..' OK')..')\n'
    util.write('tests/.generated/acceleration_'..name..'.luau',source)
    manifest[#manifest+1]=name
end

-- The large constant is in an uncalled function. Startup must still load its
-- ciphertext, while neither accelerated byte-work nor packing may eagerly
-- materialize it. Original caller arguments/results retain every nil.
local cold=string.rep('COLD_PAYLOAD_9x!',4096)
assert(#cold==65536)
local program='assert(__ovm_accelerators=="user global")\n'
    ..'local function cold() return '..string.format('%q',cold)..' end\n'
    ..'local function lookup() return marker,nil end\nreturn cold,lookup,...'
local setup=[[
environment.marker='original'
environment.__ovm_accelerators='user global'
local materializations=0
local privateNames={payloadBytes=true,prototypes=true,instructions=true,
    constantBytes=true,blockBytes=true,mapEntries=true,tableEntries=true,
    arrayIndex=true,totalConstants=true,totalInstructions=true,deadline=true,ticks=true}
environment.__verity_constant=function(layer,prototype,index,value)
    if layer==1 and type(value)=='string' and #value==65536 then materializations+=1 end
    if layer==2 and type(value)=='string' then
        assert(not privateNames[value],'inner packed runtime retained a semantic private field name')
    end
end
]]
local body=[[
local results=table.pack(protected(nil,'argument',nil,false))
assert(results.n==6 and type(results[1])=='function' and type(results[2])=='function')
assert(results[3]==nil and results[4]=='argument' and results[5]==nil and results[6]==false)
assert(materializations==0,'cold user constant materialized during startup')
local text=results[1]()
assert(#text==65536 and text:sub(1,16)=='COLD_PAYLOAD_9x!')
assert(materializations==1,'cold user constant did not materialize once')
assert(results[1]()==text and materializations==1,'prototype cache changed')
local initial=table.pack(results[2]())
assert(initial.n==2 and initial[1]=='original' and initial[2]==nil)
setfenv(results[2],setmetatable({marker='updated'}, {__index=environment}))
local changed=table.pack(results[2]())
assert(changed.n==2 and changed[1]=='updated' and changed[2]==nil,'closure environment changed')
assert(environment.__ovm_accelerators=='user global','native bridge leaked into user environment')
]]

for _,variant in ipairs({
    {name='max_native',main=true,nativeHelpers=true},
    {name='max_legacy',main=true,nativeHelpers=false},
    {name='max_single',main=false,nativeHelpers=true},
}) do
    local options={seed=12345,profile='max',main=variant.main,
        nativeHelpers=variant.nativeHelpers,debugConstants=true}
    local output,stats=obfuscator.obfuscate(program,options)
    assert(stats.mainPacked==variant.main,'native helpers changed VM layer count')
    local active=variant.main and variant.nativeHelpers
    assert(stats.settings.nativeHelpers==active,'effective native helper setting changed')
    assert(type(stats.nativeHelpers)=='number' and ((stats.nativeHelpers>0)==active),
        'native helper count does not match effective setting')
    assert(not output:find(cold,1,true),'native helper output exposed a user constant')
    assert(not output:find('loadstring',1,true),'native helpers must not evaluate source')
    verifyInternalNames(output,stats)
    fixture(variant.name,output,setup,body)
end

-- Exercise non-default legacy/eager and fixed-width paths through the bridge.
local numericProgram=[[
local values=table.pack(...)
local bytes='\0\255\128binary'
assert(#bytes==9 and string.byte(bytes,2)==255)
assert(1.25+0.5==1.75 and 1/-0==-math.huge)
return values,bytes,nil,false
]]
for _,variant in ipairs({
    {name='fixed',profile='max',compact=false,lazyConstants=true},
    {name='eager_v2',profile='fast',compact=true,lazyConstants=false,transport='literal'},
}) do
    local output,stats=obfuscator.obfuscate(numericProgram,{seed=12345,main=true,
        profile=variant.profile,nativeHelpers=true,compact=variant.compact,
        lazyConstants=variant.lazyConstants,transport=variant.transport})
    assert(stats.nativeHelpers>0 and stats.settings.nativeHelpers)
    verifyInternalNames(output,stats)
    fixture(variant.name,output,nil,[=[
local results=table.pack(protected(nil,false,'argument',nil))
assert(results.n==4 and results[3]==nil and results[4]==false)
local values=results[1]
assert(values.n==4 and values[1]==nil and values[2]==false and values[3]=='argument' and values[4]==nil)
assert(results[2]=='\0\255\128binary')
]=])
end

-- Alter already decrypted instructions after tuple capture. Native byte-work
-- must not bypass the VM's exact checks or execute a user effect afterward.
for _,enabled in ipairs({true,false}) do
    local name=enabled and 'tamper_native' or 'tamper_legacy'
    local output=obfuscator.obfuscate('touch(); return 42',{seed=12345,profile='max',
        nativeHelpers=enabled,debugBlocks=true})
    fixture(name,output,[=[
local touched=false
environment.touch=function() touched=true end
environment.__verity_block=function(layer,prototype,index,data)
    if layer==1 then buffer.writeu8(data,0,(buffer.readu8(data,0)+1)%256) end
end
]=],[=[
local result=table.pack(pcall(protected))
assert(not result[1] and not touched,'native byte-work bypassed tuple integrity')
]=])
end

-- Small cipher keys can occur through low-level APIs. They must replace only
-- template parameters, never digits inside unrelated algorithm constants.
do
    local parser=require('src.parser')
    local compiler=require('src.compiler')
    local serialize=require('src.serialize')
    local runtime=require('src.runtime')
    local cipher={key=1,multiplier=65536}
    local opcodes=serialize.opcodes(util.rng(99))
    local payload,checksum=serialize.encode(compiler.compile(parser.parse('return 42')),opcodes,99,{cipher=cipher})
    local rendered,_,helpers=runtime.render({payload=payload,checksum=checksum,seed=99,
        opcodes=opcodes,cipher=cipher,nativeHelpers=true})
    local packed=obfuscator.obfuscate('return function(__ovm_accelerators, ...)\n'..rendered..'\nend',
        {seed=99,profile='fast',main=false,junk=0})
    fixture('cipher_small_key',packed,'local helperTable='..helpers,
        'assert(protected()(helperTable)==42,"small cipher key corrupted native algorithm constants")')
end

-- Compile generated factories in isolation and reject implicit reads of VM
-- internals. A missing factory capture must fail here instead of becoming a
-- nil global only when its rare wire/cache path executes.
local function assertExplicitCaptures(helpers,label)
    local parser=require('src.parser')
    local compiler=require('src.compiler')
    local root=compiler.compile(parser.parse('return '..helpers,'<native captures>'))
    local function visit(prototype,path)
        for _,instruction in ipairs(prototype.code) do
            if instruction.op=='GETGLOBAL' or instruction.op=='SETGLOBAL' then
                local index=instruction.op=='GETGLOBAL' and instruction[2] or instruction[1]
                local value=prototype.constants[index].value
                if value:match('^__ovm_') and value~='__ovm_nativecheckpoint' and value~='__ovm_nativebindcheckpoint' then
                    util.write('tests/.generated/acceleration_capture_error.lua','return '..helpers)
                    error('native helper has an uncaptured VM dependency: '..value..' in '..label..' '..path)
                end
            end
        end
        for index,child in ipairs(prototype.children) do visit(child,path..'/'..index) end
    end
    visit(root,'root')
end

do
    local parser=require('src.parser')
    local compiler=require('src.compiler')
    local serialize=require('src.serialize')
    local runtime=require('src.runtime')
    local source=[=[
local arguments=table.pack(...)
assert(arguments.n==3 and arguments[1]==nil and arguments[2]=='argument' and arguments[3]==nil)
local text='\0\255\128binary'
local function nested(n)
    if n==0 then return text,1.75,nil,false end
    return nested(n-1)
end
return nested(3)
]=]
    for version=1,3 do
        for _,compact in ipairs(version==1 and {false} or {true,false}) do
            for _,lazyConstants in ipairs(version==1 and {false} or {true,false}) do
                for _,lazyInstructions in ipairs(version==3 and {true,false} or {false}) do
                    local name='wire_v'..version..(compact and '_compact' or '_fixed')
                        ..(lazyConstants and '_lazy_constants' or '_eager_constants')
                        ..(lazyInstructions and '_lazy_instructions' or '_eager_instructions')
                    local rng=util.rng(12345)
                    local opcodes,order,aliases=serialize.opcodes(rng)
                    local cipher={key=12345,multiplier=48271}
                    local prototype=compiler.compile(parser.parse(source))
                    if version>=2 then require('src.optimizer').apply(prototype,{}) end
                    local payload,checksum,bytes,_,entry,meta=serialize.encode(
                        prototype,opcodes,12345,
                        {version=version,compact=compact,lazyConstants=lazyConstants,
                            lazyInstructions=lazyInstructions,perPrototypeOpcodes=version==3,
                            instructionBlockSize=4,constantKey=271828,cipher=cipher,
                            aliases=aliases,rng=rng,compression=true,adaptiveCompression=true})
                    local rendered,_,helpers=runtime.render({payload=payload,checksum=checksum,seed=12345,
                        opcodes=opcodes,order=order,aliases=aliases,cipher=cipher,entry=entry,
                        version=version,compact=compact,lazyConstants=lazyConstants,constantKey=271828,
                        lazyInstructions=lazyInstructions,perPrototypeOpcodes=version==3,
                        instructionBlockSize=4,instructionCache='prototype',nativeHelpers=true,
                        compressed=meta.compressed,unpackedSize=bytes,limits=meta.limits,
                        antiTamper=true,antiHooks='identity',debugConstants=version>=2,debugBlocks=lazyInstructions,
                        payloadDigest1=meta.payloadDigest1,payloadDigest2=meta.payloadDigest2,
                        payloadDigestKey=meta.payloadDigestKey})
                    assertExplicitCaptures(helpers,name)
                    local packed=obfuscator.obfuscate('return function(__ovm_accelerators, ...)\n'..rendered..'\nend',
                        {seed=12345,profile='fast',main=false,junk=0})
                    fixture(name,packed,'local helperTable='..helpers,[=[
local results=table.pack(protected()(helperTable,nil,'argument',nil))
assert(results.n==4 and results[1]=='\0\255\128binary' and results[2]==1.75 and results[3]==nil and results[4]==false)
]=])
                end
            end
        end
    end
end

for _,bad in ipairs({'true',1,{},'off'}) do
    assert(not pcall(obfuscator.obfuscate,'return 42',{seed=1,profile='max',nativeHelpers=bad}),
        'nativeHelpers must accept booleans only')
end
util.write('tests/.generated/acceleration_manifest.txt',table.concat(manifest,'\n')..'\n')
print('Acceleration host checks OK')

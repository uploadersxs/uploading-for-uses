package.path='./?.lua;./?/init.lua;'..package.path
local obfuscator=require('src.obfuscator')
local lexer=require('src.lexer')
local util=require('src.util')
local build=require('src.build')

local function emit(name,source,options)
    local output,stats=obfuscator.obfuscate(source,options)
    util.write('tests/.generated/guards_'..name..'.luau',output)
    return output,stats
end
local function options(main,hooks,tamper)
    return {seed=12345,profile='fast',main=main,antiHooks=hooks,
        antiTamper=tamper~=false,antiBeautify=false,chunkname='guards.luau'}
end

for _,profile in ipairs({'fast','balanced','max'}) do
    local _,stats=obfuscator.obfuscate('return 42',{seed=1,profile=profile,main=false})
    assert(stats.settings.antiTamper==(profile~='fast'),'profile tamper default')
    assert(stats.settings.antiHooks==(profile=='fast' and 'off' or 'identity'),'profile hook default')
    assert(stats.settings.antiBeautify==false,'beautify must be opt-in')
end
local _,overrides=obfuscator.obfuscate('return 42',{seed=1,profile='max',main=false,
    antiTamper=false,antiHooks='off',antiBeautify=false})
assert(not overrides.settings.antiTamper and overrides.settings.antiHooks=='off')
for _,bad in ipairs({{antiTamper='true'},{antiTamper=1},{antiHooks=true},{antiHooks='invalid'},
    {antiBeautify=1},{antiBeautify=true,minify=false},{antiBeautify=true,debug=true}}) do
    bad.seed=1; bad.profile='fast'; bad.main=false
    assert(not pcall(obfuscator.obfuscate,'return 42',bad),'invalid guard options must fail')
end
for _,main in ipairs({false,true}) do
    for _,combination in ipairs({{hooks='identity',beautify=false},{hooks='off',beautify=true},
        {hooks='identity',beautify=true}}) do
        local preserved=obfuscator.obfuscate('return 42',{seed=1,profile='fast',main=main,
            rename=false,antiHooks=combination.hooks,antiBeautify=combination.beautify})
        for _,identifier in ipairs({'__ovm_entryenv','__ovm_run','__ovm_wrapperenv'}) do
            assert(preserved:find(identifier,1,true),'rename=false guard output lost '..identifier)
        end
    end
end

local normal=util.read('tests/fixtures/guards.luau')
for _,variant in ipairs({'single','main','strict_single','strict_main'}) do
    local main=variant=='main' or variant=='strict_main'
    local hooks=variant:find('strict',1,true) and 'strict' or 'identity'
    emit('normal_'..variant,normal,options(main,hooks))
end

local function harness(name,program,settings,setup,body,rendered)
    local output=rendered or obfuscator.obfuscate(program,settings)
    local prefix=[[
local nativeEnv=getfenv()
local environment=setmetatable({}, {__index=nativeEnv})
local mathCopy={}
for key,value in pairs(math) do mathCopy[key]=value end
environment.math=mathCopy
local originalFloor=mathCopy.floor
local function replaceDependency()
    mathCopy.floor=function(value) return originalFloor(value) end
end

environment.replaceDependency=replaceDependency
]]
    local source=prefix..(setup or '')..'\nlocal function protected(...)\n'..output
        ..'\nend\nsetfenv(protected,environment)\n'..body
        ..'\nprint('..string.format('%q','guards '..name..' OK')..')\n'
    util.write('tests/.generated/guards_'..name..'.luau',source)
end

-- Direct IR isolates the immediate metamethod boundary. A final wrapper check
-- or a later native call must not hide that an in-place instruction overwrote
-- its source, or that a callback removed its own metatable before returning.
local metamethodCases={
    {name='un_alias',code={{op='GETGLOBAL',1,1,0,0},{op='UN',1,1,1,0},{op='RETURN1',1,0,0,0}},
        setup='environment.operand=setmetatable({}, {__unm=function() replaceDependency(); return 7 end})',result='7'},
    {name='tostring_alias',code={{op='GETGLOBAL',1,1,0,0},{op='TOSTRING',1,1,0,0},{op='RETURN1',1,0,0,0}},
        setup='environment.operand=setmetatable({}, {__tostring=function() replaceDependency(); return "seven" end})',result='"seven"'},
    {name='index_alias',code={{op='GETGLOBAL',1,1,0,0},{op='LOADK',2,2,0,0},{op='GETTABLE',1,1,2,0},{op='RETURN1',1,0,0,0}},
        setup='environment.operand=setmetatable({}, {__index=function(self) setmetatable(self,nil); replaceDependency(); return 7 end})',result='7'},
    {name='index_detach',code={{op='GETGLOBAL',1,1,0,0},{op='LOADK',2,2,0,0},{op='GETTABLE',3,1,2,0},{op='RETURN1',3,0,0,0}},
        setup='environment.operand=setmetatable({}, {__index=function(self) setmetatable(self,nil); replaceDependency(); return 7 end})',result='7'},
    {name='newindex_detach',code={{op='GETGLOBAL',1,1,0,0},{op='LOADK',2,2,0,0},{op='LOADK',3,3,0,0},{op='SETTABLE',1,2,3,0},{op='RETURN1',3,0,0,0}},
        setup='environment.operand=setmetatable({}, {__newindex=function(self,key,value) setmetatable(self,nil); replaceDependency(); rawset(self,key,value) end})',result='7'},
    {name='global_index_detach',code={{op='GETGLOBAL',1,4,0,0},{op='RETURN1',1,0,0,0}},
        setup='setmetatable(environment,{__index=function(self,key) if key=="trigger" then setmetatable(self,nil); replaceDependency(); return 7 end; return nativeEnv[key] end})',result='7'},
    {name='global_newindex_detach',code={{op='LOADK',1,3,0,0},{op='SETGLOBAL',4,1,0,0},{op='RETURN1',1,0,0,0}},
        setup='setmetatable(environment,{__index=nativeEnv,__newindex=function(self,key,value) setmetatable(self,nil); replaceDependency(); rawset(self,key,value) end})',result='7'},
}
for _,case in ipairs(metamethodCases) do
    for _,hooks in ipairs({'identity','off'}) do
        local settings={seed=12345,junk=0,cff=false,opaque=false,compression=false,
            optimize=false,compact=true,lazyConstants=false,prune=true,antiTamper=false,
            antiHooks=hooks,layer='user',chunkname='metamethod-guard.luau'}
        local proto={code={{op='GETGLOBAL',4,5,0,0,line=1},{op='LOADK',5,6,0,0,line=1},
            {op='LOADK',6,3,0,0,line=1}},constants={{kind='string',value='operand'},{kind='string',value='key'},
            {kind='number',value=7},{kind='string',value='trigger'},{kind='string',value='progress'},
            {kind='number',value=1}},children={},upvalues={},params={},
            vararg=false,slots=0,registers=6,boxed={},lines={},chunkname='metamethod-guard.luau'}
        for pc,instruction in ipairs(case.code) do
            if instruction.op=='RETURN1' then
                proto.code[#proto.code+1]={op='SETTABLE',4,5,6,0,line=1}
            end
            proto.code[#proto.code+1]={op=instruction.op,instruction[1],instruction[2],instruction[3],instruction[4],line=1}
        end
        local output=build.render(proto,util.rng(settings.seed),settings)
        local label='meta_'..case.name..'_'..hooks
        local body='local outcome=table.pack(pcall(protected)); '
        if hooks=='identity' then
            body=body..'assert(not outcome[1] and environment.progress[1]==nil,"metamethod hook escaped before subsequent write")'
        else body=body..'assert(outcome.n==2 and outcome[1] and outcome[2]=='..case.result
            ..' and environment.progress[1]==7,"metamethod result or subsequent write changed")' end
        harness(label,nil,nil,'environment.progress={}\n'..case.setup,body,output)
    end
end

for _,main in ipairs({false,true}) do
    local layer=main and 'main' or 'single'
    for _,hooks in ipairs({'identity','off'}) do
        local guarded=hooks~='off'
        local settings=options(main,hooks,false)
        local label=layer..'_'..hooks
        harness('call_'..label,'replaceDependency(); return "done",nil',settings,nil,
            guarded and 'local outcome=table.pack(pcall(protected)); assert(not outcome[1],"hook after call escaped")'
                or 'local outcome=table.pack(pcall(protected)); assert(outcome.n==3 and outcome[1] and outcome[2]=="done" and outcome[3]==nil)')
        harness('frame_'..label,'return function() return "done",nil end',settings,nil,
            'local returned=protected(); replaceDependency(); local outcome=table.pack(pcall(returned)); '
                ..(guarded and 'assert(not outcome[1],"hook at activation escaped")'
                    or 'assert(outcome.n==3 and outcome[1] and outcome[2]=="done" and outcome[3]==nil)'))
        harness('yield_'..label,'return coroutine.create(function() coroutine.yield("pause",nil); return "done",nil end)',settings,nil,
            'local co=protected(); local paused=table.pack(coroutine.resume(co)); '
                ..'assert(paused.n==3 and paused[1] and paused[2]=="pause" and paused[3]==nil); '
                ..'replaceDependency(); local resumed=table.pack(coroutine.resume(co)); '
                ..(guarded and 'assert(not resumed[1],"hook after resume escaped")'
                    or 'assert(resumed.n==3 and resumed[1] and resumed[2]=="done" and resumed[3]==nil)'))
    end
end

for _,hooks in ipairs({'identity','strict'}) do
    local label='prehook_'..hooks
    harness(label,'return 42,nil',options(false,hooks,false),
        'mathCopy.floor=function(value) return originalFloor(value) end',
        'local outcome=table.pack(pcall(protected)); '..(hooks=='strict'
            and 'assert(not outcome[1],"strict accepted Lua dependency wrapper")'
            or 'assert(outcome.n==3 and outcome[1] and outcome[2]==42 and outcome[3]==nil)'))
end
for _,hooks in ipairs({'identity','strict'}) do
    local setup=[[
local tableCopy,stringCopy={},{}
for key,value in pairs(table) do tableCopy[key]=value end
for key,value in pairs(string) do stringCopy[key]=value end
tableCopy.freeze=nil; tableCopy.isfrozen=nil
local originalFormat=stringCopy.format
stringCopy.format=function(...) return originalFormat(...) end
environment.table=tableCopy; environment.string=stringCopy
]]
    local body='local outcome=table.pack(pcall(protected)); '..(hooks=='strict'
        and 'assert(not outcome[1],"strict skipped Lua wrapper after nil dependency holes")'
        or 'assert(outcome.n==3 and outcome[1] and outcome[2]=="42" and outcome[3]==nil)')
    harness('holes_'..hooks,'return string.format("%d",42),nil',options(false,hooks,false),setup,body)
end

local guardSettings=options(false,'off',true)
guardSettings.debugGuards=true; guardSettings.minify=false
local capture=[[
local observedProtos,observedBytes
local invoked=false
environment.__verity_guard=function(layer,prototypes,bytes)
    assert(layer==1)
    invoked=true; observedProtos=prototypes; observedBytes=bytes
end
local function mutateInstructions()
    assert(invoked and observedBytes)
    for _,prototype in ipairs(observedProtos) do
        for pc=1,prototype.count-1 do
            local offset=prototype.sites[pc]
            if prototype.sites[pc+1]-offset>1 then
                buffer.writeu8(observedBytes,offset+1,(buffer.readu8(observedBytes,offset+1)+1)%256)
            end
        end
    end
end
environment.mutateInstructions=mutateInstructions
]]
harness('tamper_loaded','return 42',guardSettings,capture..[[
local captureOriginal=environment.__verity_guard
environment.__verity_guard=function(...)
    captureOriginal(...)
    mutateInstructions()
end
]],'local outcome=table.pack(pcall(protected)); assert(invoked and not outcome[1],"mutated loaded bytecode escaped")')
harness('tamper_after_call','mutateInstructions(); return 42',guardSettings,capture,
    'local outcome=table.pack(pcall(protected)); assert(invoked and not outcome[1],"mutated active bytecode escaped")')
harness('metadata_frozen','return 42',guardSettings,capture,
    'assert(protected()==42 and invoked); if table.isfrozen then '
        ..'for _,prototype in ipairs(observedProtos) do assert(table.isfrozen(prototype),"prototype metadata remained mutable") end end')
harness('metadata_no_probe','return 42',options(false,'off',true),capture,
    'assert(protected()==42 and not invoked,"guard instrumentation escaped its diagnostic option")')
for _,lazy in ipairs({true,false}) do
    local freezeSettings={}
    for key,value in pairs(guardSettings) do freezeSettings[key]=value end
    freezeSettings.lazyConstants=lazy
    local label=lazy and 'freeze_capture_lazy' or 'freeze_capture_eager'
    local setup=[[
local observedProtos,invoked
local tableCopy={}
for key,value in pairs(table) do tableCopy[key]=value end
environment.table=tableCopy
environment.__verity_guard=function(layer,prototypes)
    assert(layer==1)
    invoked=true; observedProtos=prototypes; tableCopy.freeze=nil
end
]]
    local body=[[
assert(protected()==42 and invoked)
assert(table.isfrozen(observedProtos),'prototypes container remained mutable')
for _,prototype in ipairs(observedProtos) do
    assert(table.isfrozen(prototype) and table.isfrozen(prototype.constants)
        and table.isfrozen(prototype.checks),'private metadata remained mutable')
    for _,descriptor in ipairs(prototype.constants) do assert(table.isfrozen(descriptor)) end
    assert(not table.isfrozen(prototype.cache),'mutable constant cache container was frozen')
    if prototype.eager then
        assert(table.isfrozen(prototype.eager))
        for _,value in ipairs(prototype.eager) do assert(table.isfrozen(value)) end
    end
end
]]
    harness(label,'return 42',freezeSettings,setup,body)
end
for _,hooks in ipairs({'identity','strict'}) do
    local label='missing_debug_'..hooks
    harness(label,'return 42,nil',options(false,hooks,false),'environment.debug=false',
        'local outcome=table.pack(pcall(protected)); '..(hooks=='strict'
            and 'assert(not outcome[1],"strict accepted missing debug.info")'
            or 'assert(outcome.n==3 and outcome[1] and outcome[2]==42 and outcome[3]==nil)'))
end

-- Insert formatting outside strings, using the lexer column instead of searching
-- payload characters. The checksum content and language semantics stay intact.
local function insertNewline(output,betweenMarkers)
    local lineStart=assert(output:find('\n',1,true))+1
    local tokens=lexer.lex(output)
    if betweenMarkers then
        -- Final wrapper sentinels have tiny native bodies returning 17 and 29.
        -- Splitting before the second definition preserves its code and changes
        -- only that function's declaration line, regardless of renamed locals.
        for index,token in ipairs(tokens) do
            if token.kind=='return' and tokens[index+1].kind=='number'
                and tokens[index+1].value==29 and tokens[index+2].kind=='end' then
                for first=index-1,1,-1 do
                    if tokens[first].kind=='function' then
                        local position=lineStart+tokens[first].column-1
                        return output:sub(1,position-1)..'\n'..output:sub(position)
                    end
                end
            end
        end
        error('anti-beautify wrapper has no second line sentinel')
    end
    for _,token in ipairs(tokens) do
        if token.line==2 and token.kind=='local' then
            local position=lineStart+token.column-1
            return output:sub(1,position-1)..'\n'..output:sub(position)
        end
    end
    error('guarded runtime has no safe newline insertion point')
end
for _,main in ipairs({false,true}) do
    local layer=main and 'main' or 'single'
    local settings=options(main,'off',false); settings.antiBeautify=true
    local output=emit('beautify_'..layer,'print("guards beautify_'..layer..' OK")',settings)
    util.write('tests/.generated/guards_beautify_'..layer..'_edited.luau',insertNewline(output,true))
    local start=assert(output:find('\n',1,true))+1
    util.write('tests/.generated/guards_beautify_'..layer..'_missing_debug.luau',
        output:sub(1,start-1)..'debug=false;'..output:sub(start))
    settings.antiBeautify=false
    local plain=obfuscator.obfuscate('print("guards formatting_'..layer..' OK")',settings)
    util.write('tests/.generated/guards_formatting_'..layer..'.luau',insertNewline(plain))
end
print('Guard host checks and fixtures OK')

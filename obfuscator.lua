local parser = require('src.parser')
local compiler = require('src.compiler')
local build = require('src.build')
local minify = require('src.minify')
local util = require('src.util')
local guards = require('src.guards')
local scheduler = require('src.scheduler')

-- Only generated runtime tables use these keys. Pack.n remains a native protocol.
local runtimePrivateFields = {
    constants=true,upvalues=true,params=true,children=true,slots=true,registers=true,
    vararg=true,kind=true,index=true,count=true,offset=true,id=true,
    boxed=true,cache=true,eager=true,size=true,hash=true,tag=true,raw=true,
    modulus=true,read=true,write=true,width=true,sites=true,source=true,lines=true,
    checks=true,guardSalt=true,
    checks2=true,constantCount=true,constantSeed=true,operandKeys=true,operandStrides=true,
    opcodeMap=true,blocks=true,blockSize=true,first=true,
    blockDomain=true,data=true,hash1=true,hash2=true,
    payloadBytes=true,prototypes=true,instructions=true,constantBytes=true,
    blockBytes=true,mapEntries=true,tableEntries=true,arrayIndex=true,
    totalConstants=true,totalInstructions=true,deadline=true,ticks=true,
}

local M = {version='1',watermark='-- This file has been protected using zz7 obfuscator v1'}
M.profiles = {
    fast = {main=false,junk=0.05,cff=true,opaque=false,antiTamper=false,antiHooks='off',lazyInstructions=false,perPrototypeOpcodes=false,instructionBlockSize=32},
    balanced = {main=true,junk=0.30,cff=true,opaque=true,antiTamper=true,antiHooks='identity',lazyInstructions=true,perPrototypeOpcodes=true,instructionBlockSize=32},
    max = {main=true,junk=0.65,cff=true,opaque=true,antiTamper=true,antiHooks='identity',lazyInstructions=true,perPrototypeOpcodes=true,instructionBlockSize=16},
}

local function setting(options, profile, key, default)
    local value=options[key]
    if value==nil then value=profile[key] end
    if value==nil then value=default end
    return value
end

function M.obfuscate(source, options)
    local started=os.clock()
    if options==nil then options={} end
    assert(type(options)=='table', 'options must be a table')
    assert(type(source)=='string', 'source must be a string')
    local profileName=options.profile
    if profileName==nil then profileName='balanced' end
    assert(type(profileName)=='string','profile must be fast, balanced or max')
    local profile=assert(M.profiles[profileName], 'profile must be fast, balanced or max')
    local requestedSeed=options.seed
    if requestedSeed==nil then requestedSeed=(os.time()+math.floor(os.clock()*1000000))%2147483646+1 end
    local seed = util.seed(requestedSeed)
    local junk = setting(options,profile,'junk',0.30)
    assert(type(junk)=='number' and junk>=0 and junk<=1, 'junk must be between 0 and 1')
    local constantCache=options.constantCache
    if constantCache==nil then constantCache='prototype' end
    assert(constantCache=='prototype' or constantCache=='execution' or constantCache=='none',
        'constantCache must be prototype, execution or none')
    local lazyInstructions=setting(options,profile,'lazyInstructions',false)
    local perPrototypeOpcodes=setting(options,profile,'perPrototypeOpcodes',false)
    local instructionBlockSize=setting(options,profile,'instructionBlockSize',32)
    local instructionCache=options.instructionCache
    if instructionCache==nil then instructionCache='prototype' end
    assert(type(lazyInstructions)=='boolean','lazyInstructions must be a boolean')
    assert(type(perPrototypeOpcodes)=='boolean','perPrototypeOpcodes must be a boolean')
    assert(type(instructionBlockSize)=='number' and instructionBlockSize%1==0 and instructionBlockSize>=1 and instructionBlockSize<=256,'instructionBlockSize must be an integer between 1 and 256')
    assert(instructionCache=='prototype' or instructionCache=='execution' or instructionCache=='none','instructionCache must be prototype, execution or none')
    local antiTamper=setting(options,profile,'antiTamper',false)
    local antiHooks=setting(options,profile,'antiHooks','off')
    local antiBeautify=setting(options,profile,'antiBeautify',false)
    assert(type(antiTamper)=='boolean','antiTamper must be a boolean')
    assert(antiHooks=='off' or antiHooks=='identity' or antiHooks=='strict',
        'antiHooks must be off, identity or strict')
    assert(type(antiBeautify)=='boolean','antiBeautify must be a boolean')
    assert(not antiBeautify or options.minify~=false,'antiBeautify requires minified output; remove --readable')
    assert(not antiBeautify or options.debug~=true,'antiBeautify is incompatible with debug output; remove --debug/--map')
    local settings = {seed=seed,junk=junk,cff=setting(options,profile,'cff',true)~=false,
        opaque=setting(options,profile,'opaque',true)~=false,
        compression=options.compression~=false,transport=options.transport,
        optimize=options.optimize~=false,compact=options.compact~=false,
        lazyConstants=options.lazyConstants~=false,prune=options.prune~=false,
        debug=options.debug==true,debugConstants=options.debugConstants==true,debugGuards=options.debugGuards==true,
        unbox=options.unbox,reuse=options.reuse,fuse=options.fuse,fixedReturns=options.fixedReturns,layer='user',
        antiTamper=antiTamper,antiHooks=antiHooks,antiBeautify=antiBeautify,minify=options.minify~=false,rename=options.rename~=false,
        constantCache=constantCache,chunkname=options.chunkname or '<input>'}
    settings.lazyInstructions,settings.perPrototypeOpcodes=lazyInstructions,perPrototypeOpcodes
    settings.instructionBlockSize,settings.instructionCache=instructionBlockSize,instructionCache
    settings.debugBlocks=options.debugBlocks==true
    local main=setting(options,profile,'main',true)~=false
    assert(options.nativeHelpers==nil or type(options.nativeHelpers)=='boolean','nativeHelpers must be a boolean')
    settings.nativeHelpers=main and options.nativeHelpers~=false
    local cooperative=options.cooperative
    if cooperative==nil then cooperative=main end
    local scheduling=scheduler.render({cooperative=cooperative,yieldBudgetMs=options.yieldBudgetMs,
        yieldInterval=options.yieldInterval,environment='__ovm_nativeenv'})
    settings.cooperative=scheduling.enabled
    settings.runtimeCooperative=not main and scheduling.enabled
    settings.yieldBudgetMs,settings.yieldInterval=scheduling.budgetMs,scheduling.interval
    local rng = util.rng(seed)
    local timings,stage={outerParse=0,outerCompile=0,outer=0,minify=0},os.clock()
    local ast = parser.parse(source, options.chunkname or '<input>')
    timings.parse=os.clock()-stage; stage=os.clock()
    local proto = compiler.compile(ast,settings)
    timings.compile=os.clock()-stage; stage=os.clock()
    local result,stats,helpers=build.render(proto,rng,settings)
    timings.inner=os.clock()-stage
    stats.mainPacked=main
    if stats.mainPacked then
        local innerBytes=#result
        stage=os.clock()
        if settings.nativeHelpers then result='return function(__ovm_accelerators, ...)\n'..result..'\nend' end
        if options.minify~=false and options.rename~=false then
            local fieldStats
            result,fieldStats=minify.compact(result,{rng=rng,fieldsOnly=true,privateFields=runtimePrivateFields})
            if settings.nativeHelpers then
                helpers=minify.compact(helpers,{rng=rng,fieldsOnly=true,privateFields=runtimePrivateFields,names=fieldStats.names})
            end
        end
        local mainAst=parser.parse(result,'<verity main>')
        timings.outerParse=os.clock()-stage; stage=os.clock()
        local outerSettings={}
        for key,value in pairs(settings) do outerSettings[key]=value end
        outerSettings.junk=0.01
        outerSettings.chunkname='<verity main>'
        outerSettings.layer='main'
        outerSettings.antiTamper=antiTamper
        outerSettings.antiHooks='off'
        outerSettings.antiBeautify=false
        outerSettings.nativeHelpers=false
        outerSettings.trustedRuntime=true
        outerSettings.runtimeCooperative=settings.cooperative
        if settings.nativeHelpers and settings.cooperative then
            outerSettings.sharedCheckpoint='__ovm_nativecheckpoint'
            outerSettings.sharedBinder='__ovm_nativebindcheckpoint'
        end
        local mainProto=compiler.compile(mainAst,outerSettings)
        timings.outerCompile=os.clock()-stage; stage=os.clock()
        local outer,mainStats=build.render(mainProto,rng,outerSettings)
        timings.outer=os.clock()-stage
        result=outer
        if settings.nativeHelpers then
            local freeze=antiTamper and "table.freeze(__ovm_accelerators)\n" or ''
            local setup=scheduling.setup:gsub('__ovm_checkpoint','__ovm_nativecheckpoint'):gsub('__ovm_bindcheckpoint','__ovm_nativebindcheckpoint')
            result='return(function(...)\nlocal __ovm_nativeenv=getfenv()\n'..setup..'\nlocal __ovm_accelerators='..helpers..'\n'..freeze
                ..'local __ovm_start=(function(...)\n'..result..'\nend)()\nreturn __ovm_start(__ovm_accelerators, ...)\nend)(...)'
        end
        stats.main=mainStats
        stats.main.sourceBytes=innerBytes
        stats.main.layers=2
    end
    local minifyStats
    stage=os.clock()
    if options.minify~=false then
        result,minifyStats = minify.compact(result,{rng=rng,rename=options.rename~=false,privateFields=runtimePrivateFields})
    end
    timings.minify=os.clock()-stage
    if antiHooks~='off' or antiBeautify then
        stage=os.clock()
        result,stats.wrapperGuards=guards.wrap(result,settings)
        timings.wrapperGuards=os.clock()-stage
    else timings.wrapperGuards=0 end
    result=M.watermark..'\n'..result..'\n'
    stats.sourceBytes,stats.outputBytes=#source,#result
    stats.minifierSpaces=minifyStats and minifyStats.spaces or nil
    stats.profile=profileName
    stats.settings={main=stats.mainPacked,junk=junk,cff=settings.cff,opaque=settings.opaque,
        optimize=settings.optimize,compact=settings.compact,lazyConstants=settings.lazyConstants,
        prune=settings.prune,compression=settings.compression,debug=settings.debug,
        debugConstants=settings.debugConstants,debugGuards=settings.debugGuards,constantCache=constantCache,
        antiTamper=antiTamper,antiHooks=antiHooks,antiBeautify=antiBeautify,
        lazyInstructions=lazyInstructions,perPrototypeOpcodes=perPrototypeOpcodes,
        instructionBlockSize=instructionBlockSize,instructionCache=instructionCache,debugBlocks=settings.debugBlocks,
        nativeHelpers=settings.nativeHelpers,
        fixedReturns=settings.optimize and settings.fixedReturns~=false,
        cooperative=settings.cooperative,yieldBudgetMs=settings.yieldBudgetMs,yieldInterval=settings.yieldInterval,
        unbox=settings.optimize and settings.unbox~=false,reuse=settings.optimize and settings.reuse~=false,
        fuse=settings.optimize and settings.fuse~=false,minify=options.minify~=false,rename=options.rename~=false}
    timings.total=os.clock()-started
    stats.timings=stats.timings or {}
    for key,value in pairs(timings) do stats.timings[key]=value end
    return result, stats
end

return M

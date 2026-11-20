local passes=require('src.passes')
local serialize=require('src.serialize')
local runtime=require('src.runtime')
local instructions=require('src.instructions')
local optimizer=require('src.optimizer')
local verify=require('src.verify')

local M={}

function M.render(proto,rng,options)
    local timings,started={},os.clock()
    verify.check(proto)
    local optimized=optimizer.apply(proto,options)
    verify.check(proto)
    timings.optimize=os.clock()-started; started=os.clock()
    local stats=passes.apply(proto,rng,options)
    verify.check(proto)
    timings.passes=os.clock()-started; started=os.clock()
    local opcodes,order,aliases=serialize.opcodes(rng,options.prune~=false and instructions.used(proto) or nil)
    local layout,fields=serialize.layout(rng)
    local keys,strides=serialize.operandMasks(rng)
    local binaryIds,unaryIds=serialize.operatorIds(rng)
    local cipher={key=rng:int(1,2147483646),multiplier=rng:int(10001,100000)}
    local alphabetSeed=rng:int(1,2147483646)
    local constantKey=rng:int(1,2147483646)
    local compact,lazy=options.compact~=false,options.lazyConstants~=false
    local version=(options.lazyInstructions or options.perPrototypeOpcodes) and 3 or 2
    local payload,checksum,bytes,packedBytes,entry,wire=serialize.encode(proto,opcodes,options.seed,{
        aliases=aliases,rng=rng,fields=fields,operandKeys=keys,operandStrides=strides,
        binaryIds=binaryIds,unaryIds=unaryIds,compression=options.compression,maskOnLoad=true,
        shufflePrototypes=true,cipher=cipher,
        version=version,compact=compact,lazyConstants=lazy,constantKey=constantKey,debug=options.debug,
        lazyInstructions=options.lazyInstructions,perPrototypeOpcodes=options.perPrototypeOpcodes,instructionBlockSize=options.instructionBlockSize,
        adaptiveCompression=true,
    })
    timings.serialize=os.clock()-started; started=os.clock()
    local source,renderStats,helpers=runtime.render({payload=payload,seed=options.seed,checksum=checksum,
        opcodes=opcodes,order=order,aliases=aliases,layout=layout,operandKeys=keys,operandStrides=strides,
        binaryIds=binaryIds,unaryIds=unaryIds,rng=rng,compressed=wire.compressed,unpackedSize=bytes,
        maskOnLoad=version<3,entry=entry,cipher=cipher,transport=options.transport,alphabetSeed=alphabetSeed,
        version=version,compact=compact,fields=fields,lazyConstants=lazy,constantKey=constantKey,
        lazyInstructions=options.lazyInstructions,perPrototypeOpcodes=options.perPrototypeOpcodes,instructionBlockSize=options.instructionBlockSize,
        instructionCache=options.instructionCache,debugBlocks=options.debugBlocks,limits=wire.limits,
        payloadDigest1=options.antiTamper and wire.payloadDigest1 or nil,
        payloadDigest2=options.antiTamper and wire.payloadDigest2 or nil,
        payloadDigestKey=wire.payloadDigestKey,
        constantCache=options.constantCache,debug=options.debug,debugConstants=options.debugConstants,
        antiTamper=options.antiTamper,antiHooks=options.antiHooks,debugGuards=options.debugGuards,
        layer=options.layer=='main' and 2 or 1,
        nativeHelpers=options.nativeHelpers,
        nativeCooperative=options.nativeHelpers and options.cooperative,
        cooperative=options.runtimeCooperative,
        yieldBudgetMs=options.yieldBudgetMs,yieldInterval=options.yieldInterval,
        sharedCheckpoint=options.sharedCheckpoint,sharedBinder=options.sharedBinder,
    })
    timings.runtime=os.clock()-started
    stats.timings=timings; stats.optimizer=optimized
    stats.wireVersion=wire.version; stats.compact=compact; stats.lazyConstants=lazy
    stats.constantCache=options.constantCache or 'prototype'
    stats.constants=wire.constants; stats.encryptedConstants=wire.encryptedConstants
    stats.instructionBytes=wire.instructionBytes; stats.legacyInstructionBytes=wire.legacyInstructionBytes
    stats.compressionApplied=wire.compressed
    stats.handlerVariants=renderStats.handlerVariants
    stats.guards=renderStats.guards
    stats.nativeHelpers=renderStats.nativeHelpers
    stats.cooperative=renderStats.cooperative
    stats.protection={blockCount=wire.protection.blockCount,
        encryptedInstructionBytes=wire.protection.encryptedInstructionBytes,
        opcodeMaps=wire.protection.opcodeMaps}
    stats.loaderLimits=wire.limits
    if options.debug then stats.debugMap=wire.debugMap end
    stats.seed,stats.payloadBytes,stats.compressedBytes=options.seed,bytes,packedBytes
    stats.compressionRatio=packedBytes/bytes
    stats.dispatcher,stats.transport,stats.handlerLeaves='BST',renderStats.transport,renderStats.handlerLeaves
    stats.alphabetSeed=alphabetSeed
    stats.opcodeAliases=renderStats.opcodeAliases
    return source,stats,helpers
end

return M

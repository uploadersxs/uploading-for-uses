local own = (arg[0] or ''):gsub('\\','/')
local directory = own:match('^(.*)/[^/]+$') or '.'
package.path = directory..'/?.lua;'..directory..'/?/init.lua;'..package.path

local util = require('src.util')

local function usage()
    io.write([[zz7 Obfuscator v1 - Lua host / Luau output
Usage: lua obfuscate.lua input.luau -o output.luau [options]
       lua obfuscate.lua --batch scripts --out-dir protected [options]
  --profile NAME  fast, balanced (default), max; explicit options override it
  --seed N        Reproducible build (1..2147483646)
  --junk N        Junk density, 0..1
  --no-cff        Disable block reordering
  --no-opaque     Disable opaque predicate branches
  --no-main       Use one VM layer
  --no-native-helpers Virtualize byte-work too (slower legacy comparison)
  --cooperative   Yield at VM checkpoints when task.wait is available
  --no-cooperative Disable automatic scheduler checkpoints
  --yield-budget-ms N  CPU budget between yields (default 8 ms)
  --no-optimize   Disable bytecode optimizations
  --no-compact    Use fixed 17-byte instruction records
  --no-lazy       Decode constants during loading
  --no-prune      Include handlers for unused opcodes
  --anti-tamper   Enable bounded bytecode/metadata integrity guards
  --no-anti-tamper Disable runtime integrity guards
  --anti-hooks [MODE]  identity (default), strict, off
  --no-anti-hooks Disable runtime dependency checks
  --anti-beautify Detect line changes in the final minified output
  --no-anti-beautify Disable the optional line-layout guard
  --constant-cache MODE  prototype (default), execution, none
  --lazy-instructions Decode and verify instruction blocks on first use
  --no-lazy-instructions Keep instructions available after loading
  --prototype-opcodes Use independent opcode maps and keys per function
  --no-prototype-opcodes Disable per-function opcode maps
  --instruction-block-size N  Instructions per encrypted block, 1..256
  --instruction-cache MODE  prototype (default), execution, none
  --no-compression Disable LZSS transport compression
  --readable      Preserve runtime whitespace and identifiers
  --debug         Include source/line/PC in VM errors
  --map PATH      Save a private JSON source map; enables --debug
  --stats [PATH]  Print JSON statistics, or save them to PATH
  --batch DIR     Recursively compile .lua/.luau files; skip *.obf.luau
  --out-dir DIR   Batch destination; relative subdirectories are preserved
  --force         Replace existing files through staged atomic writes
  --help          Show this help
]])
end

local function main()
    local options,input,output,force={},nil,nil,false
    local batch,outDir,statsPath,mapPath,parseOptions=nil,nil,nil,nil,true
    local i=1
    local values={['-o']=true,['--output']=true,['--seed']=true,['--junk']=true,
        ['--profile']=true,['--batch']=true,['--out-dir']=true,['--map']=true,['--constant-cache']=true,
        ['--instruction-block-size']=true,['--instruction-cache']=true,['--yield-budget-ms']=true}
    local switches={['--no-cff']='cff',['--no-opaque']='opaque',['--no-main']='main',
        ['--no-optimize']='optimize',['--no-compact']='compact',['--no-lazy']='lazyConstants',
        ['--no-prune']='prune',['--no-compression']='compression',['--readable']='minify',
        ['--no-anti-tamper']='antiTamper',['--no-anti-beautify']='antiBeautify',
        ['--no-lazy-instructions']='lazyInstructions',['--no-prototype-opcodes']='perPrototypeOpcodes',
        ['--no-native-helpers']='nativeHelpers',['--no-cooperative']='cooperative'}
    while i<=#arg do
        local item=arg[i]
        if parseOptions and (item=='--help' or item=='-h') then usage(); return
        elseif parseOptions and item=='--' then parseOptions=false
        elseif parseOptions and values[item] then
            i=i+1; local value=assert(arg[i],'missing value for '..item)
            if item=='-o' or item=='--output' then output=value
            elseif item=='--seed' then options.seed=util.seed(value)
            elseif item=='--junk' then options.junk=assert(tonumber(value),'junk must be a number')
            elseif item=='--profile' then options.profile=value
            elseif item=='--batch' then batch=value
            elseif item=='--out-dir' then outDir=value
            elseif item=='--map' then mapPath=value; options.debug=true
            elseif item=='--constant-cache' then options.constantCache=value
            elseif item=='--instruction-cache' then options.instructionCache=value
            elseif item=='--yield-budget-ms' then options.yieldBudgetMs=assert(tonumber(value),'yield budget must be a number')
            elseif item=='--instruction-block-size' then options.instructionBlockSize=assert(tonumber(value),'instruction block size must be a number') end
        elseif parseOptions and switches[item] then options[switches[item]]=false
        elseif parseOptions and item=='--anti-tamper' then options.antiTamper=true
        elseif parseOptions and item=='--anti-beautify' then options.antiBeautify=true
        elseif parseOptions and item=='--lazy-instructions' then options.lazyInstructions=true
        elseif parseOptions and item=='--prototype-opcodes' then options.perPrototypeOpcodes=true
        elseif parseOptions and item=='--cooperative' then options.cooperative=true
        elseif parseOptions and item=='--no-anti-hooks' then options.antiHooks='off'
        elseif parseOptions and item=='--anti-hooks' then
            options.antiHooks='identity'
            local following=arg[i+1]
            if following=='identity' or following=='strict' or following=='off' then i=i+1; options.antiHooks=following end
        elseif parseOptions and item:match('^%-%-anti%-hooks=') then
            options.antiHooks=item:sub(14)
            assert(#options.antiHooks>0,'missing value for --anti-hooks')
        elseif parseOptions and item=='--debug' then options.debug=true
        elseif parseOptions and item=='--force' then force=true
        elseif parseOptions and item=='--stats' then
            statsPath=true
            local followingSource=input or batch
            if not followingSource then
                local j=i+2
                while j<=#arg do
                    if arg[j]=='--batch' then followingSource=true; break
                    elseif values[arg[j]] then j=j+2
                    elseif arg[j]=='--anti-hooks' and (arg[j+1]=='identity' or arg[j+1]=='strict' or arg[j+1]=='off') then j=j+2
                    elseif arg[j]:sub(1,1)=='-' then j=j+1
                    else followingSource=true; break end
                end
            end
            if followingSource and arg[i+1] and arg[i+1]:sub(1,1)~='-' then i=i+1; statsPath=arg[i] end
        elseif parseOptions and item:match('^%-%-stats=') then
            statsPath=item:sub(9); assert(#statsPath>0,'missing value for --stats')
        elseif parseOptions and item:sub(1,1)=='-' then error('unknown option: '..item,0)
        elseif not input then input=item
        else error('unexpected argument: '..item,0) end
        i=i+1
    end
    assert(not (batch and input),'choose an input file or --batch directory')
    assert(not (batch and output),'--output is for a single file; use --out-dir with --batch')
    assert(not (outDir and not batch),'--out-dir requires --batch')
    if not batch and not input then usage(); error('input file required',0) end
    local jobs={}
    if batch then
        assert(outDir,'--batch requires --out-dir')
        local root,destination=util.absolute(batch),util.absolute(outDir)
        assert(root~=destination,'batch output directory must differ from input directory')
        local prefix=root:sub(-1)=='/' and root or root..'/'
        local outputPrefix=destination:sub(-1)=='/' and destination or destination..'/'
        local destinationInside=destination:sub(1,#prefix)==prefix
        for _,file in ipairs(util.listSources(batch)) do
            local absolute=util.absolute(file)
            if not absolute:lower():match('%.obf%.luau$') and not (destinationInside and absolute:sub(1,#outputPrefix)==outputPrefix) then
                assert(absolute:sub(1,#prefix)==prefix,'batch source escaped input directory')
                local relative=absolute:sub(#prefix+1):gsub('%.[lL][uU][aA][uU]?$', '')..'.obf.luau'
                jobs[#jobs+1]={input=file,output=outputPrefix..relative}
            end
        end
        assert(#jobs>0,'batch directory contains no eligible .lua/.luau files')
    else
        output=output or input:gsub('%.lua[u]?$', '')..'.obf.luau'
        jobs[1]={input=input,output=output}
    end
    local sources,reserved={},{}
    for _,job in ipairs(jobs) do sources[util.absolute(job.input)]=true end
    local function reserve(path)
        local absolute=util.absolute(path)
        assert(not sources[absolute],'output must differ from input')
        assert(not reserved[absolute],'multiple outputs resolve to the same path: '..path)
        reserved[absolute]=true
        assert(force or not util.exists(path),'output already exists; choose another name or use --force')
    end
    for _,job in ipairs(jobs) do reserve(job.output) end
    if type(statsPath)=='string' then reserve(statsPath) end
    if mapPath then reserve(mapPath) end
    local obfuscator=require('src.obfuscator')
    local records,maps={},{}
    local function status(message)
        if statsPath==true then io.stderr:write(message) else io.write(message) end
    end
    for _,job in ipairs(jobs) do
        local jobOptions={}
        for key,value in pairs(options) do jobOptions[key]=value end
        jobOptions.chunkname=job.input
        local result,stats=obfuscator.obfuscate(util.read(job.input),jobOptions)
        -- Compile completely before preparing directories or replacing output.
        if batch then util.mkdir(assert(job.output:match('^(.*)/[^/]+$'))) end
        util.atomicWrite(job.output,result,force)
        records[#records+1]={input=job.input,output=job.output,stats=stats}
        if mapPath then maps[#maps+1]={input=job.input,output=job.output,map=assert(stats.debugMap,'debug map unavailable')} end
        status(string.format('Created %s | %s | %d VM layers | seed %d | payload %d -> %d bytes | output %d bytes | %.3fs CPU\n',
            job.output,stats.profile,stats.mainPacked and 2 or 1,stats.seed,stats.payloadBytes,stats.compressedBytes,#result,stats.timings.total))
    end
    if mapPath then
        local map=batch and {version=1,files=maps} or maps[1].map
        util.atomicWrite(mapPath,util.json(map)..'\n',force)
    end
    if statsPath then
        local statistics=batch and {version=1,files=records} or records[1].stats
        local json=util.json(statistics)..'\n'
        if type(statsPath)=='string' then util.atomicWrite(statsPath,json,force) else io.write(json) end
    end
end

local ok,err=pcall(main)
if not ok then io.stderr:write('zz7: '..tostring(err)..'\n'); os.exit(1) end

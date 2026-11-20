-- Bounded checks for the libraries and private data used by the generated VM.
-- Checks are generated locally; no third-party snippets or executor APIs run.
local util=require('src.util')
local minify=require('src.minify')
local M={}

local dependencies={
    {'buffer',{'create','fromstring','len','readu8','readu16','readu32','readstring','writeu8','writeu16','writeu32'}},
    {'bit32',{'band','bxor','lshift','extract'}},
    {'math',{'floor'}},
    {'table',{'pack','unpack','create','move','freeze','isfrozen'}},
    {'string',{'byte','sub','gsub','format'}},
}
local globals={'type','tonumber','error','ipairs','next','getmetatable','rawget','getfenv','setfenv','pcall'}

function M.hooks(mode,environment)
    if mode==nil or mode=='off' then return '', '' end
    assert(mode=='identity' or mode=='strict','invalid hook guard mode')
    -- Flat snapshots and explicit comparisons avoid reinterpreting a table of
    -- triples and its loop on every boundary when this VM is itself packed.
    local rows,checks,libraries={},{},{}
    local function dependency(actual,expected)
        rows[#rows+1]=expected or actual
        checks[#checks+1]=actual..' ~= __ovm_guardrefs['..#rows..']'
    end
    for _,entry in ipairs(dependencies) do
        local library='__ovm_guardlib_'..entry[1]
        libraries[#libraries+1]='local '..library..' = '..entry[1]
        for _,name in ipairs(entry[2]) do
            dependency(library..'.'..name)
        end
        dependency(environment..'.'..entry[1],library)
    end
    for _,name in ipairs(globals) do dependency(environment..'.'..name,name) end
    local source=[=[
local __ovm_guardtype, __ovm_guarderror = type, error
@LIBRARIES@
local __ovm_guardrefs = {@REFS@}
local __ovm_guardfreezerefs = __ovm_guardlib_table.freeze
if __ovm_guardtype(__ovm_guardfreezerefs) == 'function' then __ovm_guardfreezerefs(__ovm_guardrefs) end
local function __ovm_guardhooks()
    if @CHECKS@ then __ovm_guarderror('', 0) end
end
@STRICT@
__ovm_guardhooks()
]=]
    local strict=''
    if mode=='strict' then strict=[=[
local __ovm_guardinfo = debug and debug.info
if __ovm_guardtype(__ovm_guardinfo) ~= 'function' then __ovm_guarderror('', 0) end
if __ovm_guardinfo(__ovm_guardinfo, 's') ~= '[C]' or __ovm_guardinfo(__ovm_guardinfo, 'l') ~= -1 then __ovm_guarderror('', 0) end
for __ovm_i = 1, @REFCOUNT@ do
    local __ovm_ref = __ovm_guardrefs[__ovm_i]
    if __ovm_guardtype(__ovm_ref) == 'function' then
        if __ovm_guardinfo(__ovm_ref, 's') ~= '[C]' or __ovm_guardinfo(__ovm_ref, 'l') ~= -1 then __ovm_guarderror('', 0) end
    end
end
]=] end
    local substitutions={REFS=table.concat(rows,','),LIBRARIES=table.concat(libraries,'\n'),
        CHECKS=table.concat(checks,'\n        or '),STRICT=strict}
    source=source:gsub('@([A-Z]+)@',function(key) return assert(substitutions[key]) end)
    source=source:gsub('@REFCOUNT@',tostring(#rows))
    return source,'__ovm_guardhooks()'
end

function M.probe()
    return [=[
do
    local __ovm_probe = buffer.create(8)
    buffer.writeu32(__ovm_probe, 0, 1370480337)
    buffer.writeu8(__ovm_probe, 4, 131)
    if buffer.len(__ovm_probe) ~= 8 or buffer.readu32(__ovm_probe, 0) ~= 1370480337 or buffer.readu8(__ovm_probe, 4) ~= 131 then error('', 0) end
    if string.byte(buffer.readstring(__ovm_probe, 4, 1)) ~= 131 or bit32.bxor(23063, 42405) ~= 65458 then error('', 0) end
    if math.floor(-1.25) ~= -2 or string.sub('verity', 2, 4) ~= 'eri' then error('', 0) end
    local __ovm_probevalues = table.pack(pcall(function() return nil, false, 23, nil end))
    if __ovm_probevalues.n ~= 5 or __ovm_probevalues[1] ~= true or __ovm_probevalues[2] ~= nil or __ovm_probevalues[3] ~= false or __ovm_probevalues[4] ~= 23 or __ovm_probevalues[5] ~= nil then error('', 0) end
end
]=]
end

function M.integrity(config,opcodes,specs,fieldOrder,quote,number)
    if not config.antiTamper then return {startup='',prepare='',loaded='',frame='',weights={}} end
    local startup=[=[
local __ovm_guardfreezeentry = table.freeze
if type(__ovm_guardfreezeentry)~='function' or type(table.isfrozen)~='function' then error('',0) end
local __ovm_freezeprobe={17}
__ovm_guardfreezeentry(__ovm_freezeprobe)
if not table.isfrozen(__ovm_freezeprobe) then error('',0) end
]=]
    local prepare='    __ovm_p.checks = {}\n'
    if not config.lazyInstructions then
        local at=config.compact and '__ovm_p.sites[__ovm_site]' or '__ovm_p.offset+(__ovm_site-1)*17'
        prepare=prepare..'    for __ovm_site=1,__ovm_p.count do\n'
            ..'        local __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d,__ovm_next=__ovm_decodeinstruction(__ovm_p,__ovm_bytes,'..at..',__ovm_site)\n'
            ..'        __ovm_p.checks[__ovm_site]={__ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d,__ovm_buffer.readstring(__ovm_bytes,'..at..',__ovm_next-('..at..'))}\n    end\n'
    end
    local loaded=[=[
local __ovm_guardfreeze = __ovm_guardfreezeentry
for __ovm_i=1,__ovm_count do
    local __ovm_p=__ovm_protos[__ovm_i]
    for __ovm_j=1,__ovm_p.constantCount do
        if __ovm_type(__ovm_p.constants[__ovm_j])=='table' then __ovm_guardfreeze(__ovm_p.constants[__ovm_j]) end
    end
    for __ovm_j=1,#__ovm_p.upvalues do __ovm_guardfreeze(__ovm_p.upvalues[__ovm_j]) end
    __ovm_guardfreeze(__ovm_p.constants)
    __ovm_guardfreeze(__ovm_p.params)
    __ovm_guardfreeze(__ovm_p.upvalues)
    __ovm_guardfreeze(__ovm_p.children)
    if __ovm_p.boxed then __ovm_guardfreeze(__ovm_p.boxed) end
    if __ovm_p.sites then __ovm_guardfreeze(__ovm_p.sites) end
    if __ovm_p.lines then __ovm_guardfreeze(__ovm_p.lines) end
    if __ovm_p.operandKeys then __ovm_guardfreeze(__ovm_p.operandKeys); __ovm_guardfreeze(__ovm_p.operandStrides) end
    if __ovm_p.opcodeMap then __ovm_guardfreeze(__ovm_p.opcodeMap) end
    if __ovm_p.blocks then
        for __ovm_j=1,#__ovm_p.blocks do __ovm_guardfreeze(__ovm_p.blocks[__ovm_j]) end
        __ovm_guardfreeze(__ovm_p.blocks)
    end
    for __ovm_j=1,#__ovm_p.checks do __ovm_guardfreeze(__ovm_p.checks[__ovm_j]) end
    __ovm_guardfreeze(__ovm_p.checks)
    if __ovm_p.eager then
        for __ovm_j=1,#__ovm_p.eager do __ovm_guardfreeze(__ovm_p.eager[__ovm_j]) end
        __ovm_guardfreeze(__ovm_p.eager)
    end
    __ovm_guardfreeze(__ovm_p)
end
__ovm_guardfreeze(__ovm_protos)
]=]
    return {startup=startup,prepare=prepare,loaded=loaded,
        frame=config.lazyInstructions and '' or 'local __ovm_checks=__ovm_p.checks',weights={}}
end

function M.wrap(source,settings)
    local hooks=settings.antiHooks or 'off'
    if hooks=='off' and not settings.antiBeautify then return source,{enabled=false,antiHooks=hooks,antiBeautify=false} end
    local setup,check=M.hooks(hooks,'__ovm_wrapperenv')
    local markerfirst=settings.antiBeautify and 'local __ovm_markerfirst = function() return 17 end\n' or ''
    local lineguard=settings.antiBeautify and [=[
local __ovm_lineinfo = debug and debug.info
if type(__ovm_lineinfo) ~= 'function' then error('', 0) end
local __ovm_markerlast = function() return 29 end
local __ovm_firstline, __ovm_lastline = __ovm_lineinfo(__ovm_markerfirst, 'l'), __ovm_lineinfo(__ovm_markerlast, 'l')
if type(__ovm_firstline) ~= 'number' or __ovm_firstline <= 0 or __ovm_firstline ~= __ovm_lastline then error('', 0) end
]=] or ''
    local probe=hooks~='off' and M.probe() or ''
    local wrapper='return(function(...) local __ovm_wrapperenv=getfenv() '..setup..probe..markerfirst
        ..' local __ovm_wrapperprogram=function(...) '..source..' end '..lineguard
        ..' local __ovm_wrapperpack,__ovm_wrapperunpack=table.pack,table.unpack local __ovm_wrapperresults=__ovm_wrapperpack(__ovm_wrapperprogram(...)) '
        ..check..' return __ovm_wrapperunpack(__ovm_wrapperresults,1,__ovm_wrapperresults.n) end)(...)'
    if settings.minify~=false then wrapper=minify.compact(wrapper,{rng=util.rng((settings.seed+104729)%2147483646+1),rename=settings.rename~=false,privateFields={}}) end
    return wrapper,{enabled=true,antiHooks=hooks,antiBeautify=settings.antiBeautify==true}
end

return M

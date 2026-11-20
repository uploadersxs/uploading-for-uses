package.path='./?.lua;'..package.path
local util=require('src.util')
local build=require('src.build')
local serialize=require('src.serialize')
local cipher=require('src.cipher')

local entries={
    {kind='nil'}, {kind='boolean',value=false}, {kind='boolean',value=true},
    {kind='number',value=0}, {kind='number',value=-1/math.huge},
    {kind='number',value=-2147483648}, {kind='number',value=2147483647},
    {kind='number',value=-128}, {kind='number',value=127},
    {kind='number',value=-32768}, {kind='number',value=32767},
    {kind='number',value=65535}, {kind='number',value=65536},
    {kind='number',value=2147483648}, {kind='number',value=-2147483649},
    {kind='number',value=0/0}, {kind='number',value=math.huge},
    {kind='number',value=-math.huge}, {kind='string',value=''},
    {kind='string',value='\0\255\128binary'},
}
local unused='WIRE_UNUSED_ENCRYPTED_SENTINEL_735c'
local function prototype()
    local proto={code={{op='PACK',1,0,0,0}},constants={},children={},upvalues={},params={},
        slots=0,registers=2,vararg=true,chunkname='wire-values.luau'}
    for index,k in ipairs(entries) do
        proto.constants[index]={kind=k.kind,value=k.value}
        proto.code[#proto.code+1]={op='LOADK',2,index,0,0,line=index}
        proto.code[#proto.code+1]={op='PUSH',1,2,0,0,line=index}
    end
    proto.constants[#entries+1]={kind='string',value=unused}
    proto.code[#proto.code+1]={op='RETURN1',1,0,0,0,line=#entries+1}
    return proto
end

-- Remove only the outer transport transform. The stored string pool remains
-- ciphertext; the unused marker is absent from the wire bytes themselves.
do
    local rng=util.rng(112358)
    local opcodes=serialize.opcodes(rng)
    local cipherConfig={key=1234567,multiplier=48271}
    local payload,_,_,_,_,meta=serialize.encode(prototype(),opcodes,112358,
        {version=2,compact=true,lazyConstants=true,constantKey=271828,cipher=cipherConfig})
    local wire=cipher.crypt(payload,cipherConfig,true)
    assert(wire:sub(1,7)=='VERITY_' and wire:byte(8)==2)
    assert(not wire:find(unused,1,true),'unused constant stored as plaintext')
    assert(not wire:find(entries[20].value,1,true),'binary string stored as plaintext')
    assert(meta.encryptedConstants>0 and meta.instructionBytes<meta.legacyInstructionBytes)
end

local validation=[=[
assert(values.n==20)
assert(values[1]==nil and values[2]==false and values[3]==true)
assert(values[4]==0 and 1/values[4]==math.huge)
assert(values[5]==0 and 1/values[5]==-math.huge)
assert(values[6]==-2147483648 and values[7]==2147483647)
assert(values[8]==-128 and values[9]==127)
assert(values[10]==-32768 and values[11]==32767)
assert(values[12]==65535 and values[13]==65536)
assert(values[14]==2147483648 and values[15]==-2147483649)
assert(values[16]~=values[16])
assert(values[17]==math.huge and values[18]==-math.huge)
assert(values[19]=='' and values[20]=='\0\255\128binary')
]=]
for _,variant in ipairs({
    {name='compact_lazy',compact=true,lazyConstants=true},
    {name='fixed_lazy',compact=false,lazyConstants=true},
    {name='compact_eager',compact=true,lazyConstants=false},
}) do
    local options={seed=112358,junk=0,cff=true,opaque=false,compression=true,
        compact=variant.compact,lazyConstants=variant.lazyConstants,debugConstants=true,
        optimize=true,prune=true,constantCache='none'}
    local source,stats=build.render(prototype(),util.rng(options.seed),options)
    assert(stats.wireVersion==2 and stats.lazyConstants==variant.lazyConstants)
    local prefix='local materializations=0\n__verity_constant=function(layer,proto,index,value)\nassert(layer==1)\nmaterializations+=1\n'
    if variant.lazyConstants then prefix=prefix..'assert(value~='..string.format('%q',unused)..', "unused constant materialized")\n' end
    prefix=prefix..'end\nlocal function protected(...)\n'
    local suffix='\nend\nlocal values=protected()\n__verity_constant=nil\n'..validation..
        'assert(materializations=='..(#entries+(variant.lazyConstants and 0 or 1))..')\nprint("wire '..variant.name..' OK")\n'
    util.write('tests/.generated/wire_'..variant.name..'.luau',prefix..source..suffix)
end

-- Force each compact operand width without allowing allocation to shrink the
-- deliberately sparse register ID. Return values remain identical.
for _,register in ipairs({3,300,70000}) do
    local proto={code={{op='LOADK',register,1,0,0},{op='RETURN1',register,0,0,0}},
        constants={{kind='string',value='compact-width-OK'}},children={},upvalues={},params={},
        slots=0,registers=register,vararg=true,chunkname='wire-width.luau'}
    local source=build.render(proto,util.rng(register),{seed=register,junk=0,cff=false,opaque=false,
        compression=true,compact=true,lazyConstants=true,optimize=false,prune=true})
    util.write('tests/.generated/wire_width_'..register..'.luau',
        'local function protected(...)\n'..source..'\nend\nassert(protected()=="compact-width-OK")\nprint("wire width '..register..' OK")\n')
end
print('Wire host checks OK')

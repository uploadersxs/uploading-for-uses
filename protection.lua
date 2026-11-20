-- Paired nonlinear corruption checks for instruction blocks. These checks are
-- not signatures or authenticated encryption; the runtime carries its keys.
local M={}
local floor=math.floor
local modulus=4294967296
local native=rawget(_G,'bit32') or rawget(_G,'bit')
if not native then
    local ok,library=pcall(require,'bit')
    if ok then native=library end
end
local nibble={}
for a=0,15 do
    local row={}; nibble[a]=row
    for b=0,15 do
        local x,y,value,place=a,b,0,1
        for _=1,4 do
            if x%2~=y%2 then value=value+place end
            x,y,place=floor(x/2),floor(y/2),place*2
        end
        row[b]=value
    end
end
function M.xor(a,b)
    if native then return native.bxor(a,b)%modulus end
    local value,place=0,1
    for _=1,8 do
        value=value+nibble[a%16][b%16]*place
        a,b,place=floor(a/16),floor(b/16),place*16
    end
    return value
end
function M.blockKey(seed,prototype,block)
    return (seed+prototype*8191+block*131+97)%2147483646+1
end
function M.digest(source,key)
    assert(type(source)=='string','block digest input must be a string')
    assert(type(key)=='number' and key>=0 and key<modulus and key%1==0,'invalid block digest key')
    local first,second=key,M.xor(key,2779096485)
    for i=1,#source do
        local byte=source:byte(i)
        first=(M.xor(first,byte)*65599+17)%modulus
        local rotated=(second*128)%modulus+floor(second/33554432)
        second=(M.xor(rotated,byte+1)*257+31)%modulus
    end
    first=M.xor(first,floor(first/65536))
    first=(first*65599)%modulus
    first=M.xor(first,floor(first/8192))
    second=M.xor(second,floor(second/32768))
    second=(second*257)%modulus
    second=M.xor(second,floor(second/65536))
    return first,second
end
function M.runtimeSource()
    return [=[
local function __ovm_blockkey(__ovm_seed,__ovm_prototype,__ovm_block)
    return (__ovm_seed+__ovm_prototype*8191+__ovm_block*131+97)%2147483646+1
end
local function __ovm_blockdigest(__ovm_data,__ovm_start,__ovm_size,__ovm_key)
    local __ovm_first,__ovm_second=__ovm_key,__ovm_bxor(__ovm_key,2779096485)
    for __ovm_i=0,__ovm_size-1 do
        local __ovm_byte=__ovm_buffer.readu8(__ovm_data,__ovm_start+__ovm_i)
        __ovm_first=(__ovm_bxor(__ovm_first,__ovm_byte)*65599+17)%4294967296
        local __ovm_rotated=(__ovm_second*128)%4294967296+__ovm_floor(__ovm_second/33554432)
        __ovm_second=(__ovm_bxor(__ovm_rotated,__ovm_byte+1)*257+31)%4294967296
    end
    __ovm_first=__ovm_bxor(__ovm_first,__ovm_floor(__ovm_first/65536))
    __ovm_first=(__ovm_first*65599)%4294967296
    __ovm_first=__ovm_bxor(__ovm_first,__ovm_floor(__ovm_first/8192))
    __ovm_second=__ovm_bxor(__ovm_second,__ovm_floor(__ovm_second/32768))
    __ovm_second=(__ovm_second*257)%4294967296
    __ovm_second=__ovm_bxor(__ovm_second,__ovm_floor(__ovm_second/65536))
    return __ovm_first,__ovm_second
end
]=]
end
return M

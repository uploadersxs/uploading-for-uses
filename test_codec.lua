local codec=require('src.codec')
local util=require('src.util')
local rng=util.rng(314159)
local alphabet={}
for i=0,255 do alphabet[#alphabet+1]=string.char(i) end
local randomBytes={}
for i=1,70000 do randomBytes[i]=string.char(rng:int(0,255)) end
local cases={'','x','abcd',table.concat(alphabet),string.rep('\0',100000),
    string.rep('abcdxyz',12000),table.concat(randomBytes)}
for _,source in ipairs(cases) do
    assert(codec.decompress(codec.compress(source))==source,'LZSS roundtrip')
end
assert(#codec.compress(string.rep('abc',10000))<1000,'LZSS compression ratio')
for _,bad in ipairs({'','VLZ1','VLZ1'..string.char(100,0,0,0),
    'VLZ1'..string.char(4,0,0,0,1,0,0,0)}) do
    assert(not pcall(codec.decompress,bad),'invalid LZSS stream must fail')
end
print('Compression checks OK')

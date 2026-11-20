export type Pair<T> = {first:T, second:T}
type Transformer = (number, ...string) -> (number, string?)
local function typed(x: number, ...: string): (number, string?)
    local label: string? = ...
    return x*2,label
end
local a: number,b: string?=typed(21,'answer')
assert(a==42 and b=='answer')
local pair: Pair<number> = {first=3,second=5}
local cast=(pair :: Pair<number>)
assert(cast.first+cast.second==8)
local x=if a>10 then 1 elseif a==0 then 2 else 3
assert(x==1)
assert((if false then error('bad') else 77)==77)
assert(9//2==4 and -9//2==-5)
local n=0b1010+0x10+1_000
assert(n==1026)
local escaped='A\x42\u{43}\z   D'
assert(escaped=='ABCD')
local text=[==[
long ]=] string
]==]
assert(string.find(text,']=]',1,true))
local bytes=buffer.create(8)
buffer.writeu32(bytes,0,4294967295)
buffer.writef32(bytes,4,1.5)
assert(buffer.readu32(bytes,0)==4294967295 and buffer.readf32(bytes,4)==1.5)
assert(bit32.bxor(255,15)==240)
print('luau OK')

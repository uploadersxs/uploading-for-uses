local total=0
for i=1,10 do
    if i==3 then continue end
    if i==8 then break end
    total += i
end
assert(total==25)
local descending=0
for i='5','1','-2' do descending+=i end
assert(descending==9)
local closures={}
for i=1,3 do closures[i]=function() return i end end
assert(closures[1]()==1 and closures[2]()==2 and closures[3]()==3)
local count=0
while count<5 do
    count+=1
    if count<4 then continue end
    total+=1
end
assert(count==5 and total==27)
local r=0
repeat
    r+=1
    local finished=r>=3
until finished
assert(r==3)
repeat
    local active=r
    r-=1
    if r>0 then continue end
until active==1
assert(r==0)
local map={a=2,b=3,c=4}
local sum=0
for k,v in pairs(map) do sum+=v end
assert(sum==9)
sum=0
for k,v in map do sum+=v end
assert(sum==9)
local iter=setmetatable({}, {__iter=function()
    local n=0
    return function() n+=1; if n<=3 then return n,n*2 end end
end})
sum=0
for k,v in iter do sum+=v end
assert(sum==12)
local funcs={}
for k,v in ipairs({10,20,30}) do funcs[k]=function() return v end end
assert(funcs[1]()==10 and funcs[2]()==20 and funcs[3]()==30)
local outer=0
for i=1,3 do
    for j=1,3 do if j==2 then break end; outer+=1 end
end
assert(outer==3)
print('loops OK')

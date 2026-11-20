package.path='./?.lua;./?/init.lua;'..package.path
local scheduler=require('src.scheduler')
local disabled=scheduler.render()
assert(not disabled.enabled and disabled.setup=='' and disabled.checkpoint=='')
for _,bad in ipairs({{cooperative=1},{yieldBudgetMs=0},{yieldBudgetMs=-1},{yieldBudgetMs=1001},{yieldBudgetMs='8'},
    {yieldInterval=0},{yieldInterval=1.5},{yieldInterval=65537},{yieldInterval='256'}}) do
    assert(not pcall(scheduler.render,bad),'invalid scheduler settings accepted')
end
assert(not pcall(scheduler.render,{cooperative=true,environment='env.task'}),'environment must be one local identifier')
for _,bad in ipairs({'checkpoint.field','checkpoint()',1,{}}) do
    assert(not pcall(scheduler.render,{cooperative=true,sharedCheckpoint=bad}),'shared checkpoint must be a local identifier')
    assert(not pcall(scheduler.render,{cooperative=true,sharedCheckpoint='checkpoint',sharedBinder=bad}),'shared binder must be a local identifier')
end
assert(not pcall(scheduler.render,{cooperative=true,sharedBinder='binder'}),'shared binder requires a shared checkpoint')

local rendered=scheduler.render({cooperative=true,yieldBudgetMs=8,yieldInterval=4})
assert(rendered.enabled and rendered.checkpoint=='__ovm_checkpoint()')
assert(not rendered.setup:find('@[A-Z]+@'),'unexpanded scheduler placeholder')
local evaluate=loadstring or load
local constructor=assert(evaluate('return function(__ovm_entryenv)\n'..rendered.setup..'\n return __ovm_checkpoint end'))()
local bindingConstructor=assert(evaluate('return function(__ovm_entryenv)\n'..rendered.setup..'\n return __ovm_checkpoint,__ovm_bindcheckpoint end'))()
assert(rendered.binding=='local __ovm_checkpoint=__ovm_bindcheckpoint()')
local now,clocks,waits,yieldable,thread=0,0,0,true,{}
local environment={task={wait=function() waits=waits+1; now=now+100 end},os={clock=function() clocks=clocks+1; return now end},
    coroutine={isyieldable=function() return yieldable end,running=function() return thread end}}
local checkpoint=constructor(environment)
for _=1,3 do checkpoint() end
assert(clocks==0 and waits==0,'clock must be throttled')
checkpoint()
assert(clocks==1 and waits==0,'first interval initializes a thread budget')
now=0.007
for _=1,4 do checkpoint() end
assert(waits==0,'checkpoint yielded before the budget elapsed')
now=0.008
for _=1,4 do checkpoint() end
assert(waits==1,'elapsed thread budget did not yield')
for _=1,4 do checkpoint() end
assert(waits==1,'time spent waiting must not consume the next CPU budget')
now=now+0.02
yieldable=false
local previousClocks=clocks
for _=1,12 do checkpoint() end
assert(waits==1 and clocks==previousClocks,'non-yieldable boundaries must skip clock and wait')
yieldable=true
local firstThread=thread
thread={}
for _=1,4 do checkpoint() end
assert(waits==1,'a new thread must start with a fresh budget')
thread=firstThread
for _=1,4 do checkpoint() end
assert(waits==2,'another thread must not reset a pending thread budget')
thread=nil
for _=1,4 do checkpoint() end
assert(waits==2,'main fallback must initialize its own budget')
now=now+0.02
for _=1,4 do checkpoint() end
assert(waits==3,'main fallback must retain its budget')

for _,missing in ipairs({'task','os','coroutine'}) do
    local absent={task=environment.task,os=environment.os,coroutine=environment.coroutine}
    absent[missing]=nil
    local noop=constructor(absent)
    local previousWaits=waits
    for _=1,100 do noop() end
    assert(waits==previousWaits,'missing scheduler APIs must be a no-op')
end
for _,missing in ipairs({'wait','clock','isyieldable','running'}) do
    local absent={task={wait=environment.task.wait},os={clock=environment.os.clock},coroutine={isyieldable=environment.coroutine.isyieldable,running=environment.coroutine.running}}
    if missing=='wait' then absent.task.wait=nil elseif missing=='clock' then absent.os.clock=nil else absent.coroutine[missing]=nil end
    local noop=constructor(absent)
    local previousWaits=waits
    for _=1,100 do noop() end
    assert(waits==previousWaits,'missing scheduler functions must be a no-op')
end

-- Alternating equal-sized bursts must not assign every clock check to the
-- second thread. Both retain their own interval counters and deadlines.
local alternatingThreads={{},{}}
local activeThread=alternatingThreads[1]
local alternatingNow=0
local alternatingWaits={}
local alternatingCheckpoint=constructor({task={wait=function()
    alternatingWaits[activeThread]=(alternatingWaits[activeThread] or 0)+1
end},os={clock=function() return alternatingNow end},coroutine={
    isyieldable=function() return true end,running=function() return activeThread end}})
for _=1,4 do
    for _,candidate in ipairs(alternatingThreads) do activeThread=candidate; alternatingCheckpoint() end
end
alternatingNow=0.02
for _=1,4 do
    for _,candidate in ipairs(alternatingThreads) do activeThread=candidate; alternatingCheckpoint() end
end
assert(alternatingWaits[alternatingThreads[1]]==1 and alternatingWaits[alternatingThreads[2]]==1,
    'alternating coroutines must both receive budget checks')

local capturedNow,capturedWaits=0,0
local capturedEnvironment={task={wait=function() capturedWaits=capturedWaits+1 end},os={clock=function() return capturedNow end},
    coroutine={isyieldable=function() return true end,running=function() return nil end}}
local capturedCheckpoint=constructor(capturedEnvironment)
local replaced=function() error('scheduler recaptured a replaced dependency') end
capturedEnvironment.task.wait=replaced; capturedEnvironment.os.clock=replaced
capturedEnvironment.coroutine.isyieldable=replaced; capturedEnvironment.coroutine.running=replaced
for _=1,4 do capturedCheckpoint() end
capturedNow=0.02
for _=1,4 do capturedCheckpoint() end
assert(capturedWaits==1,'scheduler must retain captured API references')

-- Binding is per activation: a native helper or VM frame resolves its owner
-- once and keeps that thread's ticks/deadline through every yield/resume.
local boundNow,boundLookups,boundClocks,boundWaits=0,0,0,0
local boundThread={}
local boundEnvironment={task={wait=function() boundWaits=boundWaits+1 end},
    os={clock=function() boundClocks=boundClocks+1; return boundNow end},
    coroutine={isyieldable=function() return true end,running=function() boundLookups=boundLookups+1; return boundThread end}}
local unbound,bind=bindingConstructor(boundEnvironment)
local firstBinding,secondBinding=bind(),bind()
assert(boundLookups==2,'each activation must resolve its thread once')
firstBinding(); secondBinding(); firstBinding(); secondBinding()
assert(boundLookups==2 and boundClocks==1,'bindings must share a thread counter without hot thread lookups')
boundNow=0.02
for _=1,4 do firstBinding() end
assert(boundWaits==1,'bound elapsed budget did not yield')
for _=1,4 do secondBinding() end
assert(boundWaits==1,'a second binding must observe the first binding reset instead of yielding twice')
local beforeLookup=boundLookups
for _=1,4 do unbound() end
assert(boundLookups==beforeLookup+4 and boundWaits==1,'unbound and bound callsites must share the same deadline')
local firstBoundThread=boundThread
boundThread={}
local otherBinding=bind()
for _=1,4 do otherBinding() end
boundNow=0.04
for _=1,4 do otherBinding() end
assert(boundWaits==2,'a different thread must keep its own binding budget')
boundThread=firstBoundThread
for _=1,4 do firstBinding() end
assert(boundWaits==3,'other thread must not reset this thread bound budget')

-- The native helper wrapper and outer VM refer to one checkpoint/binder pair,
-- rather than constructing independent expired deadlines on the same thread.
local shared=scheduler.render({cooperative=true,sharedCheckpoint='sharedCheckpoint',sharedBinder='sharedBinder'})
local sharedConstructor=assert(evaluate('return function(sharedCheckpoint,sharedBinder)\n'..shared.setup
    ..'\nreturn __ovm_checkpoint,__ovm_bindcheckpoint end'))()
local left,leftBind=sharedConstructor(unbound,bind)
local right,rightBind=sharedConstructor(unbound,bind)
assert(shared.shared and left==right and left==unbound and leftBind==rightBind and leftBind==bind,
    'shared scheduler must preserve checkpoint and binder identity')
assert(not shared.setup:find('schedulerstates',1,true),'shared aliases must not allocate another scheduler')
assert(shared.binding==rendered.binding,'shared and owned frames must bind in the same way')
local sharedOnly=scheduler.render({cooperative=true,sharedCheckpoint='sharedCheckpoint'})
assert(sharedOnly.binding=='' and sharedOnly.setup=='local __ovm_checkpoint=sharedCheckpoint\n',
    'shared checkpoint without binder must remain supported')
local _,noopBind=bindingConstructor({})
assert(noopBind()==noopBind(),'missing APIs must reuse a stable no-op binding')

-- Exercise a real coroutine yield/resume in Luau, with a deterministic clock
-- and a local task facade. No running Roblox client is needed.
local util=require('src.util')
local actual=scheduler.render({cooperative=true,yieldInterval=1,yieldBudgetMs=8})
util.write('tests/.generated/scheduler.luau',[=[
local now=0
local environment={task={wait=function() coroutine.yield('checkpoint') end},os={clock=function() return now end},coroutine=coroutine}
local checkpoint=(function(__ovm_entryenv)
]=]..actual.setup..[=[
return __ovm_checkpoint end)(environment)
local progress=0
local worker=coroutine.create(function()
    checkpoint()
    now=0.02
    checkpoint()
    progress=progress+1
    now=0.04
    checkpoint()
    progress=progress+1
end)
local ok,value=coroutine.resume(worker)
assert(ok and value=='checkpoint' and progress==0)
ok,value=coroutine.resume(worker)
assert(ok and value=='checkpoint' and progress==1)
ok,value=coroutine.resume(worker)
assert(ok and coroutine.status(worker)=='dead' and progress==2)
-- __tostring is a non-yieldable native boundary in Luau. A scheduler call
-- with an expired budget must return normally instead of yielding through it.
local nativeBoundary=setmetatable({},{__tostring=function()
    checkpoint()
    now=now+1
    checkpoint()
    return 'non-yieldable'
end})
assert(tostring(nativeBoundary)=='non-yieldable')
assert(string.gsub('x','x',function()
    checkpoint()
    now=now+1
    checkpoint()
    return 'x'
end)=='x')
print('scheduler OK')
]=])
local realBindings=scheduler.render({cooperative=true,yieldInterval=1,yieldBudgetMs=8})
util.write('tests/.generated/scheduler_binding.luau',[=[
local now,lookups,waits=0,0,0
local capturedRunning=coroutine.running
local environment={task={wait=function() waits+=1; coroutine.yield('checkpoint') end},
    os={clock=function() return now end},coroutine={isyieldable=coroutine.isyieldable,
        running=function() lookups+=1; return capturedRunning() end}}
local unbound,bind=(function(__ovm_entryenv)
]=]..realBindings.setup..[=[
return __ovm_checkpoint,__ovm_bindcheckpoint end)(environment)
local completed=0
local worker=coroutine.create(function()
    local first,second=bind(),bind()
    first(); now=0.02; first()
    -- First resets after resume; second must use that same updated deadline.
    second()
    assert(waits==1,'another binding yielded immediately after resume')
    local boundary=setmetatable({},{__tostring=function()
        now=now+1; first(); return 'safe'
    end})
    assert(tostring(boundary)=='safe','bound checkpoint yielded through a native boundary')
    first()
    completed+=1
end)
local ok,value=coroutine.resume(worker)
assert(ok and value=='checkpoint' and completed==0)
assert(lookups==2 and waits==1,'bindings repeated per-byte thread lookups')
ok,value=coroutine.resume(worker)
assert(ok and value=='checkpoint' and completed==0)
ok,value=coroutine.resume(worker)
assert(ok and coroutine.status(worker)=='dead' and completed==1)
assert(lookups==2 and waits==2)
print('scheduler binding OK')
]=])
print('Scheduler host checks passed')

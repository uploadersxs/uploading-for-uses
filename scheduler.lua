-- A native wrapper and its outer VM can share one scheduler. Bound closures
-- belong to one coroutine activation; bind again when creating another frame.
-- Checkpoints never attempt to yield through a native boundary.
local M={}

function M.render(config)
    config=config or {}
    assert(type(config)=='table','scheduler config must be a table')
    local enabled=config.cooperative==true
    assert(config.cooperative==nil or type(config.cooperative)=='boolean','cooperative must be a boolean')
    local budget=config.yieldBudgetMs or 8
    local interval=config.yieldInterval or 256
    assert(type(budget)=='number' and budget>0 and budget<=1000,'yieldBudgetMs must be greater than 0 and at most 1000')
    assert(type(interval)=='number' and interval%1==0 and interval>=1 and interval<=65536,'yieldInterval must be an integer between 1 and 65536')
    local result={enabled=enabled,budgetMs=budget,interval=interval,setup='',checkpoint='',binding=''}
    if not enabled then return result end
    local function identifier(value,name)
        assert(type(value)=='string' and value:match('^[%a_][%w_]*$'),name..' must be a local identifier')
        return value
    end
    if config.sharedCheckpoint~=nil then
        local shared=identifier(config.sharedCheckpoint,'sharedCheckpoint')
        result.setup='local __ovm_checkpoint='..shared..'\n'
        result.binding=''
        if config.sharedBinder~=nil then
            local binder=identifier(config.sharedBinder,'sharedBinder')
            result.setup=result.setup..'local __ovm_bindcheckpoint='..binder..'\n'
            result.binding='local __ovm_checkpoint=__ovm_bindcheckpoint()'
        end
        result.checkpoint='__ovm_checkpoint()'
        result.shared=true
        return result
    end
    assert(config.sharedBinder==nil,'sharedBinder requires sharedCheckpoint')
    local environment=config.environment or '__ovm_entryenv'
    assert(type(environment)=='string' and environment:match('^[%a_][%w_]*$'),'scheduler environment must be a local identifier')
    local setup=[=[
local __ovm_schedulerenv=@ENVIRONMENT@
local __ovm_schedulertask,__ovm_scheduleros,__ovm_schedulercoroutine=__ovm_schedulerenv.task,__ovm_schedulerenv.os,__ovm_schedulerenv.coroutine
local __ovm_schedulerwait=type(__ovm_schedulertask)=='table' and __ovm_schedulertask.wait
local __ovm_schedulerclock=type(__ovm_scheduleros)=='table' and __ovm_scheduleros.clock
local __ovm_scheduleryieldable=type(__ovm_schedulercoroutine)=='table' and __ovm_schedulercoroutine.isyieldable
local __ovm_schedulerrunning=type(__ovm_schedulercoroutine)=='table' and __ovm_schedulercoroutine.running
local __ovm_scheduleravailable=type(__ovm_schedulerwait)=='function' and type(__ovm_schedulerclock)=='function' and type(__ovm_scheduleryieldable)=='function' and type(__ovm_schedulerrunning)=='function'
local __ovm_schedulerstates=setmetatable({},{__mode='k'})
local __ovm_schedulermain={ticks=0}
local __ovm_schedulernoop=function() end
local function __ovm_schedulergetstate()
    local __ovm_schedulerthread=__ovm_schedulerrunning()
    local __ovm_schedulerstate
    if __ovm_schedulerthread then __ovm_schedulerstate=__ovm_schedulerstates[__ovm_schedulerthread]
    else __ovm_schedulerstate=__ovm_schedulermain end
    if not __ovm_schedulerstate then
        __ovm_schedulerstate={ticks=0}
        __ovm_schedulerstates[__ovm_schedulerthread]=__ovm_schedulerstate
    end
    return __ovm_schedulerstate
end
local function __ovm_checkpoint()
    if not __ovm_scheduleravailable then return end
    local __ovm_schedulerstate=__ovm_schedulergetstate()
@CHECK@
end
local function __ovm_bindcheckpoint()
    if not __ovm_scheduleravailable then return __ovm_schedulernoop end
    local __ovm_schedulerstate=__ovm_schedulergetstate()
    return function()
@CHECK@
    end
end
]=]
    local check=[=[
    __ovm_schedulerstate.ticks=__ovm_schedulerstate.ticks+1
    if __ovm_schedulerstate.ticks<@INTERVAL@ then return end
    __ovm_schedulerstate.ticks=0
    if not __ovm_scheduleryieldable() then return end
    local __ovm_schedulernow=__ovm_schedulerclock()
    if not __ovm_schedulerstate.deadline then
        __ovm_schedulerstate.deadline=__ovm_schedulernow+@BUDGET@
    elseif __ovm_schedulernow>=__ovm_schedulerstate.deadline then
        __ovm_schedulerstate.deadline=__ovm_schedulernow+@BUDGET@
        __ovm_schedulerwait()
        __ovm_schedulerstate.deadline=__ovm_schedulerclock()+@BUDGET@
    end
]=]
    local values={ENVIRONMENT=environment,INTERVAL=tostring(interval),BUDGET=(string.format('%.17g',budget/1000):gsub(',','.'))}
    check=check:gsub('@([A-Z]+)@',function(key) return assert(values[key]) end)
    values.CHECK=check
    result.setup=setup:gsub('@([A-Z]+)@',function(key) return assert(values[key]) end)
    result.checkpoint='__ovm_checkpoint()'
    result.binding='local __ovm_checkpoint=__ovm_bindcheckpoint()'
    return result
end

return M

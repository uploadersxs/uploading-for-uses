-- Offline startup harness for the real Spin To Upgrade input. Replace the
-- @SPIN_SOURCE@ line with native or generated source before running this file.
-- Workers stay suspended, signals do not fire and remote methods only fail.
local instances, connections, remoteCalls, workers, entryCheckpoints = 0, 0, 0, {}, 0
local ownedThreads={}
local function signal()
    return {Connect = function(_, callback)
        assert(type(callback) == "function")
        connections += 1
        return {Disconnect = function() end}
    end}
end
local eventNames = {
    Activated=true, Focused=true, FocusLost=true, MouseEnter=true, MouseLeave=true,
    InputBegan=true, InputChanged=true, InputEnded=true, OnClientEvent=true,
}
local methods = {}
local function object(class, name)
    instances += 1
    local props, children, signals = {ClassName=class, Name=name or class}, {}, {}
    local item = {}
    setmetatable(item, {
        __index = function(_, key)
            if methods[key] then return methods[key] end
            if props[key] ~= nil then return props[key] end
            if children[key] then return children[key] end
            if eventNames[key] then
                signals[key] = signals[key] or signal()
                return signals[key]
            end
            return nil
        end,
        __newindex = function(_, key, value)
            if key == "Parent" and value then value._children[props.Name] = item end
            props[key] = value
        end,
    })
    rawset(item, "_children", children)
    rawset(item, "_signals", signals)
    return item
end
function methods:GetPropertyChangedSignal(key)
    self._signals[key] = self._signals[key] or signal()
    return self._signals[key]
end
function methods:FindFirstChild(key) return self._children[key] end
function methods:WaitForChild(key) return assert(self._children[key], "Missing mock child: "..key) end
function methods:FindFirstChildOfClass(class)
    for _, child in self._children do if child.ClassName == class then return child end end
end
function methods:IsA(class) return self.ClassName == class end
function methods:GetAttribute() return nil end
function methods:Destroy() self.Destroyed = true end
function methods:QueryDescendants() return {} end
function methods:GetInstanceRemovedSignal(key) return self:GetPropertyChangedSignal(key) end
function methods:GetServerTimeNow() return os.clock() end
function methods:FireServer() remoteCalls += 1; error("Offline harness remote attempt", 0) end
function methods:InvokeServer() remoteCalls += 1; error("Offline harness remote attempt", 0) end
local function attach(parent, name, value)
    parent._children[name] = value
    return value
end
local player = object("Player", "Player")
player.UserId = 1
player.PlayerGui = attach(player,"PlayerGui",object("PlayerGui"))
player.PlayerScripts = attach(player,"PlayerScripts",object("PlayerScripts"))
local client = attach(player.PlayerScripts,"Client",object("Folder","Client"))
local controllers = attach(client,"Controllers",object("Folder","Controllers"))
local replicated = object("ReplicatedStorage")
local sharedModules = attach(replicated,"Shared",object("Folder","Shared"))
local config = attach(sharedModules,"Config",object("Folder","Config"))
local function module(parent, name, value)
    local item = attach(parent,name,object("ModuleScript",name))
    item.Payload = value
end
module(controllers,"DataController",{Data=nil})
module(controllers,"HudController",{stillLoading=function() return false end})
module(sharedModules,"Items",{})
module(sharedModules,"UpgradeMath",{})
module(sharedModules,"EconomyRules",{})
module(sharedModules,"Progression",{})
module(sharedModules,"StockRules",{})
module(sharedModules,"PlotMath",{})
module(sharedModules,"MiningRules",{})
module(sharedModules,"Remotes",{RockHit=object("RemoteEvent","RockHit")})
module(config,"Zones",{{Id="First",Name="First zone",Price=0},{Id="Second",Name="Second zone",Price=100}})
module(config,"Upgrader",{MaxChance=.95})
module(config,"Economy",{SellMultiplier=1})
module(config,"GameSettings",{})
module(config,"Mining",{})
local camera = object("Camera")
camera.ViewportSize = {X=1280,Y=720}
local mockWorkspace = object("Workspace")
mockWorkspace.CurrentCamera = camera
local services = {
    Players={LocalPlayer=player}, UserInputService=object("UserInputService"),
    HttpService={}, ReplicatedStorage=replicated,
    CollectionService=object("CollectionService"), PathfindingService={},
}
local mockGame = {PlaceId=101054234503030}
function mockGame:GetService(name) return assert(services[name], "Missing mock service: "..name) end
local mockShared = {}
local enum = setmetatable({}, {__index=function(self, group)
    local values=setmetatable({}, {__index=function(t, key)
        local value={Name=key}; rawset(t,key,value); return value
    end})
    rawset(self,group,values); return values
end})
local function udim(scale, offset) return {Scale=scale or 0,Offset=offset or 0} end
local function udim2(xs,xo,ys,yo) return {X=udim(xs,xo),Y=udim(ys,yo)} end
local mockTask = {
    spawn=function(callback, ...)
        local worker=coroutine.create(callback)
        table.insert(workers,worker)
        ownedThreads[worker]=true
        return worker
    end,
    delay=function(_, callback) return coroutine.create(callback) end,
    wait=function(duration)
        if ownedThreads[coroutine.running()] and coroutine.isyieldable() then
            return coroutine.yield(duration==0.12 and "spin idle wait" or "spin checkpoint")
        end
        return 0
    end,
    cancel=function(thread) coroutine.close(thread) end,
}
local environment = setmetatable({
    game=mockGame,workspace=mockWorkspace,shared=mockShared,task=mockTask,
    getgenv=function() return mockShared end,
    require=function(item) return assert(item.Payload, "Missing mock module payload") end,
    Instance={new=function(class) return object(class) end},Enum=enum,
    Color3={fromRGB=function(r,g,b) return {R=r/255,G=g/255,B=b/255} end},
    UDim={new=udim},UDim2={new=udim2,
        fromOffset=function(x,y) return udim2(0,x,0,y) end,
        fromScale=function(x,y) return udim2(x,0,y,0) end},
    Vector2={new=function(x,y) return {X=x,Y=y} end},
}, {__index=getfenv()})
local run = function(...)
--@SPIN_SOURCE@
end
setfenv(run,environment)
local entry=coroutine.create(run)
ownedThreads[entry]=true
local result
while true do
    local ok, value=coroutine.resume(entry)
    assert(ok, tostring(value))
    if coroutine.status(entry)=="dead" then result=value; break end
    entryCheckpoints += 1
end
--@SPIN_EXPECT_COOPERATIVE@
assert(type(result)=="table" and result.UI==mockShared.__SpinUI)
assert(result.Planner==mockShared.__SpinPlanner and result.Controller==mockShared.__SpinController)
assert(result.UI.Ready and not result.UI.Destroyed and result.Controller.Alive)
assert(#result.Planner.ZoneNames==2 and #result.UI.Controls.StopZone.Choices==3)
assert(instances>400 and connections>80 and #workers==1,
    string.format("Startup coverage: %d instances, %d connections, %d workers",instances,connections,#workers))
for _, key in {"AutoMine","AutoCollect","AutoSell","AutoStats","AutoMiners","AutoProgress"} do
    assert(result.UI.State[key]==false, "Automation enabled during startup")
end
assert(remoteCalls==0)
-- Resume the scheduler once with no player data: it must safely yield without
-- purchases or an infinite loop, then exercise the exported shutdown callbacks.
while true do
    local ok,value=coroutine.resume(workers[1])
    assert(ok,tostring(value))
    if value=="spin idle wait" then break end
    assert(coroutine.status(workers[1])=="suspended","Scheduler stopped before idle wait")
end
assert(coroutine.status(workers[1])=="suspended" and remoteCalls==0)
result.UI:Destroy()
while coroutine.status(workers[1])~="dead" do
    local ok,value=coroutine.resume(workers[1])
    assert(ok,tostring(value))
end
assert(result.UI.Destroyed and not result.Controller.Alive)
assert(mockShared.__SpinUI==nil and mockShared.__SpinController==nil and remoteCalls==0)
print("spin mock OK")
--@SPIN_REPORT@

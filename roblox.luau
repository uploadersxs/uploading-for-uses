-- Run inside Roblox Studio on the server and client. All instances and signal
-- connections belong to this fixture and are cleaned up before returning.
assert(typeof(game) == 'Instance')
assert(typeof(workspace) == 'Instance')
assert(game:GetService('RunService') ~= nil)
local folder = Instance.new('Folder')
folder.Name = 'VerityCompatibilityFixture'
local part = Instance.new('Part')
part.Name = 'TestPart'
part.Anchored = true
part.Size = Vector3.new(2,3,4)
part:SetAttribute('counter', 17)
part.Parent = folder
assert(folder:FindFirstChild('TestPart') == part)
assert(part:GetAttribute('counter') == 17)
assert(part.Size.X == 2 and part.Size.Y == 3)
local bindable = Instance.new('BindableEvent')
local seen = nil
local connection = bindable.Event:Connect(function(value, missing, flag)
    assert(missing == nil and flag == false)
    seen = value
end)
bindable:Fire('callback', nil, false)
task.wait()
assert(seen == 'callback')
connection:Disconnect()
bindable:Destroy()
folder:Destroy()
print('Roblox compatibility OK')

-- Luau keeps simple own-local operands live until their instruction executes.
local arithmetic = 1
local function mutateArithmetic()
    arithmetic = 100
    return 2
end
assert(arithmetic + mutateArithmetic() == 102)

local compound = 1
local function mutateCompound()
    compound = 100
    return 2
end
compound += mutateCompound()
assert(compound == 102)

local captured = 1
local function mutateCaptured()
    captured = 100
    return 2
end
local function updateCaptured()
    captured += mutateCaptured()
    return captured
end
assert(updateCaptured() == 3)

local object = { x = 1 }
local oldObject = object
local function replaceObject()
    object = { x = 9 }
    return 2
end
object.x += replaceObject()
assert(object.x == 3 and oldObject.x == 1)

local target = { x = 1 }
local oldTarget = target
local function replaceTarget()
    target = { x = 9 }
    return 2
end
target.x = replaceTarget()
assert(target.x == 2 and oldTarget.x == 1)

local key = "x"
local keyed = { x = 1, y = 2 }
local function changeKey()
    key = "y"
    return 5
end
keyed[key] += changeKey()
assert(keyed.x == 1 and keyed.y == 6)

local readObject = { x = 1 }
local function changeReadObject()
    readObject = { x = 9 }
    return "x"
end
assert(readObject[changeReadObject()] == 9)

local constructorKey = "x"
local function changeConstructorKey()
    constructorKey = "y"
    return 3
end
local constructed = { [constructorKey] = changeConstructorKey() }
assert(constructed.x == nil and constructed.y == 3)

-- Assignment target conflicts save table operands before evaluating the RHS.
local index = 1
local indexed = {}
index, indexed[index] = 2, 3
assert(index == 2 and indexed[1] == 3 and indexed[2] == nil)
local replacement = { x = 1 }
local oldReplacement = replacement
replacement, replacement.x = { x = 9 }, 3
assert(replacement.x == 9 and oldReplacement.x == 3)

-- A no-op own-local self assignment retains a later RHS mutation.
local selfAssigned = 1
local function changeSelfAssigned()
    selfAssigned = 100
    return 2
end
local second
selfAssigned, second = selfAssigned, changeSelfAssigned()
assert(selfAssigned == 100 and second == 2)
local duplicate = 1
duplicate, duplicate = 2, duplicate
assert(duplicate == 1)

-- Call operands, list constructor operands and new locals are snapshots.
local callable = function() return "old" end
local function replaceCallable()
    callable = function() return "new" end
    return 1
end
assert(callable(replaceCallable()) == "old")
local arrayValue = 1
local function changeArrayValue()
    arrayValue = 100
    return 2
end
local array = { arrayValue, changeArrayValue() }
assert(array[1] == 1 and array[2] == 2)

-- Literal array allocation determines Luau's border for sparse positional lists.
local sparse = { 1, nil, 3 }
assert(#sparse == 3 and sparse[2] == nil and sparse[3] == 3)
local function sparseTail() return nil, 3, nil, 5 end
local expandedSparse = { 1, sparseTail() }
assert(#expandedSparse == 5 and expandedSparse[2] == nil and expandedSparse[5] == 5)

print("evaluation OK")

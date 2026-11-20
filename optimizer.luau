local function pack(...) return { n = select("#", ...), ... } end
local trace = {}
local function mark(label, ...)
    trace[#trace + 1] = label
    return ...
end

-- Single requested values truncate calls; excess expressions still execute.
local single = mark("single", nil, false, 3)
assert(single == nil)
local first, second, third = mark("multiple", nil, false, 3)
assert(first == nil and second == false and third == 3)
local excess = 1, mark("excess-first", 2, 3), mark("excess-last", nil, 4)
assert(excess == 1)
excess = 5, mark("assignment-excess", nil, false)
assert(excess == 5)
assert(table.concat(trace, ",") == "single,multiple,excess-first,excess-last,assignment-excess")

-- Missing values become nil while earlier RHS reads remain snapshots.
local missingA, missingB
assert(missingA == nil and missingB == nil)
local leading, trailingA, trailingB = 8, mark("tail", nil, false)
assert(leading == 8 and trailingA == nil and trailingB == false)
local snapshot = 9
local function changeSnapshot()
    snapshot = 100
    return nil, 20
end
local oldSnapshot, onlyFirst = snapshot, changeSnapshot()
assert(oldSnapshot == 9 and onlyFirst == nil and snapshot == 100)

-- Target preparation, self-assignment quirks and duplicate targets survive.
local index = 1
local indexed = {}
index, indexed[index] = 2, 7
assert(index == 2 and indexed[1] == 7 and indexed[2] == nil)
local selfAssigned = 1
local function changeSelfAssigned()
    selfAssigned = 30
    return 4
end
local extra
selfAssigned, extra = selfAssigned, changeSelfAssigned()
assert(selfAssigned == 30 and extra == 4)
local duplicate = 1
duplicate, duplicate = 2, duplicate
assert(duplicate == 1)

-- Empty and one-nil returns are distinct; discarded calls can still yield.
local function empty() return end
local function oneNil() return nil end
assert(pack(empty()).n == 0 and pack(oneNil()).n == 1)
local resumed = false
local function discarded()
    coroutine.yield("discarded", nil)
    resumed = true
    return nil, false, 8
end
local suspended = coroutine.create(function()
    local value = 1, discarded()
    discarded()
    return value
end)
local yielded = pack(coroutine.resume(suspended))
assert(yielded.n == 3 and yielded[1] and yielded[2] == "discarded" and yielded[3] == nil)
yielded = pack(coroutine.resume(suspended))
assert(resumed and yielded.n == 3 and yielded[1] and yielded[2] == "discarded")
local completed = pack(coroutine.resume(suspended))
assert(completed.n == 2 and completed[1] and completed[2] == 1)

-- Disjoint scalar slots can be reused while escaped cells remain alive.
local escaped
do
    local captured=10
    escaped=function(value) captured+=value; return captured end
end
do local reused=3; assert(reused==3) end
assert(escaped(2)==12 and escaped(-1)==11)
local function ignoredParameter(unused,value) return value end
assert(ignoredParameter(100,nil)==nil and ignoredParameter(nil,7)==7)
print("optimizer OK")

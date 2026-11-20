local function pack(...) return { n = select("#", ...), ... } end

-- Three lexical levels capture the same mutable cell and independent shadows.
local function owner(initial)
    local value = initial
    local function middle(delta)
        local increment = delta
        return function(amount)
            value += amount * increment
            return value
        end
    end
    return middle, function() return value end
end
local middle, read = owner(5)
local addTwo, addThree = middle(2), middle(3)
assert(addTwo(4) == 13 and addThree(2) == 19 and read() == 19)
local otherMiddle, otherRead = owner(100)
assert(otherMiddle(7)(1) == 107 and otherRead() == 107 and read() == 19)

-- Each execution of a declaration creates a cell even in nested loop scopes.
local retained = {}
for outer = 1, 3 do
    local shared = outer * 10
    retained[outer] = {}
    for inner = 1, 2 do
        local private = inner
        retained[outer][inner] = function(change)
            shared += change
            private += 1
            return shared, private, outer, inner
        end
    end
end
local s, p, o, i = retained[1][1](2)
assert(s == 12 and p == 2 and o == 1 and i == 1)
s, p, o, i = retained[1][2](3)
assert(s == 15 and p == 3 and o == 1 and i == 2)
s, p, o, i = retained[2][1](7)
assert(s == 27 and p == 2 and o == 2 and i == 1)

local repeatCount = 0
local repeatClosures = {}
repeat
    repeatCount += 1
    local iteration = repeatCount
    repeatClosures[iteration] = function() return iteration end
    if repeatCount < 3 then continue end
until iteration == 3
assert(repeatClosures[1]() == 1 and repeatClosures[2]() == 2 and repeatClosures[3]() == 3)

-- Reassigning visible generic-for variables does not alter its hidden control.
local controls = {}
local function iterator(state, control)
    if control == nil then return false, "first", nil end
    if control == false then return 2, "second", 30 end
    if control == 2 then return 3, "third", 40 end
end
local genericCount = 0
for control, label, extra in iterator, nil, nil do
    genericCount += 1
    controls[genericCount] = pack(control, label, extra)
    control = 100
    if genericCount == 2 then continue end
end
assert(genericCount == 3 and controls[1][1] == false and controls[1].n == 3)
assert(controls[2][1] == 2 and controls[3][3] == 40)

local sequence = { 1, 2, 3 }
local sequenceSum = 0
for index, value in ipairs(sequence) do
    if index == 1 then sequence[2] = 20 end
    sequenceSum += value
end
assert(sequenceSum == 24)

-- All trailing expressions expand only in contexts that accept multiple values.
local function sparseValues() return nil, false, 9, nil end
local function relay(...) return ... end
local relayed = pack(relay(4, sparseValues()))
assert(relayed.n == 5 and relayed[1] == 4 and relayed[2] == nil)
assert(relayed[3] == false and relayed[4] == 9 and relayed[5] == nil)
local truncated = pack((sparseValues()))
assert(truncated.n == 1 and truncated[1] == nil)

-- CONCAT uses snapshots even though numeric arithmetic borrows own locals.
local concatenated = "old"
local function changeConcatenated()
    concatenated = "new"
    return "!"
end
assert(concatenated .. changeConcatenated() == "old!")
local compoundConcatenated = "old"
local function changeCompoundConcatenated()
    compoundConcatenated = "new"
    return "!"
end
compoundConcatenated ..= changeCompoundConcatenated()
assert(compoundConcatenated == "old!")

local callable = setmetatable({ total = 0 }, {
    __call = function(self, ...)
        local values = pack(...)
        self.total += values.n
        return self.total, nil, values[1]
    end,
})
local called = pack(callable(7, nil, 9))
assert(called.n == 3 and called[1] == 3 and called[2] == nil and called[3] == 7)

-- Native userdata colon calls use __namecall without an __index method.
local proxy = newproxy(true)
local proxyMetatable = getmetatable(proxy)
proxyMetatable.__namecall = function(self, ...)
    local arguments = pack(...)
    assert(self == proxy)
    return "initial", arguments.n, arguments[1], arguments[2]
end
local namecalled = pack(proxy:invoke(7, nil))
assert(namecalled.n == 4 and namecalled[1] == "initial" and namecalled[2] == 2)
assert(namecalled[3] == 7 and namecalled[4] == nil)
local function replaceNamecall()
    proxyMetatable.__namecall = function(self, ...)
        return "replacement", ...
    end
    return 9
end
local replacedNamecall = pack(proxy:invoke(replaceNamecall()))
assert(replacedNamecall.n == 2 and replacedNamecall[1] == "replacement" and replacedNamecall[2] == 9)

-- Virtualized functions can suspend with nil-valued results and resume normally.
local suspended = coroutine.create(function(...)
    local incoming = pack(...)
    local response = pack(coroutine.yield(incoming.n, nil, incoming[1]))
    return response.n, response[1], response[2]
end)
local yielded = pack(coroutine.resume(suspended, 8, nil))
assert(yielded.n == 4 and yielded[1] and yielded[2] == 2 and yielded[4] == 8)
local completed = pack(coroutine.resume(suspended, nil, 12))
assert(completed.n == 4 and completed[1] and completed[2] == 2)
assert(completed[3] == nil and completed[4] == 12)

print("advanced OK")

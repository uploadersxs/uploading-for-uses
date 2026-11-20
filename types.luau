-- Type functions and aliases belong to compilation and must never run in the VM.
type function Identity<T>(ty: type): type
    error('compile-time function was executed')
    return ty
end
type function Readonly(ty: type): type
    local result = types.newtable()
    for key, property in ty:properties() do
        result:setreadproperty(key, property.read)
    end
    return result
end
export type Box<T=number, Args...=(string, number)> = {
    read value: T,
    write [string]: any,
    callback: (T, Args...) -> T?,
}
type Primitive = | 'left' | 'right' | nil
type Record = & {read a: number} & {write b: string}
type Array = {read number}
type MutableArray = {write string}
type Transformed = Identity<number>
type PackFunction<A..., B...=(number, string)> = <T>(T, A...) -> (T, B...)
local object: Box<number> = {value=42, callback=function(value) return value end}
local cast = object :: Box<number>
assert(cast.value == 42)
local const = 'contextual identifier'
assert(const == 'contextual identifier')
const answer: number = 42
const label: string = 'immutable'
@native
const function square(value: number): number
    return value * value
end
@checked
local function identity<T>(value: T): T
    return value
end
@native @checked
const function captured(): (number, string)
    return answer, label
end
@deprecated
local function old() return 1 end
local anonymous = @native function(value: number): number return value + 1 end
local a, b = captured()
assert(a == 42 and b == 'immutable')
assert(square(identity(3)) == 9 and anonymous(3) == 4 and old() == 1)
type FromValue = typeof(object)
local nullable: (number | nil)? = nil
assert(nullable == nil)
print('types OK')

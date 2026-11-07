import RuntimeABI

/// The built-in `List` contract (§7.4): a host-owned ordered collection of
/// objects. Contract parameters and results of type `[String]` or
/// `[SomeContract]` travel as a `List`.
public enum RuntimeList {

    /// Contract name.
    public static let name: StaticString = "org.pureswift.runtime.List"

    public static let classReference = ClassReference(name)

    public static let makeMethod = MethodReference(classReference, "make", "()O", .constructor)

    public static let countMethod = MethodReference(classReference, "count", "()I")

    public static let objectAtMethod = MethodReference(classReference, "objectAt:", "(I)O")

    public static let appendMethod = MethodReference(classReference, "append:", "(O)V")

    /// The contract descriptor hosts register.
    public static var descriptor: ContractDescriptor {
        BuiltinContracts.list
    }

    /// Creates an empty list. Returns a +1 handle.
    public static func make() -> ObjectHandle {
        Call(makeMethod).invokeOrTrap().handle()
    }

    /// Creates a list holding the given objects, then releases the +1
    /// handles passed in. Returns a +1 handle to the list.
    public static func make(retainedHandles handles: [ObjectHandle]) -> ObjectHandle {
        let list = make()
        for handle in handles {
            var call = Call(appendMethod, target: list)
            call.add(retained: handle)
            _ = call.invokeOrTrap()
        }
        return list
    }

    /// Creates a list of host strings. Returns a +1 handle.
    public static func make(strings: [String]) -> ObjectHandle {
        make(retainedHandles: strings.map(Runtime.makeString))
    }

    /// Number of elements.
    public static func count(_ list: ObjectHandle) -> Int32 {
        Call(countMethod, target: list).invokeOrTrap().scalar()
    }

    /// +1 handles to every element, in order.
    public static func retainedHandles(_ list: ObjectHandle) -> [ObjectHandle] {
        let count = count(list)
        guard count > 0 else { return [] }
        var handles = [ObjectHandle]()
        handles.reserveCapacity(Int(count))
        for index in 0..<count {
            var call = Call(objectAtMethod, target: list)
            call.add(index)
            handles.append(call.invokeOrTrap().handle())
        }
        return handles
    }

    /// Copies a list of strings out.
    public static func strings(_ list: ObjectHandle) -> [String] {
        retainedHandles(list).map { handle in
            defer { Runtime.release(handle) }
            return Runtime.string(handle)
        }
    }
}

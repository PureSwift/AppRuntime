import RuntimeABI

/// Runs a call to a contract method declared with untyped `throws` and maps
/// whatever it throws to `RuntimeError`, so it can cross the boundary as
/// `RT_ERR_THROWN`. Used by generated dispatch code.
public func rethrowingRuntimeError<T>(_ body: () throws -> T) throws(RuntimeError) -> T {
    do {
        return try body()
    } catch let error as RuntimeError {
        throw error
    } catch {
        throw RuntimeError.thrown("error")
    }
}

import CRuntime
import RuntimeNative

/// The app library's exports: a sealed slice's or wasm2c output's
/// `rt_main`, `rt_dispatch` and `rt_finalize`.
///
/// ```swift
/// AppEntryPoints(main: rt_main, dispatch: rt_dispatch, finalize: rt_finalize)
/// ```
public struct AppEntryPoints {

    public var main: () -> rt_status

    public var dispatch: NativeGuest.EntryPoints.Dispatch

    public var finalize: NativeGuest.EntryPoints.Finalize

    public init(
        main: @escaping () -> rt_status,
        dispatch: NativeGuest.EntryPoints.Dispatch,
        finalize: NativeGuest.EntryPoints.Finalize
    ) {
        self.main = main
        self.dispatch = dispatch
        self.finalize = finalize
    }
}

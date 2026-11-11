/// A type whose stored properties report reads and changes (§5.3).
///
/// The stopgap for the toolchain's `Observation` module in Embedded guests:
/// the API follows the index-only entry points of the Swift Forums pitch
/// "Observation performance and modeling improvements", so app code compiles
/// unchanged when the toolchain module replaces this one. Guest builds name
/// this module `Observation`; host builds call it `DynamicObservation`, since
/// Apple's SDKs already have an `Observation`.
public protocol Observable { }

/// What `@Observable` generates so `@Bindable` works without key paths:
/// a `Bindings` value with one `Binding` per stored property, which
/// `Bindable.projectedValue` returns, so `$model.name` works.
///
/// Stopgap only: Embedded Swift 6.4 has no key paths, which Apple's
/// `@Bindable` uses.
public protocol _BindableObservable: Observable, AnyObject {

    associatedtype Bindings

    var _$bindings: Bindings { get }
}

/// Makes a class observable: each stored property reads through
/// `access(propertyIndex:)` and writes through `withMutation(propertyIndex:_:)`,
/// with indices assigned in declaration order. `@ObservationIgnored`
/// excludes a property.
@attached(member, names: named(_$observationRegistrar), named(access), named(withMutation), named(Bindings), named(_$bindings))
@attached(memberAttribute)
@attached(extension, conformances: Observable, _BindableObservable)
public macro Observable() = #externalMacro(module: "ObservationMacros", type: "ObservableMacro")

/// Added to each tracked stored property by `@Observable`.
@attached(accessor, names: named(init), named(get), named(set), named(_modify))
@attached(peer, names: prefixed(_))
public macro ObservationTracked(index: Int) = #externalMacro(module: "ObservationMacros", type: "ObservationTrackedMacro")

/// Leaves a stored property of an `@Observable` class untracked.
@attached(peer)
public macro ObservationIgnored() = #externalMacro(module: "ObservationMacros", type: "ObservationIgnoredMacro")

import DynamicUI

// MARK: - Values from the host

/// Whether the window is narrow or wide, or short or tall.
public enum UserInterfaceSizeClass: String, Sendable, CaseIterable {
    case compact, regular
}

public enum ColorScheme: String, Sendable, CaseIterable {
    case light, dark
}

public enum ColorSchemeContrast: String, Sendable, CaseIterable {
    case standard, increased
}

/// The user's text size, smallest first.
public enum DynamicTypeSize: String, Sendable, CaseIterable, Comparable {

    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

    /// The five largest sizes, which accessibility settings give.
    public var isAccessibilitySize: Bool {
        self >= .accessibility1
    }

    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    public static func < (lhs: DynamicTypeSize, rhs: DynamicTypeSize) -> Bool {
        lhs.order < rhs.order
    }
}

public enum LayoutDirection: String, Sendable, CaseIterable {
    case leftToRight, rightToLeft
}

public enum LegibilityWeight: String, Sendable, CaseIterable {
    case regular, bold
}

// MARK: - Values from the guest

/// Closes what a view is in: a sheet, a pushed level, or a column a
/// collapsed split view shows. Anywhere else it does nothing.
public struct DismissAction {

    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    static var none: DismissAction { DismissAction { } }

    public func callAsFunction() {
        action()
    }
}

// MARK: - Keys

/// An app's own environment value: its type and its default.
public protocol EnvironmentKey {

    associatedtype Value

    static var defaultValue: Value { get }
}

/// What a view inherits from its ancestors, and from the host's window.
///
/// Embedded Swift has no key paths, so a value is named by a static member
/// of `EnvironmentValues.Key`: `@Environment(.colorScheme)` where SwiftUI
/// writes `@Environment(\.colorScheme)`.
public struct EnvironmentValues {

    /// The host's values, with the ones a subtree set.
    var window = RenderEnvironment()

    var custom: [ObjectIdentifier: AnyObject] = [:]

    var dismiss = DismissAction.none

    var isPresented = false

    var isEnabled = true

    var scenePhase = ScenePhase.active

    var openURL = OpenURLAction.system

    public init() { }

    /// One value: how to read it and set it.
    public struct Key<Value> {

        let read: (EnvironmentValues) -> Value

        let write: (inout EnvironmentValues, Value) -> Void

        init(read: @escaping (EnvironmentValues) -> Value, write: @escaping (inout EnvironmentValues, Value) -> Void) {
            self.read = read
            self.write = write
        }

        /// An app's own value:
        ///
        /// ```swift
        /// extension EnvironmentValues.Key where Value == Theme {
        ///     static var theme: Self { Self(ThemeKey.self) }
        /// }
        /// ```
        public init<K: EnvironmentKey>(_ key: K.Type) where K.Value == Value {
            // A class's metatype: Embedded Swift keeps one for each
            // specialization, which it doesn't for a struct's.
            let id = ObjectIdentifier(EnvironmentKeyToken<K>.self)
            self.read = { values in
                guard let box = values.custom[id] else { return K.defaultValue }
                return unsafeDowncast(box, to: EnvironmentBox<Value>.self).value
            }
            self.write = { values, value in
                values.custom[id] = EnvironmentBox(value)
            }
        }
    }

    /// A key for one of the host's values, with its default.
    static func window<Value>(
        _ get: @escaping (RenderEnvironment) -> Value?,
        _ set: @escaping (inout RenderEnvironment, Value) -> Void,
        default value: Value
    ) -> Key<Value> {
        Key(read: { get($0.window) ?? value }, write: { set(&$0.window, $1) })
    }
}

/// Names an app's own key in `EnvironmentValues`.
final class EnvironmentKeyToken<Key> { }

final class EnvironmentBox<Value> {

    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

extension EnvironmentValues.Key where Value == UserInterfaceSizeClass? {

    public static var horizontalSizeClass: Self {
        Self(read: { $0.window.horizontalSizeClass.flatMap { UserInterfaceSizeClass(rawValue: $0.rawValue) } },
             write: { $0.window.horizontalSizeClass = $1.flatMap { RenderEnvironment.SizeClass(rawValue: $0.rawValue) } })
    }

    public static var verticalSizeClass: Self {
        Self(read: { $0.window.verticalSizeClass.flatMap { UserInterfaceSizeClass(rawValue: $0.rawValue) } },
             write: { $0.window.verticalSizeClass = $1.flatMap { RenderEnvironment.SizeClass(rawValue: $0.rawValue) } })
    }
}

extension EnvironmentValues.Key where Value == ColorScheme {

    public static var colorScheme: Self {
        EnvironmentValues.window({ $0.colorScheme.flatMap { ColorScheme(rawValue: $0.rawValue) } },
                                 { $0.colorScheme = RenderEnvironment.ColorScheme(rawValue: $1.rawValue) },
                                 default: .light)
    }
}

extension EnvironmentValues.Key where Value == ColorSchemeContrast {

    public static var colorSchemeContrast: Self {
        EnvironmentValues.window({ $0.colorSchemeContrast.flatMap { ColorSchemeContrast(rawValue: $0.rawValue) } },
                                 { $0.colorSchemeContrast = RenderEnvironment.Contrast(rawValue: $1.rawValue) },
                                 default: .standard)
    }
}

extension EnvironmentValues.Key where Value == DynamicTypeSize {

    public static var dynamicTypeSize: Self {
        EnvironmentValues.window({ $0.dynamicTypeSize.flatMap { DynamicTypeSize(rawValue: $0.rawValue) } },
                                 { $0.dynamicTypeSize = RenderEnvironment.TypeSize(rawValue: $1.rawValue) },
                                 default: .large)
    }
}

extension EnvironmentValues.Key where Value == LayoutDirection {

    public static var layoutDirection: Self {
        EnvironmentValues.window({ $0.layoutDirection.flatMap { LayoutDirection(rawValue: $0.rawValue) } },
                                 { $0.layoutDirection = RenderEnvironment.LayoutDirection(rawValue: $1.rawValue) },
                                 default: .leftToRight)
    }
}

extension EnvironmentValues.Key where Value == LegibilityWeight? {

    public static var legibilityWeight: Self {
        Self(read: { $0.window.legibilityWeight.flatMap { LegibilityWeight(rawValue: $0.rawValue) } },
             write: { $0.window.legibilityWeight = $1.flatMap { RenderEnvironment.LegibilityWeight(rawValue: $0.rawValue) } })
    }
}

extension EnvironmentValues.Key where Value == CGFloat {

    /// Pixels per point.
    public static var displayScale: Self {
        EnvironmentValues.window({ $0.displayScale }, { $0.displayScale = $1 }, default: 1)
    }
}

extension EnvironmentValues.Key where Value == Bool {

    public static var accessibilityReduceMotion: Self {
        EnvironmentValues.window({ $0.reduceMotion }, { $0.reduceMotion = $1 }, default: false)
    }

    public static var accessibilityReduceTransparency: Self {
        EnvironmentValues.window({ $0.reduceTransparency }, { $0.reduceTransparency = $1 }, default: false)
    }

    public static var accessibilityDifferentiateWithoutColor: Self {
        EnvironmentValues.window({ $0.differentiateWithoutColor }, { $0.differentiateWithoutColor = $1 }, default: false)
    }

    /// Whether the view is in a sheet's content or a pushed level.
    public static var isPresented: Self {
        Self(read: { $0.isPresented }, write: { $0.isPresented = $1 })
    }

    /// `false` under `disabled(true)`.
    public static var isEnabled: Self {
        Self(read: { $0.isEnabled }, write: { $0.isEnabled = $1 })
    }
}

extension EnvironmentValues.Key where Value == DismissAction {

    public static var dismiss: Self {
        Self(read: { $0.dismiss }, write: { $0.dismiss = $1 })
    }
}

// MARK: - Reading

/// Finds what an ancestor put in the environment.
///
/// Embedded Swift can't list a view's properties, so a value is found where
/// it's read. While views render, that's the innermost body being
/// evaluated, once per update: a view kept across updates, such as the
/// root or a link's destination, sees each update's values. In an event's
/// handler, it's the view whose body made the handler, so `dismiss()` in a
/// button's action is the button's view's. Elsewhere, in a task, it's what
/// was found last.
final class EnvironmentStorage<Value> {

    let find: (RenderContext) -> Value?

    var value: Value?

    /// The update `value` was found in.
    private var generation: UInt64?

    init(_ find: @escaping (RenderContext) -> Value?) {
        self.find = find
    }

    func resolve() -> Value? {
        guard let graph = ViewGraph.current, let context = graph.contexts.last else { return value }
        if graph.isEvaluating, generation == graph.currentGeneration, value != nil {
            return value
        }
        // An object that isn't here yet may be found later in the update.
        if let found = find(context) {
            value = found
            generation = graph.isEvaluating ? graph.currentGeneration : nil
        }
        return value
    }
}

/// A value from the environment: one of the host's or the guest's,
/// `@Environment(.colorScheme)`, or an `@Observable` object from an
/// ancestor's `environment(_:)`, `@Environment(Model.self)`.
///
/// SwiftUI's key-path form, `@Environment(\.colorScheme)`, needs key paths,
/// which Embedded Swift doesn't have.
@propertyWrapper
public struct Environment<Value> {

    let storage: EnvironmentStorage<Value>

    let fallback: (() -> Value)?

    /// A value, read the first time the view uses it while it renders.
    public init(_ key: EnvironmentValues.Key<Value>) {
        storage = EnvironmentStorage { key.read($0.values) }
        fallback = { key.read(EnvironmentValues()) }
    }

    public init(_ type: Value.Type) where Value: AnyObject {
        storage = EnvironmentStorage { $0.object(Value.self) }
        fallback = nil
        _ = storage.resolve()
    }

    public var wrappedValue: Value {
        if let value = storage.resolve() {
            return value
        }
        guard let fallback else {
            fatalError("No object of this type found. A View.environment(_:) for it may be missing as an ancestor of this view.")
        }
        return fallback()
    }
}

/// An `ObservableObject` from an ancestor's `environmentObject(_:)`.
@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject> {

    let storage = EnvironmentStorage<ObjectType> { $0.object(ObjectType.self) }

    public init() {
        _ = storage.resolve()
    }

    public var wrappedValue: ObjectType {
        guard let object = storage.resolve() else {
            fatalError("No ObservableObject of this type found. A View.environmentObject(_:) for it may be missing as an ancestor of this view.")
        }
        return object
    }
}

// MARK: - Setting

/// A view whose descendants see a changed `RenderContext`.
public struct _EnvironmentView<Content: View>: View {

    let content: Content

    let transform: (inout RenderContext) -> Void

    public var body: Never {
        fatalError()
    }

    /// The host's values the change set go into the IR as an inherited
    /// `environment` modifier, so the host draws the subtree with them.
    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var changed = context
        transform(&changed)
        let before = context.values.window.props
        var set: [String: PropValue] = [:]
        for (key, value) in changed.values.window.props where before[key] != value {
            set[key] = value
        }
        let start = nodes.count
        content._render(into: &nodes, context: changed)
        guard !set.isEmpty else { return }
        for index in nodes.indices where index >= start {
            nodes[index].modifiers.append(ModifierNode("environment", set))
        }
    }
}

extension View {

    /// Sets an environment value for this view and its descendants. One of
    /// the host's values is drawn that way too.
    public func environment<Value>(_ key: EnvironmentValues.Key<Value>, _ value: Value) -> _EnvironmentView<Self> {
        _EnvironmentView(content: self) { key.write(&$0.values, value) }
    }

    /// Makes `object` available to `@EnvironmentObject` in descendants.
    public func environmentObject<T: ObservableObject>(_ object: T) -> _EnvironmentView<Self> {
        _EnvironmentView(content: self) { $0.objects.append((ObjectIdentifier(T.self), object)) }
    }

    /// Makes an `@Observable` object available to `@Environment(T.self)` in
    /// descendants.
    public func environment<T: Observable & AnyObject>(_ object: T) -> _EnvironmentView<Self> {
        _EnvironmentView(content: self) { $0.objects.append((ObjectIdentifier(T.self), object)) }
    }

    /// Asks for the window's color scheme, or the sheet's this view is in.
    /// `nil` gives back the system's.
    public func preferredColorScheme(_ scheme: ColorScheme?) -> _ModifierView<Self> {
        modified("preferredColorScheme", scheme.map { ["scheme": .string($0.rawValue)] } ?? [:])
    }
}

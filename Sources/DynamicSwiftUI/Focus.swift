import DynamicUI

/// Which view has the keyboard, as state: SwiftUI's `@FocusState`.
///
/// ```swift
/// @FocusState private var editing: Bool
///
/// TextEditor(buffer)
///     .focused($editing)
///
/// Button("Edit") { editing = true }
/// ```
///
/// For several fields, the value says which:
///
/// ```swift
/// enum Field { case name, email }
/// @FocusState private var field: Field?
///
/// TextField("Name", text: $name).focused($field, equals: .name)
/// TextField("Email", text: $email).focused($field, equals: .email)
/// ```
///
/// Setting it gives the view the keyboard, or puts the keyboard away. It
/// follows the user too: it changes when they tap into a field or leave it.
/// Kept across updates and matched by position, like `@State`.
@propertyWrapper
public struct FocusState<Value: Hashable> {

    let box: StateBox<Value>

    /// What it is when no view it's bound to has the keyboard.
    let unfocused: Value

    init(unfocused: Value) {
        self.unfocused = unfocused
        if let graph = ViewGraph.current, graph.isEvaluating {
            box = graph.stateBox { unfocused }
        } else {
            box = StateBox(unfocused)
        }
    }

    public init() where Value == Bool {
        self.init(unfocused: false)
    }

    public init<T: Hashable>() where Value == T? {
        self.init(unfocused: nil)
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    public var projectedValue: Binding {
        Binding(box: box, unfocused: unfocused)
    }

    /// What `focused` takes: `$editing`.
    @propertyWrapper
    public struct Binding {

        let box: StateBox<Value>

        let unfocused: Value

        public var wrappedValue: Value {
            get { box.value }
            nonmutating set { box.value = newValue }
        }

        public var projectedValue: Binding {
            self
        }
    }
}

/// When the keyboard capitalizes what's typed.
public struct TextInputAutocapitalization: Equatable, Sendable {

    let mode: String

    public static let never = TextInputAutocapitalization(mode: "never")

    public static let words = TextInputAutocapitalization(mode: "words")

    public static let sentences = TextInputAutocapitalization(mode: "sentences")

    public static let characters = TextInputAutocapitalization(mode: "characters")
}

extension View {

    /// Ties this view's keyboard focus to `condition`: true while it has
    /// the keyboard. For a `TextField` or a `TextEditor`.
    ///
    /// The node gets a `focused` modifier with `value`, and the host
    /// reports `focus` when the user moves the keyboard in or out.
    public func focused(_ condition: FocusState<Bool>.Binding) -> _ModifierView<Self> {
        focused(condition, equals: true)
    }

    /// Ties this view's keyboard focus to `binding`: it has the keyboard
    /// while the binding equals `value`.
    public func focused<Value: Hashable>(_ binding: FocusState<Value>.Binding, equals value: Value) -> _ModifierView<Self> {
        let isFocused = binding.wrappedValue == value
        return _ModifierView(content: self, modifier: ModifierNode("focused", ["value": .bool(isFocused)])) { id, graph in
            graph.on(id, .focus) { payload in
                guard let focused = payload?.bool else { return }
                if focused {
                    binding.wrappedValue = value
                } else if binding.wrappedValue == value {
                    // Left for somewhere that isn't bound; a view that is
                    // says so itself.
                    binding.wrappedValue = binding.unfocused
                }
            }
        }
    }

    /// Whether the keyboard corrects what's typed in the text views here.
    /// Inherited by descendants.
    public func autocorrectionDisabled(_ disable: Bool = true) -> _ModifierView<Self> {
        modified("autocorrection", ["disabled": .bool(disable)])
    }

    /// When the keyboard capitalizes what's typed in the text views here;
    /// `nil` is the platform's way. Inherited by descendants.
    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> _ModifierView<Self> {
        modified("autocapitalization", autocapitalization.map { ["mode": .string($0.mode)] } ?? [:])
    }
}

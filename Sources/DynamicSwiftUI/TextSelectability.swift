import DynamicUI

/// Whether the user can select a view's text: SwiftUI's protocol, for
/// `textSelection(_:)`.
public protocol TextSelectability {

    static var allowsSelection: Bool { get }
}

public struct EnabledTextSelectability: TextSelectability {

    public static let allowsSelection = true
}

public struct DisabledTextSelectability: TextSelectability {

    public static let allowsSelection = false
}

extension TextSelectability where Self == EnabledTextSelectability {

    /// The user can select the text and copy it.
    public static var enabled: EnabledTextSelectability {
        EnabledTextSelectability()
    }
}

extension TextSelectability where Self == DisabledTextSelectability {

    public static var disabled: DisabledTextSelectability {
        DisabledTextSelectability()
    }
}

extension View {

    /// Lets the user select the text in this view and copy it, with the
    /// platform's own menu and shortcuts. Inherited by descendants.
    ///
    /// ```swift
    /// Text(contact.phone)
    ///     .textSelection(.enabled)
    /// ```
    ///
    /// The nodes get a `textSelection` modifier with `enabled`. Nothing
    /// reaches the guest: the selection and the copy are the host's.
    public func textSelection<S: TextSelectability>(_ selectability: S) -> _ModifierView<Self> {
        modified("textSelection", ["enabled": .bool(S.allowsSelection)])
    }
}

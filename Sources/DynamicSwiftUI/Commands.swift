import DynamicUI

// MARK: - Keyboard shortcuts

/// A key a shortcut presses: a character, or one of the named keys.
public struct KeyEquivalent: Equatable, Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {

    /// A character, or a named key: `return`, `escape`, `upArrow`…
    public let name: String

    init(name: String) {
        self.name = name
    }

    /// A character key, as `"s"`.
    public init(_ character: String) {
        self.name = character
    }

    public init(extendedGraphemeClusterLiteral value: String) {
        self.name = value
    }

    public static let `return` = KeyEquivalent(name: "return")
    public static let escape = KeyEquivalent(name: "escape")
    public static let delete = KeyEquivalent(name: "delete")
    public static let deleteForward = KeyEquivalent(name: "deleteForward")
    public static let tab = KeyEquivalent(name: "tab")
    public static let space = KeyEquivalent(name: "space")
    public static let upArrow = KeyEquivalent(name: "upArrow")
    public static let downArrow = KeyEquivalent(name: "downArrow")
    public static let leftArrow = KeyEquivalent(name: "leftArrow")
    public static let rightArrow = KeyEquivalent(name: "rightArrow")
    public static let home = KeyEquivalent(name: "home")
    public static let end = KeyEquivalent(name: "end")
    public static let pageUp = KeyEquivalent(name: "pageUp")
    public static let pageDown = KeyEquivalent(name: "pageDown")
}

/// The keys held with a shortcut. `.command` is ⌘ on Apple platforms and
/// Ctrl elsewhere; `.control` is Ctrl, and ⌃ on Apple platforms.
public struct EventModifiers: OptionSet, Hashable, Sendable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = EventModifiers(rawValue: 1)
    public static let shift = EventModifiers(rawValue: 2)
    public static let option = EventModifiers(rawValue: 4)
    public static let control = EventModifiers(rawValue: 8)

    var names: [PropValue] {
        var names: [PropValue] = []
        if contains(.command) { names.append("command") }
        if contains(.shift) { names.append("shift") }
        if contains(.option) { names.append("option") }
        if contains(.control) { names.append("control") }
        return names
    }
}

/// A key and its modifiers.
public struct KeyboardShortcut: Equatable, Hashable, Sendable {

    public var key: KeyEquivalent

    public var modifiers: EventModifiers

    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Return, for the button that does what the view is for.
    public static let defaultAction = KeyboardShortcut(.return, modifiers: [])

    /// Escape, for the button that backs out.
    public static let cancelAction = KeyboardShortcut(.escape, modifiers: [])
}

extension View {

    /// Presses the button when the keys are: on a `Button`, or on a view for
    /// each button in it that has no shortcut of its own. A disabled button's
    /// does nothing.
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> _ModifierView<Self> {
        keyboardShortcut(KeyboardShortcut(key, modifiers: modifiers))
    }

    public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> _ModifierView<Self> {
        modified("keyboardShortcut", [
            "key": .string(shortcut.key.name),
            "modifiers": .array(shortcut.modifiers.names),
        ])
    }

    /// `nil` takes away a shortcut set further out.
    public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> _ModifierView<Self> {
        guard let shortcut else {
            return modified("keyboardShortcut", [:])
        }
        return keyboardShortcut(shortcut)
    }
}

// MARK: - Commands

/// The app's menus, in `WindowGroup`'s `commands`: `CommandMenu`s and
/// `CommandGroup`s. A command is a `Button`, as in a `Menu`.
///
/// They're views, so a type of the app's own is `struct EditCommands:
/// Commands { var body: some Commands { … } }`, as in SwiftUI.
public protocol Commands: View { }

/// What builds commands: the frontend's view builder.
public typealias CommandsBuilder = ViewBuilder

/// A menu of the app's own, after the standard ones.
public struct CommandMenu<Content: View>: Commands, PrimitiveView {

    let title: String

    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("CommandMenu", id: id, props: ["title": .string(title)], children: context.children(content))
    }
}

/// Where in a standard menu a group goes.
public struct CommandGroupPlacement: Equatable, Sendable {

    let name: String

    public static let appInfo = CommandGroupPlacement(name: "appInfo")
    public static let appSettings = CommandGroupPlacement(name: "appSettings")
    public static let newItem = CommandGroupPlacement(name: "newItem")
    public static let saveItem = CommandGroupPlacement(name: "saveItem")
    public static let importExport = CommandGroupPlacement(name: "importExport")
    public static let printItem = CommandGroupPlacement(name: "printItem")
    public static let undoRedo = CommandGroupPlacement(name: "undoRedo")
    public static let pasteboard = CommandGroupPlacement(name: "pasteboard")
    public static let textEditing = CommandGroupPlacement(name: "textEditing")
    public static let toolbar = CommandGroupPlacement(name: "toolbar")
    public static let sidebar = CommandGroupPlacement(name: "sidebar")
    public static let help = CommandGroupPlacement(name: "help")
}

/// Commands in a standard menu: before or after a group, or in its place.
public struct CommandGroup<Content: View>: Commands, PrimitiveView {

    let placement: CommandGroupPlacement

    let position: String

    let content: Content

    public init(before placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement
        self.position = "before"
        self.content = addition()
    }

    public init(after placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement
        self.position = "after"
        self.content = addition()
    }

    /// Takes the platform's items out of the group.
    public init(replacing placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement
        self.position = "replacing"
        self.content = addition()
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("CommandGroup", id: id, props: [
            "placement": .string(placement.name),
            "position": .string(position),
        ], children: context.children(content))
    }
}

/// The window's content with the app's menus: a `Commands` node, the
/// content its first child, the menus and groups after it. The commands
/// are evaluated with each update, so they follow what they read.
public struct _CommandsRoot<Content: View, Menus: View>: View {

    let content: Content

    let menus: () -> Menus

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        var children = context.children(content)
        children += context.children(menus())
        nodes.append(RenderNode("Commands", id: id, children: children))
    }
}

extension WindowGroup {

    /// The app's menus: `CommandMenu`s and `CommandGroup`s. A host with no
    /// menu bar keeps their shortcuts, and shows none of them.
    public func commands<Menus: View>(@ViewBuilder content: @escaping () -> Menus) -> WindowGroup<_CommandsRoot<Content, Menus>> {
        WindowGroup<_CommandsRoot<Content, Menus>> {
            _CommandsRoot(content: self.content, menus: content)
        }
    }
}

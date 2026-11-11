import DynamicRuntime
import DynamicUI
#if canImport(DynamicObservation)
import DynamicObservation
#else
import Observation
#endif

/// Where a view graph sends its trees: the host's `Renderer`, or a test.
public protocol RenderSink: AnyObject {

    /// Everything on screen is now `tree`.
    func apply(_ tree: RenderNode)

    /// The node `id` and its subtree are now `subtree`.
    func replace(_ id: RenderNode.ID, with subtree: RenderNode)
}

/// Evaluates a view tree into render IR and keeps it current (§9.1, §9.5).
///
/// The guest's side of the UI: no layout and no rendering. Each update
/// evaluates `body`s inside one coalescing Observation listener, so a change
/// to any `@State` or `@Observable` property read while rendering schedules
/// the next update. Updates are sent just before control returns to the host
/// (`GuestExecutor.whenIdle`), diffed against the last tree: the smallest
/// changed subtrees go out with `replace`, a changed root with `apply`.
///
/// Identity comes from position, since Embedded Swift has no reflection:
/// each composed view's `body` runs in a scope keyed by its parent's scope
/// and its place among its siblings. `@State` created while a `body` runs
/// takes the next slot in its scope, and each node the next node ID.
/// Containers and `if` branches open their own scopes, so a view behind an
/// `if` doesn't shift the identity of the views after it.
///
/// The guest is single-threaded (§6.4).
public final class ViewGraph {

    /// The graph being evaluated, for property wrappers created in a `body`.
    nonisolated(unsafe) static var current: ViewGraph?

    /// Every live graph, for `ObservableObject`, whose objects don't know
    /// which graphs use them.
    nonisolated(unsafe) static var live: [Unmanaged<ViewGraph>] = []

    private let renderRoot: (inout [RenderNode], RenderContext) -> Void

    private let sink: RenderSink

    private var listener: ObservationTracking.Listener!

    /// The tree on screen, as the host last received it.
    public private(set) var tree: RenderNode?

    private(set) var needsUpdate = true

    private var scheduled = false

    // MARK: Pass state

    private var generation: UInt64 = 0

    private(set) var isEvaluating = false

    private var scopeKey: UInt64 = 0

    private var childIndex: UInt64 = 0

    private var stateIndex: UInt64 = 0

    private var nodeIndex: UInt64 = 0

    /// The lazy list whose row is being rendered (its node ID), or 0.
    private var rowOwner: RenderNode.ID = 0

    /// Contexts of the bodies being evaluated, innermost last, for
    /// `@EnvironmentObject` and `@Environment`.
    private(set) var contexts: [RenderContext] = []

    // MARK: Registries

    private struct Slot {
        let key: UInt64
        let box: AnyObject
        var lastUsed: UInt64
        /// The lazy list a row's state belongs to, or 0 for the main tree.
        let owner: RenderNode.ID
    }

    private var slots: [Slot] = []

    struct EventKey: Hashable {
        let node: RenderNode.ID
        let kind: Int32
    }

    typealias Handler = (PropValue?) -> Void

    private var handlers: [EventKey: Handler] = [:]

    private var pendingHandlers: [EventKey: Handler] = [:]

    private final class LazyList {
        let count: Int
        let row: (Int) -> RenderNode
        var rowHandlers: [Int: [EventKey: Handler]] = [:]
        var rowListeners: [Int: ObservationTracking.Listener] = [:]

        init(count: Int, row: @escaping (Int) -> RenderNode) {
            self.count = count
            self.row = row
        }
    }

    private var lists: [RenderNode.ID: LazyList] = [:]

    private var pendingLists: [RenderNode.ID: LazyList] = [:]

    struct Appearance {
        let node: RenderNode.ID
        let onAppear: (() -> Void)?
        let onDisappear: (() -> Void)?
    }

    private var appearances: [Appearance] = []

    private var pendingAppearances: [Appearance] = []

    /// Bumped every update, so lazy lists re-fetch their visible rows.
    private var revision = 0

    // MARK: Lifecycle

    public init<Root: View>(_ root: Root, sink: RenderSink) {
        self.renderRoot = { nodes, context in root._render(into: &nodes, context: context) }
        self.sink = sink
        self.listener = ObservationTracking.Listener { [unowned(unsafe) self] in
            self.setNeedsUpdate()
        }
        Self.live.append(Unmanaged.passUnretained(self))
    }

    deinit {
        Self.live.removeAll { $0.toOpaque() == Unmanaged.passUnretained(self).toOpaque() }
    }

    /// Schedules an update before control returns to the host. Outside a
    /// host call (tests), call `update()` yourself.
    public func setNeedsUpdate() {
        needsUpdate = true
        guard !scheduled, !isEvaluating, GuestExecutor.isInHostCall else { return }
        scheduled = true
        GuestExecutor.whenIdle { [self] in
            scheduled = false
            if needsUpdate {
                update()
            }
        }
    }

    static func setAllNeedUpdate() {
        for graph in live {
            graph.takeUnretainedValue().setNeedsUpdate()
        }
    }

    /// Evaluates the views and sends what changed.
    public func update() {
        needsUpdate = false
        generation &+= 1
        revision &+= 1
        scopeKey = 0xcbf2_9ce4_8422_2325
        childIndex = 0
        stateIndex = 0
        nodeIndex = 0
        pendingHandlers = [:]
        pendingLists = [:]
        pendingAppearances = []

        let previous = Self.current
        Self.current = self
        isEvaluating = true
        let nodes = listener.track { () -> [RenderNode] in
            var nodes: [RenderNode] = []
            renderRoot(&nodes, RenderContext())
            return nodes
        }
        isEvaluating = false
        Self.current = previous

        let root = nodes.count == 1 ? nodes[0] : RenderNode("VStack", id: Self.mix(0x524f_4f54, 0), props: [
            "alignment": "center", "spacing": .double(defaultSpacing),
        ], children: nodes)

        handlers = pendingHandlers
        pendingHandlers = [:]
        lists = pendingLists
        pendingLists = [:]
        slots.removeAll { slot in
            slot.owner == 0 ? slot.lastUsed != generation : lists[slot.owner] == nil
        }
        send(root)

        // Handlers may change state, which schedules another update.
        let before = appearances
        appearances = pendingAppearances
        pendingAppearances = []
        for old in before where !appearances.contains(where: { $0.node == old.node }) {
            old.onDisappear?()
        }
        for new in appearances where !before.contains(where: { $0.node == new.node }) {
            new.onAppear?()
        }
    }

    private func send(_ root: RenderNode) {
        guard let old = tree, old.id == root.id, old.type == root.type else {
            tree = root
            sink.apply(root)
            return
        }
        var changes: [RenderNode] = []
        Self.diff(old, root, into: &changes)
        tree = root
        if changes.contains(where: { $0.id == root.id }) {
            sink.apply(root)
            return
        }
        for change in changes {
            sink.replace(change.id, with: change)
        }
    }

    /// The smallest subtrees of `new` that differ from `old`.
    static func diff(_ old: RenderNode, _ new: RenderNode, into changes: inout [RenderNode]) {
        guard old.id == new.id,
              old.type == new.type,
              old.props == new.props,
              old.modifiers == new.modifiers,
              old.count == new.count,
              old.children.count == new.children.count,
              zip(old.children, new.children).allSatisfy({ $0.id == $1.id && $0.type == $1.type }) else {
            changes.append(new)
            return
        }
        for (oldChild, newChild) in zip(old.children, new.children) where oldChild != newChild {
            diff(oldChild, newChild, into: &changes)
        }
    }

    // MARK: Events from the host

    /// Runs the handler a node registered for `kind`. Returns whether there
    /// was one.
    @discardableResult
    public func handle(_ node: RenderNode.ID, kind: RenderEventKind, payload: PropValue? = nil) -> Bool {
        let key = EventKey(node: node, kind: kind.rawValue)
        if let handler = handlers[key] {
            handler(payload)
            return true
        }
        for list in lists.values {
            for rowHandlers in list.rowHandlers.values {
                if let handler = rowHandlers[key] {
                    handler(payload)
                    return true
                }
            }
        }
        return false
    }

    public func rowCount(_ list: RenderNode.ID) -> Int {
        lists[list]?.count ?? 0
    }

    /// Renders row `index` of a lazy list, tracking what it reads.
    public func row(_ list: RenderNode.ID, index: Int) -> RenderNode? {
        guard let lazy = lists[list], index >= 0, index < lazy.count else { return nil }
        let savedHandlers = pendingHandlers
        let savedOwner = rowOwner
        pendingHandlers = [:]
        rowOwner = list
        let previous = Self.current
        Self.current = self
        let wasEvaluating = isEvaluating
        isEvaluating = true
        let listener = ObservationTracking.Listener { [unowned(unsafe) self] in
            self.setNeedsUpdate()
        }
        let row = listener.track { lazy.row(index) }
        isEvaluating = wasEvaluating
        Self.current = previous
        lazy.rowHandlers[index] = pendingHandlers
        lazy.rowListeners[index] = listener
        pendingHandlers = savedHandlers
        rowOwner = savedOwner
        return row
    }

    // MARK: Scopes, state and IDs

    struct Scope {
        let key: UInt64
        let childIndex: UInt64
        let stateIndex: UInt64
        let nodeIndex: UInt64
    }

    func enterScope() -> Scope {
        let saved = Scope(key: scopeKey, childIndex: childIndex + 1, stateIndex: stateIndex, nodeIndex: nodeIndex)
        scopeKey = Self.mix(scopeKey, childIndex)
        childIndex = 0
        stateIndex = 0
        nodeIndex = 0
        return saved
    }

    /// Keyed by `identity` instead of position: for `ForEach` elements and
    /// `if` branches.
    func enterScope(identity: UInt64) -> Scope {
        let saved = enterScope()
        scopeKey = Self.mix(saved.key ^ 0x4944_0000_0000_0000, identity)
        return saved
    }

    func exitScope(_ scope: Scope) {
        scopeKey = scope.key
        childIndex = scope.childIndex
        stateIndex = scope.stateIndex
        nodeIndex = scope.nodeIndex
    }

    /// Runs `body` in a child scope.
    func scoped<T>(identity: UInt64? = nil, _ body: () -> T) -> T {
        let scope = identity.map { enterScope(identity: $0) } ?? enterScope()
        defer { exitScope(scope) }
        return body()
    }

    /// The current scope, for lazy containers to render rows in later.
    var currentScopeKey: UInt64 {
        scopeKey
    }

    /// Runs `body` in the scope of a lazy row: keyed by its list's scope and
    /// the row's identity, whenever the host asks for it.
    func rowScope<T>(listScope: UInt64, identity: UInt64, _ body: () -> T) -> T {
        let saved = Scope(key: scopeKey, childIndex: childIndex, stateIndex: stateIndex, nodeIndex: nodeIndex)
        scopeKey = Self.mix(listScope ^ 0x524f_5700_0000_0000, identity)
        childIndex = 0
        stateIndex = 0
        nodeIndex = 0
        defer { exitScope(saved) }
        return body()
    }

    /// The ID of the next node rendered at this position.
    func nextNodeID() -> RenderNode.ID {
        let id = Self.mix(scopeKey ^ 0x4e4f_4445_0000_0000, nodeIndex)
        nodeIndex += 1
        return id
    }

    /// A key for something at this position that needs an identity across
    /// updates (a navigation stack, for example).
    func nextKey() -> UInt64 {
        let key = Self.mix(scopeKey ^ 0x4b45_5900_0000_0000, stateIndex)
        stateIndex += 1
        return key
    }

    /// The state box for the next `@State` at this position, made with
    /// `make` the first time.
    func stateBox<Value>(_ make: () -> Value) -> StateBox<Value> {
        let key = Self.mix(scopeKey ^ 0x5354_4154_4500_0000, stateIndex)
        stateIndex += 1
        if let index = slots.firstIndex(where: { $0.key == key }) {
            slots[index].lastUsed = generation
            return unsafeDowncast(slots[index].box, to: StateBox<Value>.self)
        }
        let box = StateBox(make())
        slots.append(Slot(key: key, box: box, lastUsed: generation, owner: rowOwner))
        return box
    }

    // MARK: Registration during a pass

    func on(_ node: RenderNode.ID, _ kind: RenderEventKind, _ handler: @escaping Handler) {
        pendingHandlers[EventKey(node: node, kind: kind.rawValue)] = handler
    }

    func lazyList(_ node: RenderNode.ID, count: Int, row: @escaping (Int) -> RenderNode) {
        pendingLists[node] = LazyList(count: count, row: row)
    }

    func register(_ appearance: Appearance) {
        pendingAppearances.append(appearance)
    }

    var currentRevision: Int {
        revision
    }

    func pushContext(_ context: RenderContext) {
        contexts.append(context)
    }

    func popContext() {
        contexts.removeLast()
    }

    /// FNV-1a over the 8 bytes of `value`, continuing from `hash`.
    static func mix(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        var result = hash
        var remaining = value
        for _ in 0..<8 {
            result = (result ^ (remaining & 0xff)) &* 0x0000_0100_0000_01b3
            remaining >>= 8
        }
        return result
    }
}

/// The default stack spacing, written into the IR so layout matches across
/// hosts (§9.2).
let defaultSpacing: Double = 8

/// The default padding.
let defaultPadding: Double = 16

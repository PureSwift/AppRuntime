/// A window's values, as a renderer reports them (`Documentation/Environment.md`):
/// the payload of `Renderer.environment()` and of an `environment` event, and
/// the args of an `environment` modifier.
///
/// The payload is one array: a key, then its value, then the next key. A
/// value that is `nil` here is one the host didn't report, and takes its
/// default; a key this doesn't know is skipped.
public struct RenderEnvironment: Equatable, Sendable {

    public enum SizeClass: String, Sendable, CaseIterable {
        case compact, regular
    }

    public enum ColorScheme: String, Sendable, CaseIterable {
        case light, dark
    }

    public enum Contrast: String, Sendable, CaseIterable {
        case standard, increased
    }

    /// The user's text size, smallest first.
    public enum TypeSize: String, Sendable, CaseIterable {
        case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
        case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

        /// The body text's size over `large`'s, from iOS's body sizes (14 to
        /// 53 points over 17).
        public var ratio: Double {
            switch self {
            case .xSmall: return 0.82
            case .small: return 0.88
            case .medium: return 0.94
            case .large: return 1
            case .xLarge: return 1.12
            case .xxLarge: return 1.24
            case .xxxLarge: return 1.35
            case .accessibility1: return 1.65
            case .accessibility2: return 1.94
            case .accessibility3: return 2.35
            case .accessibility4: return 2.76
            case .accessibility5: return 3.12
            }
        }

        /// The size whose ratio is nearest `scale`, a platform's text scale
        /// (Android's `fontScale`, GNOME's `text-scaling-factor`). Halfway
        /// between two, the one nearer `large`: Android's 0.85 is `small`.
        public init(scale: Double) {
            var best = TypeSize.large
            for size in TypeSize.allCases {
                let distance = abs(size.ratio - scale)
                let bestDistance = abs(best.ratio - scale)
                if distance < bestDistance - 1e-9
                    || (abs(distance - bestDistance) <= 1e-9 && abs(size.ratio - 1) < abs(best.ratio - 1)) {
                    best = size
                }
            }
            self = best
        }
    }

    public enum LayoutDirection: String, Sendable, CaseIterable {
        case leftToRight, rightToLeft
    }

    public enum LegibilityWeight: String, Sendable, CaseIterable {
        case regular, bold
    }

    public var horizontalSizeClass: SizeClass?

    public var verticalSizeClass: SizeClass?

    public var colorScheme: ColorScheme?

    public var colorSchemeContrast: Contrast?

    public var dynamicTypeSize: TypeSize?

    public var layoutDirection: LayoutDirection?

    public var legibilityWeight: LegibilityWeight?

    /// Pixels per point.
    public var displayScale: Double?

    public var reduceMotion: Bool?

    public var reduceTransparency: Bool?

    public var differentiateWithoutColor: Bool?

    public init(
        horizontalSizeClass: SizeClass? = nil,
        verticalSizeClass: SizeClass? = nil,
        colorScheme: ColorScheme? = nil,
        colorSchemeContrast: Contrast? = nil,
        dynamicTypeSize: TypeSize? = nil,
        layoutDirection: LayoutDirection? = nil,
        legibilityWeight: LegibilityWeight? = nil,
        displayScale: Double? = nil,
        reduceMotion: Bool? = nil,
        reduceTransparency: Bool? = nil,
        differentiateWithoutColor: Bool? = nil
    ) {
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.colorScheme = colorScheme
        self.colorSchemeContrast = colorSchemeContrast
        self.dynamicTypeSize = dynamicTypeSize
        self.layoutDirection = layoutDirection
        self.legibilityWeight = legibilityWeight
        self.displayScale = displayScale
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.differentiateWithoutColor = differentiateWithoutColor
    }

    /// Whether no value is set.
    public var isEmpty: Bool {
        self == RenderEnvironment()
    }

    // MARK: Keys

    public enum Key {
        public static let horizontalSizeClass = "horizontalSizeClass"
        public static let verticalSizeClass = "verticalSizeClass"
        public static let colorScheme = "colorScheme"
        public static let colorSchemeContrast = "colorSchemeContrast"
        public static let dynamicTypeSize = "dynamicTypeSize"
        public static let layoutDirection = "layoutDirection"
        public static let legibilityWeight = "legibilityWeight"
        public static let displayScale = "displayScale"
        public static let reduceMotion = "accessibilityReduceMotion"
        public static let reduceTransparency = "accessibilityReduceTransparency"
        public static let differentiateWithoutColor = "accessibilityDifferentiateWithoutColor"
    }

    // MARK: As props

    /// The values that are set, by key: an `environment` modifier's args.
    public var props: [String: PropValue] {
        var props: [String: PropValue] = [:]
        if let horizontalSizeClass { props[Key.horizontalSizeClass] = .string(horizontalSizeClass.rawValue) }
        if let verticalSizeClass { props[Key.verticalSizeClass] = .string(verticalSizeClass.rawValue) }
        if let colorScheme { props[Key.colorScheme] = .string(colorScheme.rawValue) }
        if let colorSchemeContrast { props[Key.colorSchemeContrast] = .string(colorSchemeContrast.rawValue) }
        if let dynamicTypeSize { props[Key.dynamicTypeSize] = .string(dynamicTypeSize.rawValue) }
        if let layoutDirection { props[Key.layoutDirection] = .string(layoutDirection.rawValue) }
        if let legibilityWeight { props[Key.legibilityWeight] = .string(legibilityWeight.rawValue) }
        if let displayScale { props[Key.displayScale] = .double(displayScale) }
        if let reduceMotion { props[Key.reduceMotion] = .bool(reduceMotion) }
        if let reduceTransparency { props[Key.reduceTransparency] = .bool(reduceTransparency) }
        if let differentiateWithoutColor { props[Key.differentiateWithoutColor] = .bool(differentiateWithoutColor) }
        return props
    }

    /// The values in `props`. A key it doesn't know, or a value of the wrong
    /// kind, is skipped.
    public init(props: [String: PropValue]) {
        self.init()
        for (key, value) in props {
            set(key, value)
        }
    }

    private mutating func set(_ key: String, _ value: PropValue) {
        switch key {
        case Key.horizontalSizeClass: horizontalSizeClass = value.string.flatMap(SizeClass.init(rawValue:))
        case Key.verticalSizeClass: verticalSizeClass = value.string.flatMap(SizeClass.init(rawValue:))
        case Key.colorScheme: colorScheme = value.string.flatMap(ColorScheme.init(rawValue:))
        case Key.colorSchemeContrast: colorSchemeContrast = value.string.flatMap(Contrast.init(rawValue:))
        case Key.dynamicTypeSize: dynamicTypeSize = value.string.flatMap(TypeSize.init(rawValue:))
        case Key.layoutDirection: layoutDirection = value.string.flatMap(LayoutDirection.init(rawValue:))
        case Key.legibilityWeight: legibilityWeight = value.string.flatMap(LegibilityWeight.init(rawValue:))
        case Key.displayScale: displayScale = value.double
        case Key.reduceMotion: reduceMotion = value.bool
        case Key.reduceTransparency: reduceTransparency = value.bool
        case Key.differentiateWithoutColor: differentiateWithoutColor = value.bool
        default: break
        }
    }

    /// The values set in `other` replace these.
    public func merging(_ other: RenderEnvironment) -> RenderEnvironment {
        var merged = self
        for (key, value) in other.props {
            merged.set(key, value)
        }
        return merged
    }

    // MARK: On the wire

    /// The payload: the set values' keys and values, alternating, in key
    /// order.
    public var payload: PropValue {
        var items: [PropValue] = []
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            items.append(.string(key))
            items.append(value)
        }
        return .array(items)
    }

    /// The values in a payload. Anything but an array of keys and values is
    /// no values.
    public init(payload: PropValue?) {
        self.init()
        guard case .array(let items)? = payload else { return }
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].string {
                set(key, items[index + 1])
            }
            index += 2
        }
    }

    /// The payload as `Renderer.environment()` answers it.
    public var bytes: [UInt8] {
        RenderCodec.encode(payload: payload)
    }

    /// The values in `Renderer.environment()`'s answer; `nil` for no bytes,
    /// a renderer from before version 2, or bytes that don't decode.
    public init?(bytes: [UInt8]) {
        guard !bytes.isEmpty, let payload = try? RenderCodec.decode(payload: bytes) else { return nil }
        self.init(payload: payload)
    }
}

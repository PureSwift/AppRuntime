# Environment values and split views

**Status:** implemented: the contract's version 2, `RenderEnvironment`,
the frontend's values, `dismiss`, `NavigationSplitView` and
`List(selection:)`, with `ExampleNotes` on three engines. No platform
host reports the values or draws a split view yet. What changed while
building is at the end.

Second in the first wave's order (`PlannedApps.md`): every app at tablet
and desktop width needs a sidebar, and a guest can't tell today how wide
its window is, whether it's dark, or how large the user's text is.

`@Environment` reads only objects now, `@Environment(Model.self)`.
SwiftUI's `@Environment(\.colorScheme)` needs a key path, and Embedded
Swift 6.4 still refuses one: "cannot use key path in embedded Swift"
(tried with the 6.4.2 toolchain for `wasm32-unknown-none-wasm`).

| Where | What changes |
|---|---|
| `DynamicSwiftUI` | `@Environment(.colorScheme)` and the other values; `environment(_:_:)`; an app's own `EnvironmentKey`s; `dismiss`; `preferredColorScheme(_:)`; `NavigationSplitView`; `List(selection:)` |
| `Renderer` contract | version 2: `environment()` |
| Render IR | the `environment` event (7); `NavSplit` and `NavColumn` nodes; `List`'s `selection`; the `environment` and `preferredColorScheme` modifiers |
| `DynamicUI` | `RenderEnvironment`: the values as the IR carries them, for hosts written in Swift |

No capability, and nothing in the manifest.

## What shapes it

- **No key paths.** The spelling is `@Environment(.colorScheme)`, one
  character from SwiftUI's: a port changes `\.` to `.`. The name is a
  static member of `EnvironmentValues.Key<Value>`, so the value's type is
  inferred as it is in SwiftUI. This compiles in Embedded Swift 6.4 with
  no type annotation on the property, and so does an app's own key.
- **The host knows, the guest decides.** The host measures the window and
  reads the system's settings; the guest picks a layout from them. Values
  change rarely: a rotation, split screen, the switch to dark mode, a new
  text size. A resize that keeps the size class sends nothing.
- **Per window.** Each `Renderer` is one window, and has its own values.
- **The host collapses a split view.** Every platform has a split view
  that turns into a stack at narrow widths, with its own back gesture,
  sidebar button and keyboard handling. The guest keeps which column is
  shown when it's collapsed, as it keeps a stack's path.
- **Add-only.** An older guest ignores an event kind it doesn't know,
  which `HostRenderer` does today. On an older host, which has no
  `environment()`, the values are their defaults and a split view is drawn
  as a stack, since that host doesn't know the new nodes.

## For a guest

### Reading values

```swift
struct InboxView: View {
    @Environment(.horizontalSizeClass) var sizeClass
    @Environment(.dynamicTypeSize) var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading) { sender; subject }
        } else {
            HStack { sender; Spacer(); subject }
        }
    }
}
```

From the host:

| Value | Type | Without a report |
|---|---|---|
| `horizontalSizeClass`, `verticalSizeClass` | `UserInterfaceSizeClass?` (`compact`, `regular`) | `nil` |
| `colorScheme` | `ColorScheme` (`light`, `dark`) | `light` |
| `colorSchemeContrast` | `ColorSchemeContrast` (`standard`, `increased`) | `standard` |
| `dynamicTypeSize` | `DynamicTypeSize` (`xSmall` … `xxxLarge`, `accessibility1` … `accessibility5`; comparable, `isAccessibilitySize`) | `large` |
| `layoutDirection` | `LayoutDirection` (`leftToRight`, `rightToLeft`) | `leftToRight` |
| `legibilityWeight` | `LegibilityWeight?` (`regular`, `bold`) | `nil` |
| `displayScale` | `CGFloat` | 1 |
| `accessibilityReduceMotion` | `Bool` | `false` |
| `accessibilityReduceTransparency` | `Bool` | `false` |
| `accessibilityDifferentiateWithoutColor` | `Bool` | `false` |

From the guest itself:

| Value | Type | What it is |
|---|---|---|
| `dismiss` | `DismissAction` | closes what the view is in (below) |
| `isPresented` | `Bool` | whether the view is in a sheet or a pushed level |
| `isEnabled` | `Bool` | `false` under `disabled(true)` |

A value is read when the view is made, as objects are now. When the
host's values change, the window's views are evaluated again in the next
update, and the diff sends what changed. Changes are rare enough that the
whole window is fine; per-view re-evaluation (`Implementation.md` §6) would
narrow it.

### Setting values

`.environment(.colorScheme, .dark)` sets a value for a subtree.

For a value that comes from the host, the subtree is drawn that way too.
The setting goes into the IR as an inherited `environment` modifier, and
the host draws the subtree with dark colors, a larger text size, right to
left, or a split view collapsed into a stack.

`.preferredColorScheme(.dark)` asks for the whole window, or for the sheet
the view is in. `nil` gives back the system's.

### An app's own values

```swift
struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.standard
}

extension EnvironmentValues.Key where Value == Theme {
    static var theme: Self { Self(ThemeKey.self) }
}

// .environment(.theme, .night)  …  @Environment(.theme) var theme
```

SwiftUI declares a property on `EnvironmentValues`, by hand or with
`@Entry`. Neither can be read without a key path.

### Dismissing

```swift
@Environment(.dismiss) var dismiss
// …
Button("Done") { dismiss() }
```

In a sheet's content, `dismiss()` closes the sheet. In a level pushed onto
a stack, it goes back from that level. In a column a collapsed split view
shows, it goes back a column. Anywhere else it does nothing, as in SwiftUI.

### Split views

```swift
struct NotesApp: View {
    @State var folder: Folder.ID?
    @State var note: Note.ID?

    var body: some View {
        NavigationSplitView {
            List(store.folders, selection: $folder) { folder in
                Label(folder.name, systemImage: "folder")
            }
            .navigationTitle("Folders")
        } content: {
            if let folder {
                List(store.notes(in: folder), selection: $note) { note in
                    Text(note.title)
                }
                .navigationTitle(store.name(of: folder))
            } else {
                Text("No folder")
            }
        } detail: {
            if let note {
                NoteView(note: note)
            } else {
                Text("No note")
            }
        }
    }
}
```

- Two columns (`sidebar`, `detail`) or three (`sidebar`, `content`,
  `detail`).
- At regular width the host shows the columns side by side. At compact
  width it shows them as a stack: the sidebar first, and the next column
  pushed when the user picks a row or follows a link. Going back goes
  back a column.
- **`List(selection:)`** in a column: picking a row sets the binding and,
  collapsed, shows the next column. Going back clears it, as SwiftUI does.
  The selection is the row's identifier: the element's `id`, or its
  `tag(_:)` in a list of views. One row at a time. A row without one
  can't be picked.
- **`NavigationLink(destination:)`** in a column that has no stack of its
  own shows the destination in the next column, in place of that column's
  closure.
- **A `NavigationStack` in a column** works as it does on its own.
  Collapsed, its levels follow the columns in the one stack.
- `columnVisibility:` binds a `NavigationSplitViewVisibility`
  (`automatic`, `all`, `doubleColumn`, `detailOnly`), and
  `preferredCompactColumn:` a `NavigationSplitViewColumn` (`sidebar`,
  `content`, `detail`), as in SwiftUI.
- `navigationSplitViewStyle(_:)` (`automatic`, `balanced`,
  `prominentDetail`), `navigationSplitViewColumnWidth(_:)` and
  `navigationSplitViewColumnWidth(min:ideal:max:)`, and a column's own
  `navigationTitle` and `toolbar`.
- **On an older host** it's a `NavigationStack`: the sidebar is its root,
  and the next column is pushed when a row is picked. That is what a phone
  shows anyway.

Outside a split view, `List(selection:)` highlights the row the binding
names.

## The contract

```swift
@DynamicRuntime("org.pureswift.ui.Renderer", version: 2)
public protocol Renderer: AnyObject {

    static func make(_ delegate: RendererDelegate) -> Self

    func apply(_ tree: [UInt8])

    func replaceSubtree(_ id: [UInt8], tree: [UInt8])

    /// Since version 2. The window's values, as an `environment` event's
    /// payload. The guest asks once, before its first tree.
    func environment() -> [UInt8]
}
```

`RendererDelegate` doesn't change. A change arrives as
`event(node, kind: 7, payload)` with node ID 0, which stands for the
window. The guest never gives a node ID 0.

Whether `environment()` is there also tells the guest whether the host
knows the version 2 nodes, `NavSplit` and `NavColumn`.

### The values on the wire

A payload is one array: a key, then its value, then the next key. A report
carries every value the host knows; a key it leaves out takes its default.
The guest ignores a key it doesn't know.

| Key | Value |
|---|---|
| `horizontalSizeClass`, `verticalSizeClass` | `compact`, `regular` |
| `colorScheme` | `light`, `dark` |
| `colorSchemeContrast` | `standard`, `increased` |
| `dynamicTypeSize` | `xSmall`, `small`, `medium`, `large`, `xLarge`, `xxLarge`, `xxxLarge`, `accessibility1` … `accessibility5` |
| `layoutDirection` | `leftToRight`, `rightToLeft` |
| `legibilityWeight` | `regular`, `bold` |
| `displayScale` | double: pixels per point |
| `accessibilityReduceMotion`, `accessibilityReduceTransparency`, `accessibilityDifferentiateWithoutColor` | bool |

`RenderEnvironment` in `DynamicUI` holds these, with the payload's
encoding and decoding, so a host written in Swift doesn't write its own.

### Rules every host follows

- **Before the first tree:** `environment()` answers with what the window
  will be drawn with. If the window isn't up yet, the main screen's.
- **After that:** one `environment` event for each change, carrying every
  value. Values that change together, such as both size classes in a
  rotation, are one event. Not during a resize, unless a size class
  changes.
- **Size classes** are the platform's own where it has them (iOS).
  Elsewhere they come from the window's size in points: horizontally
  compact below 600 wide and regular from 600, vertically compact below
  480 high. These are Material's breakpoints. An iPad app in a third of
  the screen is compact too.
- **Text size** is the size whose ratio to `large` is nearest the
  platform's scale:

  | Size | xSmall | small | medium | large | xLarge | xxLarge | xxxLarge | AX1 | AX2 | AX3 | AX4 | AX5 |
  |---|---|---|---|---|---|---|---|---|---|---|---|---|
  | Ratio | 0.82 | 0.88 | 0.94 | 1 | 1.12 | 1.24 | 1.35 | 1.65 | 1.94 | 2.35 | 2.76 | 3.12 |

  These are iOS's body sizes, 14 to 53 points, over 17.
- **Overrides:** an `environment` modifier sets those values for its
  subtree. Draw the colors, text, direction and split views below it with
  them, as far as the platform can.
- **`preferredColorScheme`** sets the window's scheme, or a sheet's for a
  node inside the sheet's content. Where several are set, the one nearest
  the root wins, then the first.

## Render IR

### Nodes

| Type | Props | Children | Events |
|---|---|---|---|
| `NavSplit` | `style` (`automatic`, `balanced`, `prominentDetail`), `visibility` (`automatic`, `all`, `doubleColumn`, `detailOnly`), `compactColumn` (`sidebar`, `content`, `detail`) | two or three `NavColumn`s, the sidebar first | `change` (string: the visibility the user chose), `pop` (int: columns left) |
| `NavColumn` | `column` (`sidebar`, `content`, `detail`); `title`; `minWidth`, `idealWidth`, `maxWidth` | the column's content, then its `ToolbarItem`s | — |
| `List` | adds `selection` (int: the picked row's `tag`; absent: none) | | `change` (int: the `tag` of the row the user picked; no value: none) |

### Modifiers

| Kind | Args | Inherited |
|---|---|---|
| `environment` | the keys of the table above that the subtree sets | yes |
| `preferredColorScheme` | `scheme` (`light`, `dark`); none: the system's | no: it's the window's, or the sheet's |
| `tag` | `value` (int): a row a list's `selection` can name | no |

### Events

| Kind | Value | Payload |
|---|---|---|
| `environment` | 7 | node ID 0: the window's values |

### Split views

- **Expanded:** show the columns side by side, as `visibility` says.
  `automatic` is the host's choice for the width. `doubleColumn` hides the
  sidebar of three. `detailOnly` shows the detail alone. When the user
  shows or hides a column, send `change` with the visibility they now
  see, and keep it until the guest's update arrives.
- **Collapsed** when the horizontal size class is compact, for the window
  or from an `environment` modifier above the node. Show the columns as a
  stack, up to `compactColumn`. When the user goes back, send `pop` with
  the number of columns left. Keep showing the stack as it was until the
  update, as for a `NavStack`.
- **A `NavStack` in a column**, collapsed, carries the stack on: its
  levels come after the column. Going back inside it is that stack's own
  `pop`.
- **`style`:** `balanced` narrows the detail so the sidebar fits beside
  it. `prominentDetail` keeps the detail's width and lays the sidebar
  over it. `automatic` is the host's choice.
- **Widths** are in points. Ones a platform can't set are left alone.

### Lists

A list with `selection` highlights the row whose `tag` it names, eager or
lazy, at any depth under the list (in a `Section`, say). A tag is the hash
of the row's value, so it follows the row's data as rows come and go. When
the user picks a row, send `change` with its tag, or with no value for
none, and highlight it until the guest's update arrives. Rows without a
tag, and section headers and footers, can't be picked.

## In the guest

- `RenderContext` carries `EnvironmentValues`. The root's are the host's,
  from `environment()` before the first update and from `environment`
  events after it, each of which schedules an update.
- `Environment<Value>` loses its `AnyObject` constraint. Its
  `init(_ type: Value.Type) where Value: AnyObject` keeps
  `@Environment(Model.self)` as it is.
- Setting a value from the host's table adds the inherited `environment`
  modifier to the nodes the subtree makes, as `foregroundColor` does now.
- `NavigationSplitView` keeps the compact column (or the app's binding)
  and, for each column, the link whose destination it shows. A `List` with
  a selection tells the column it's in, so going back can clear it.
- `ViewGraph` never makes node ID 0.
- Embedded Swift can't list a view's properties, so a value is found
  where it's read. While views render, that's the innermost body being
  evaluated, once per update, so a view kept across updates (the root, a
  link's destination) sees each update's values. In an event's handler,
  it's the view whose body made the handler: `dismiss()` in a button's
  action is the button's view's. In a task, it's what was found last.

## Per host

| | Values | Split view |
|---|---|---|
| iOS | the window's `UITraitCollection`, and `UIAccessibility`; the renderer is SwiftUI, so it can read SwiftUI's own environment in `RendererView` and report each change | SwiftUI's `NavigationSplitView` (iOS 16), with `preferredCompactColumn` from iOS 17. On iOS 15, `NavigationView` with the columns style |
| macOS | no size classes: from the window's size; `NSApp.effectiveAppearance`; `NSWorkspace`'s accessibility settings; text size always `large`; `backingScaleFactor` | `NavigationSplitView` (macOS 13), `NavigationView` before |
| Android | `Configuration`: `screenWidthDp`, `screenHeightDp`, `uiMode`, `fontScale`, layout direction, density; `UiModeManager.getContrast()` (API 34); `fontWeightAdjustment` (API 31); the animator duration scale for reduced motion | Material 3's adaptive `ListDetailPaneScaffold`, its extra pane for the third column |
| Linux | the window's size; `AdwStyleManager`'s dark and high contrast; GNOME's `text-scaling-factor` and `enable-animations`; GTK's text direction; the surface's scale | `AdwNavigationSplitView`, one inside another for three columns |
| Browser | the viewport's size; `matchMedia` for `prefers-color-scheme`, `prefers-contrast`, `prefers-reduced-motion`, `prefers-reduced-transparency`; `devicePixelRatio`; the document's `dir`; the root font size over 16 pixels | CSS grid columns, a stack below 600 pixels |

## Not in this design

- **`locale`, `timeZone` and `calendar`** wait for Foundation in a guest,
  which is on branches (`Contracts/Formatting.md`).
- **The size of a node** (`GeometryReader`, `ViewThatFits`). A report on
  every resize is a crossing per frame. Size classes are coarse and
  rarely change. A design of its own.
- **Value-based navigation:** `NavigationLink(value:)`,
  `navigationDestination(for:)` and a path.
- **Choosing several rows**, `Set` selection and `editMode`.
- `openURL`, `scenePhase`, and an `@Entry` macro for an app's own keys.
- Sheet detents, and keyboard shortcuts and menu commands at desktop
  width, from the same table in `PlannedApps.md`.

## Alternatives weighed

- **Key paths:** refused by Embedded Swift 6.4.
- **A key type for each value**, `@Environment(ColorSchemeKey.self)`:
  further from SwiftUI, and longer.
- **A string,** `@Environment("colorScheme")`: no type.
- **A new `RendererDelegate` method** for a change: an older guest wouldn't
  have it, and every host would check before calling. An event kind is
  already add-only.
- **Events only, with no `environment()`:** the first tree would be laid
  out with the defaults and redrawn at once. On a tablet, the phone's
  layout would flash.
- **The guest collapsing the split view** from the size class: it would
  rebuild each platform's gestures and buttons, and get them wrong. A
  guest that wants its own layout can still read the size class.

## Example and tests

`examples/ExampleNotes`: folders, notes and a note in three columns. It
reads the size class for its toolbar, the text size for its rows, and
`dismiss` in a sheet that adds a note. It runs on WasmKit, as a sealed
macOS slice and through wasm2c, with the test renderer reporting compact
and then regular, and going back.

- **Frontend:** values reach views; a change re-evaluates; overrides become
  `environment` modifiers; an app's own key; `dismiss` in a sheet, a level
  and a column; a split view collapsed and expanded, picking, going back
  and the selection cleared, a link in a column, a stack in a column; the
  stack on an older host; `List(selection:)` on an eager and a lazy list;
  no node ID 0.
- **`DynamicUI`:** `RenderEnvironment` encodes and decodes every key, keeps
  a missing key at its default and skips an unknown one.
- The test renderers (`TestRenderer`, `WasmTestRenderer`) gain
  `environment()` and a way to send the event.

## Changed while building

- **A list's selection is a row's tag, not its node ID.** The guest can't
  know a lazy row's node ID until the host has asked for the row, so it
  couldn't say which row is picked before then. Each row a selection can
  name has a `tag` modifier with the hash of its value, and `selection`
  and `change` carry that. Darwin's renderer can hand it straight to
  SwiftUI's `tag(_:)`.
- **None is no value**, not 0: a hash can be 0.
- **No bytes from `environment()` is a renderer from before version 2.**
  The method has a default in a protocol extension, so hosts that conform
  to `Renderer` themselves keep building; that default answers no bytes.
  A renderer with nothing to report answers an empty array, which is
  still version 2.
- **An `environment` event whose payload doesn't decode is ignored,**
  rather than taken as no values.
- **A subtree's setting goes into the IR whenever it differs from what
  the host reported,** including when the host didn't report that key:
  the host may draw it otherwise.
- **Halfway between two text sizes, the one nearer `large` wins,** so
  Android's 0.85 is `small`.
- **Values are found where they're read** (In the guest, above). The
  design said a value is read when the view is made; that would miss a
  window's change for the root view, and give `dismiss()` in an action
  the do-nothing default.

## Decided in review

1. `@Environment(.colorScheme)`, with `\.` changed to `.`, is the
   spelling.
2. On a host without version 2, a split view is drawn as a stack.
3. Material's breakpoints, 600 and 480 points, give the size classes
   where a platform has none of its own.

## What hosts still need

- **Darwin** (SwiftUI): answer `environment()` from SwiftUI's own
  environment in `RendererView`, and send `environment` on each change;
  apply the `environment` modifier with SwiftUI's own values; draw
  `NavSplit` as `NavigationSplitView` (iOS 16, macOS 13) with
  `preferredCompactColumn` from iOS 17, and `NavigationView` before; map
  a list's `selection` and its rows' `tag`s to `List(selection:)` and
  `tag(_:)`; `preferredColorScheme` on the window or sheet.
- **Android:** `Configuration` and the accessibility settings into the
  payload; `ListDetailPaneScaffold` for `NavSplit`; list selection in the
  Compose interpreter.
- **Linux:** the window's size and libadwaita's settings into the
  payload; `AdwNavigationSplitView`.
- Each renderer's `environment()` is the sign that it draws `NavSplit`,
  so a host implements both together.


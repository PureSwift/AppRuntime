# Render IR

The tree a guest's SwiftUI frontend sends a host's renderer (design §9.2,
§9.3). This page is for player authors: what each node and modifier means,
which events a host reports, and the byte format. The guest side is
`DynamicSwiftUI`; the types and codec are `DynamicUI` (`RenderNode`,
`ModifierNode`, `PropValue`, `RenderCodec`).

## Nodes

A node has a **type**, a 64-bit **ID**, **props**, an ordered list of
**modifiers**, **children**, and, for a lazy container, a row **count**.

- **IDs are structural identity.** They're stable while a view keeps its place
  in the tree, so key native views (and their transient state: scroll
  position, focus, a text field's selection) to them. A new ID is a new view.
- **The vocabulary is add-only.** Render a type you don't know as an empty
  placeholder; ignore a modifier kind or prop you don't know.
- **Defaults are explicit.** Stack spacing (8) and padding (16) are always in
  the IR, so layout stays close across hosts.

## Node types

| Type | Props | Children | Events |
|---|---|---|---|
| `Text` | `text` | — | — |
| `Image` | `systemName` or `name`; `resizable` | — | — |
| `Label` | `title`, `systemImage` | — | — |
| `Spacer` | `minLength` | — | — |
| `Divider` | — | — | — |
| `Color` | `color` | — | — |
| `Shape` | `shape` (`rectangle`, `roundedRectangle`, `circle`, `ellipse`, `capsule`); `cornerRadius`; `fill` (color), or `stroke` (color) and `lineWidth`; neither: filled with the foreground color | — | — |
| `GLSurface` | `surface` (int: a `Surface`'s `identifier()`) | — | none here: frames and input go to the surface's delegate (§8.2) |
| `WebView` | `page` (int: a `WebContent`'s `identifier()`) | — | none here: the page reports through its contract (`Contracts/WebKit.md`) |
| `VideoPlayer` | `player` (int: a `MediaPlayback`'s `identifier()`), `scaling` (`fit`, `fill`, `stretch`), `controls` (`platform`, `none`) | — | none here: the player reports through its contract (`Contracts/MediaPlayer.md`) |
| `TextEditor` | `buffer` (int: a `TextStorage`'s `identifier()`), `editable` (bool), `wraps` (bool) | — | none here: the text reports through its contract (`Contracts/TextEditor.md`) |
| `Photo` | `asset` (string: an asset's identifier in the photo library), `scaling` (`fill`, `fit`) | — | — (`Contracts/Photos.md`) |
| `CameraPreview` | `camera` (int: a `CameraCapture`'s `identifier()`), `scaling` (`fill`, `fit`) | — | none here: the camera reports through its contract (`Contracts/Camera.md`) |
| `VStack` | `alignment` (`leading`, `center`, `trailing`), `spacing` | content | — |
| `HStack` | `alignment` (`top`, `center`, `bottom`), `spacing` | content | — |
| `ZStack` | `horizontal`, `vertical` (alignment) | content, back to front | — |
| `ScrollView` | `axes` (`vertical`, `horizontal`, `both`), `showsIndicators` | content | — |
| `Button` | `role` (`destructive`, `cancel`) | label | `tap` |
| `Toggle` | `isOn` | label | `change` (bool) |
| `TextField` | `text`, `placeholder`; `secure` | — | `change` (string), `submit` |
| `Slider` | `value`, `min`, `max`; `step` | — | `change` (double) |
| `Stepper` | `value`, `min`, `max`, `step` (ints) | label | `change` (int) |
| `ProgressView` | `total`; `value` (none: indeterminate); `title` | — | — |
| `DatePicker` | `title`, `value` (seconds since 1970, UTC), `components` (`date`, `hourAndMinute`, or both comma-separated); `min`, `max` | — | `change` (double) |
| `Picker` | `title`; `selection` (index); `style` (`menu`, `segmented`, `inline`, `wheel`) | options | `change` (int: index) |
| `List` | `revision` when lazy; `selection` (int: the tag of the picked row) | rows when eager | `change` (int: the tag of the row the user picks; no value: none) |
| `Section` | `header`, `footer` | rows | — |
| `Form` | — | rows and sections | — |
| `SwipeActions` | `edge` (`leading`, `trailing`), `allowsFullSwipe` | the row, then its `Button` actions | — |
| `DisclosureGroup` | `isExpanded` | the label, then the content while expanded | `change` (bool) |
| `LazyVStack`, `LazyHStack` | `alignment`, `spacing`; `revision` when lazy | content when eager | — |
| `LazyVGrid` | `columns` (grid items), `alignment`, `spacing`; `revision` when lazy | items when eager | — |
| `LazyHGrid` | `rows` (grid items), `alignment`, `spacing`; `revision` when lazy | items when eager | — |
| `Grid` | `horizontal`, `vertical` (alignment), `horizontalSpacing`, `verticalSpacing` | `GridRow`s, and views that span the grid | — |
| `GridRow` | `alignment` (vertical) | its cells | — |
| `NavStack` | — | one `NavLevel` per level, root first | `pop` (int) |
| `NavLevel` | `title` | the level's content, then its `ToolbarItem`s | — |
| `NavSplit` | `style` (`automatic`, `balanced`, `prominentDetail`), `visibility` (`automatic`, `all`, `doubleColumn`, `detailOnly`), `compactColumn` (`sidebar`, `content`, `detail`) | two or three `NavColumn`s, the sidebar first | `change` (string: the visibility the user chose), `pop` (int: columns left) |
| `NavColumn` | `column` (`sidebar`, `content`, `detail`); `title`; `minWidth`, `idealWidth`, `maxWidth` | the column's content, then its `ToolbarItem`s | — |
| `ToolbarItem` | `placement` (`automatic`, `primaryAction`, `cancellationAction`, `confirmationAction`, `navigation`, `principal`, `bottomBar`) | the item's views | — |
| `NavigationLink` | — | label | `tap` |
| `Link` | `url` | label; the host opens the URL | — |
| `Searchable` | `text`; `prompt` | the view with the search field | `change` (string), `submit` |
| `TabView` | `selection` (index) | one `Tab` per tab | `change` (int: index) |
| `Tab` | `title`, `systemImage` | the tab's content | — |
| `Sheet` | `isPresented`, `style` (`sheet`, `fullScreenCover`) | the presenting view, then the content while presented | `change` (bool: `false`) |
| `Alert` | `title`, `isPresented`; `message`; `style` (`dialog`) and `titleVisibility` (`automatic`, `visible`, `hidden`) | the presenting view, then `Button` actions while presented | `change` (bool: `false`) |
| `Menu` | `title`, `systemImage` | its items: buttons, dividers, sections, menus | — |
| `ContextMenu` | — | the view, then the menu's items | — |
| `Refreshable` | `refreshing` | the list or scroll view | `refresh` |

Optional props are absent when unset. Colors are a platform color name
(`primary`, `secondary`, `accentColor`, `clear`, `black`, `white`, `gray`,
`red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`,
`purple`, `pink`, `brown`), which should follow light and dark appearance;
`[name, opacity]`; or a fixed `0xAARRGGBB` int.

A grid item is `[size, a, b, spacing, horizontal, vertical]`: `size` is
`fixed` (`a` and `b` are its length), `flexible` or `adaptive` (`a` and `b`
are the minimum and maximum, which may be ∞), then the spacing after it and
its alignment. All six are always present.

## Modifiers

Applied in order: `.padding().background(.red)` pads, then fills the padded
area. **Inherited** modifiers apply to every descendant that doesn't set its
own, like SwiftUI's environment.

| Kind | Args | Inherited |
|---|---|---|
| `padding` | `top`, `leading`, `bottom`, `trailing` | no |
| `frame` | `width`, `height`, `minWidth`, `idealWidth`, `maxWidth`, `minHeight`, `idealHeight`, `maxHeight` (∞ fills the space offered), `horizontal`, `vertical` (alignment) | no |
| `offset` | `x`, `y` | no |
| `background` | `color` | no |
| `foregroundColor` | `color`; none resets | yes |
| `tint` | `color` | yes |
| `opacity` | `value` | no |
| `cornerRadius` | `radius` | no |
| `border` | `color`, `width` | no |
| `shadow` | `color`, `radius`, `x`, `y` | no |
| `font` | `style` (`largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2`), or `size`, `weight`, `design`; `italic` | yes |
| `fontWeight` | `weight` (`ultraLight` … `black`) | yes |
| `italic` | `value` | yes |
| `lineLimit` | `lines`; none: unlimited | yes |
| `multilineTextAlignment` | `alignment` | yes |
| `textSelection` | `enabled` (bool) | yes |
| `disabled` | `value` | yes |
| `autocorrection` | `disabled` (bool) | yes |
| `autocapitalization` | `mode` (`never`, `words`, `sentences`, `characters`); none: the platform's way | yes |
| `focused` | `value` (bool); report `focus` | no |
| `environment` | the window's values the subtree sets (see [The window](#the-window)) | yes |
| `preferredColorScheme` | `scheme` (`light`, `dark`); none: the system's | no: it's the window's, or the sheet's it's in |
| `tag` | `value` (int): a list row the list's `selection` can name | no |
| `onTapGesture` | `count`; report `tap` | no |
| `accessibilityLabel` | `text` | no |
| `accessibilityIdentifier` | `identifier` | no |

`onAppear`, `onDisappear` and `task` are handled in the guest and never
appear in the IR. Nor do `tag`, `tabItem` and `pickerStyle`: they become
props of the `Picker`, `TabView` and `Tab` nodes.

## Events

`RendererDelegate.event(node, kind, payload)`: `node` is the 8-byte node ID,
`kind` a `RenderEventKind`, `payload` one encoded value or empty.

| Kind | Value | Payload |
|---|---|---|
| `tap` | 1 | — |
| `change` | 2 | the control's new value |
| `submit` | 3 | — |
| `pop` | 4 | `NavStack`: the number of levels left (int) |
| `refresh` | 5 | — |
| `focus` | 6 | whether the view now has the keyboard (bool) |
| `environment` | 7 | node ID 0, the window: its values (see [The window](#the-window)) |

**Control sync.** The guest's state is the source of truth, and its answer
to an event arrives as an update before the event call returns. Set a control
from the IR only when the value differs from what you last rendered, so
typing, dragging or a toggle in progress isn't overwritten.

## Text input

`autocorrection` and `autocapitalization` are for the on-screen keyboard
of the `TextField`, `TextEditor` and `Searchable` nodes they reach. A host
without one ignores them.

`textSelection` is for `Text` and `Label` nodes: where it's enabled, let
the user select the text and copy it with the platform's own menu and
shortcuts. Nothing is reported. A host that can't shows the text as it
would have.

A `focused` modifier is on a `TextField` or a `TextEditor`, and ties its
keyboard focus to the guest's state.

- When the user moves the keyboard into or out of the view, send `focus`.
- Sync it like a control: give or take the keyboard only when `value`
  differs from what was last rendered or reported. A node that appears
  with `value` true gets the keyboard then.
- At most one view has it. Giving it to one takes it from another, and
  that one reports `focus` false.

A `TextEditor` shows the host's text its `buffer` names. Put the text's
view there; when the node goes, take the view out and keep the text.
Input inside the node belongs to that view.

## Photos and the camera

A `Photo` shows an asset of the user's photo library. Draw it in the
node's bounds from the platform's own thumbnails, at the node's size in
pixels or the next size up: a smaller copy first if there's one to hand,
and a better one when it arrives. `fill` crops to the bounds and `fit`
shows all of it. A video is its first frame. An asset the app may not
see, or one that's gone, draws nothing. No pixel goes to the guest, and
the node has no events of its own: a tap on it is an `onTapGesture`.

A `CameraPreview` shows what the camera its `camera` names sees
(`HostCameraCapture.camera(for:)` in a host written in Swift). Mirror the
front camera's picture. A tap inside the node focuses and sets the
exposure there, and a pinch zooms, which the host reports to the guest
through the camera's contract; neither is a render event. Show nothing
while the camera is off. When the node goes the camera stays on.

## Selection

A `Picker`'s children are its options, and a `TabView`'s are its tabs.
`selection` is the index of the chosen one; it's absent when none matches the
guest's value, so show nothing selected. When the user chooses, send
`change` with the index, and show it until the guest's update arrives.
Unknown styles fall back to the platform's default picker.

## Presentations

A `Sheet` or `Alert` node stands in for the view it's attached to, its first
child: lay that out as if the node weren't there. While `isPresented` is
true, present the rest of the children: a sheet's content, or an alert's
actions, which are `Button` nodes (an alert without actions gets an OK
button). Whenever the presentation goes away other than by the guest's
update (a swipe, the Escape key, an alert's button), send `change` with
`false`. A host without full-screen covers shows a sheet.

An `Alert` with `style` `dialog` is a confirmation dialog: an action sheet on
iOS. Show it as an alert if you have no dialogs.

## Refreshing

When the user pulls a `Refreshable` node's list, send `refresh`, then keep
the refresh indicator up while `refreshing` is true. The guest's update
arrives before the event call returns; if its action finished without
waiting, `refreshing` is already false.

## Search

A `Searchable` node puts a search field in the navigation bar of the level
it's in, and lays out its child as if the node weren't there. Sync its
`text` like a text field's.

## Toolbars

A `NavLevel`'s `ToolbarItem` children come after its content. Show them in
the level's toolbar at their `placement`, and not in its content; put an
item whose placement you don't have where `automatic` items go.

## Lazy containers

A node with a `count` is lazy: it has no children, and you ask for the rows
you show with `RendererDelegate.rowCount(list)` and `row(list, index)`, which
returns an encoded tree. Row IDs follow the row's data, so they stay stable
as rows are inserted and removed. `revision` changes whenever the guest
updates; then re-fetch the rows on screen.

## Navigation

A `NavStack`'s children are its levels; show the last. When the user goes
back (a back button, a swipe, the system back gesture), report `pop` with the
number of levels left and keep showing the stack as it was until the guest's
update arrives.

## Split views

A `NavSplit` and its `NavColumn`s are version 2 of the `Renderer`
contract: a renderer that answers `environment()` draws them.

- **Expanded:** show the columns side by side, as `visibility` says.
  `automatic` is your choice for the width; `doubleColumn` hides the
  sidebar of three; `detailOnly` shows the detail alone. When the user
  shows or hides a column, send `change` with the visibility they now see,
  and keep it until the guest's update arrives.
- **Collapsed** when the horizontal size class is compact, for the window
  or from an `environment` modifier above the node: show the columns as a
  stack, up to `compactColumn`. When the user goes back, send `pop` with
  the number of columns left, and keep showing the stack as it was until
  the update, as for a `NavStack`.
- **A `NavStack` in a column**, collapsed, carries the stack on: its
  levels come after the column. Going back inside it is that stack's own
  `pop`.
- **`style`:** `balanced` narrows the detail so the sidebar fits beside
  it; `prominentDetail` keeps the detail's width and lays the sidebar over
  it; `automatic` is your choice. Widths are in points; leave alone the
  ones the platform can't set.

## Lists

A `List` with `selection` lets the user pick one row at a time: the rows
with a `tag` modifier, eager or lazy, at any depth under the list (in a
`Section`, say). Highlight the row whose `tag` is `selection`. When the
user picks a row, send `change` with its tag, or with no value for none,
and highlight it until the guest's update arrives. A row's tag follows its
data, so the selection stays on its row as rows come and go.

## The window

`Renderer.environment()` answers with the window's values, before the
guest's first tree; afterwards each change is an `environment` event to
node ID 0, which no node has. The payload is one array: a key, then its
value, then the next. Send every value you know; a key you leave out takes
its default. `RenderEnvironment` in `DynamicUI` encodes and decodes it.

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

- One event for each change, carrying every value; values that change
  together, such as both size classes in a rotation, are one event. Not
  during a resize unless a size class changes.
- Size classes are the platform's own where it has them. Elsewhere,
  horizontally compact below 600 points wide, vertically below 480 high.
- The text size is the one whose ratio to `large` is nearest the
  platform's scale (`RenderEnvironment.TypeSize(scale:)`).
- An `environment` modifier sets those values for its subtree: draw its
  colors, text, direction and split views with them, as far as you can.
- `preferredColorScheme` sets the window's scheme, or a sheet's for a node
  in the sheet's content. Where several are set, the one nearest the root
  wins, then the first.

`Documentation/Environment.md` has the design, and where each platform
finds these values.

## Updates

`Renderer.apply(tree)` replaces everything. `replaceSubtree(id, tree)`
replaces the node `id` and its subtree; update the native views for it in
place, keeping those whose IDs survive.

## Byte format

Version 1, little-endian. Every string is stored once, in a table; props are
sorted by key, so equal trees encode to equal bytes.

```text
tree      := 0x52 0x4E ("RN"), version u8 = 1, strings, node
strings   := varint count, (varint length, UTF-8 bytes)*
node      := varint type, u64 id, props, modifiers, children, varint lazy
props     := varint count, (varint key, value)*
value     := u8 tag, then
               0 string: varint string index
               1 double: f64
               2 bool:   u8 0 or 1
               3 int:    zigzag varint
               4 array:  varint count, value*
modifiers := varint count, (varint kind, props)*
children  := varint count, node*
lazy      := 0 for an eager node, rows + 1 for a lazy container
payload   := strings, value
node ID   := u64
```

A decoder rejects other magic bytes, versions it doesn't know, truncated
input, trailing bytes, out-of-range string indices and nesting deeper than
512 levels.

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
| `Picker` | `title`; `selection` (index); `style` (`menu`, `segmented`, `inline`, `wheel`) | options | `change` (int: index) |
| `List` | `revision` when lazy | rows when eager | — |
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
| `ToolbarItem` | `placement` (`automatic`, `primaryAction`, `cancellationAction`, `confirmationAction`, `navigation`, `principal`, `bottomBar`) | the item's views | — |
| `NavigationLink` | — | label | `tap` |
| `Link` | `url` | label; the host opens the URL | — |
| `Searchable` | `text`; `prompt` | the view with the search field | `change` (string), `submit` |
| `TabView` | `selection` (index) | one `Tab` per tab | `change` (int: index) |
| `Tab` | `title`, `systemImage` | the tab's content | — |
| `Sheet` | `isPresented`, `style` (`sheet`, `fullScreenCover`) | the presenting view, then the content while presented | `change` (bool: `false`) |
| `Alert` | `title`, `isPresented`; `message`; `style` (`dialog`) and `titleVisibility` (`automatic`, `visible`, `hidden`) | the presenting view, then `Button` actions while presented | `change` (bool: `false`) |
| `Menu` | `title`, `systemImage` | its items: buttons, dividers, sections, menus | — |

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
| `disabled` | `value` | yes |
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

**Control sync.** The guest's state is the source of truth, and its answer
to an event arrives as an update before the event call returns. Set a control
from the IR only when the value differs from what you last rendered, so
typing, dragging or a toggle in progress isn't overwritten.

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

# Gestures, keyboard shortcuts, menu commands and sheet detents

**Status:** a draft, not reviewed. Nothing in this document is built.

What the plan's list of SwiftUI additions still lacks (`PlannedApps.md`,
"The SwiftUI frontend and the render IR"), after environment values,
split views, text editing, images and the zooming scroll view:

| Missing | Needed by |
|---|---|
| Drag and long-press gestures | Image viewer, Maps, Browser; any list the user reorders |
| Keyboard shortcuts | Text editor, Browser, every app on a desktop |
| Menu commands | Text editor, Browser, every app on a desktop |
| Sheet detents | Every app on a phone |

None is a contract. Each is render IR, a modifier or a node, and the
frontend's API for it, which is SwiftUI's.

| | iOS | macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| Drag, long press | `UIPanGestureRecognizer`, `UILongPressGestureRecognizer` | `NSPanGestureRecognizer`, `NSPressGestureRecognizer` | `GestureDetector`, `onLongPress` | GTK's `GtkGestureDrag`, `GtkGestureLongPress` | pointer events |
| Shortcuts | `UIKeyCommand` | the menu item's key equivalent, or `NSEvent` | `View.onKeyShortcut`, `KeyEvent` | `GtkShortcutController` | `keydown` |
| Menu commands | `UIMenuBuilder` (iPad, Mac Catalyst) | `NSApp.mainMenu` | none: the shortcuts stay | `GMenu` in the header bar's menu | none: the shortcuts stay |
| Detents | `UISheetPresentationController.detents` | none: a sheet is its size | `BottomSheetDialog`'s peek and expanded states | `AdwBottomSheet` | none: a dialog |

These names are from what's known of each platform, and haven't been
checked against its documentation yet.

## What shapes it

- **A gesture's events cross, and a gesture's work stays in the host
  where it can.** Pinch to zoom is the scroll view's, in the host, so it
  doesn't lag the fingers. A drag is the app's to answer: a slider of its
  own, a card it moves, a row it reorders. So the host sends a drag's
  movement, no more than once a frame, and the guest's update comes back
  before the next. What follows the finger exactly, such as a scroll, is
  still the host's.
- **The host arbitrates gestures as its platform does.** A tap, a long
  press and a drag on the same view, or a drag inside a scroll view, are
  told apart by the platform's own rules: how far a drag must go, how
  long a press must last. The guest names the thresholds; it doesn't
  decide between them.
- **A shortcut is a button's,** as in SwiftUI: pressing it is the button's
  `tap`. No key event crosses. A text field keeps the keys it uses.
- **Commands are buttons in menus,** the same `Button`, `Divider` and
  `Menu` a `Menu` node has, in a node of their own the host shows where
  its platform keeps an app's menus. A host with no menu bar keeps their
  shortcuts.
- **Detents are the sheet content's,** as in SwiftUI: set inside the
  sheet, sent on its node, and reported back when the user drags the
  sheet to another.

## For a guest

```swift
struct Card: View {

    @State private var offset = Size.zero

    @GestureState private var pressing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(pressing ? .gray : .blue)
            .offset(x: offset.width, y: offset.height)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in offset = value.translation }
                    .onEnded { value in offset = value.predictedEndTranslation }
            )
            .onLongPressGesture(minimumDuration: 0.5) {
                showDetails()
            } onPressingChanged: { isPressing in
                pressing = isPressing
            }
    }
}

// Shortcuts: on the button, or on a view, for the buttons in it.
Button("Save") { save() }
    .keyboardShortcut("s")                       // ⌘S, Ctrl+S
Button("Find Next") { findNext() }
    .keyboardShortcut("g", modifiers: [.command])
Button("Done") { dismiss() }
    .keyboardShortcut(.defaultAction)            // Return

// Commands: the app's menus.
WindowGroup {
    ContentView()
}
.commands {
    CommandGroup(after: .newItem) {
        Button("New Tab") { browser.newTab() }
            .keyboardShortcut("t")
    }
    CommandMenu("History") {
        Button("Back") { browser.back() }
            .keyboardShortcut("[")
        Divider()
        Button("Clear History…") { browser.clear() }
    }
}

// Detents: inside the sheet.
.sheet(isPresented: $showingPlaces) {
    PlaceList()
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
}
```

### Gestures

- **`DragGesture(minimumDistance:coordinateSpace:)`** with `onChanged`
  and `onEnded`. Its `Value` has `startLocation`, `location`,
  `translation`, `predictedEndLocation` and `predictedEndTranslation`, in
  points, in the view's own space (`.local`, the default) or the window's
  (`.global`). `onChanged` comes at most once a frame; `onEnded` comes
  once, and a drag the system takes away ends without it, resetting
  `@GestureState`.
- **`LongPressGesture(minimumDuration:maximumDistance:)`** with `onEnded`,
  and `onLongPressGesture(minimumDuration:maximumDistance:perform:
  onPressingChanged:)`, SwiftUI's view modifier.
- **`TapGesture(count:)`** is the same as `onTapGesture(count:)`, which
  exists.
- **`.gesture(_:)`** attaches one. **`@GestureState`** is a value a
  gesture's `updating(_:body:)` sets while it lasts, and that goes back
  to its first value when it ends, however it ends.
- **Not in this version:** `simultaneousGesture`, `highPriorityGesture`,
  and combining gestures (`sequenced`, `simultaneously`, `exclusively`);
  `MagnifyGesture` and `RotateGesture`, which are the host's
  (`zoomable`); a drag's velocity, beyond its predicted end.

### Keyboard shortcuts

- **`keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers =
  .command)`**, on a `Button`, or on a view for every button in it that
  has none of its own. `KeyEquivalent` is a character, or `.return`,
  `.escape`, `.delete`, `.deleteForward`, `.tab`, `.space`, the arrows,
  `.home`, `.end`, `.pageUp`, `.pageDown`. `EventModifiers` is
  `.command`, `.shift`, `.option` and `.control`.
- **`.command` is the platform's command key:** ⌘ on Apple platforms,
  Ctrl elsewhere. `.control` is Ctrl everywhere, and on Apple platforms
  ⌃.
- **`KeyboardShortcut.defaultAction`** is Return, and
  **`.cancelAction`** Escape, with no modifiers; a host may draw the
  default button as such.
- **A disabled button's shortcut does nothing,** and a button that isn't
  on screen has none, except in commands.
- **Not in this version:** key events themselves (`onKeyPress`), and
  shortcuts for a view other than a button.

### Menu commands

- **`commands { … }`** on a `WindowGroup` gives the app's menus.
- **`CommandMenu(_ title:)`** adds a menu of the app's own, after the
  standard ones and before Window and Help.
- **`CommandGroup(before:after:replacing:)`** puts buttons in a standard
  menu by a placement: `.appInfo`, `.appSettings`, `.newItem`,
  `.saveItem`, `.importExport`, `.printItem`, `.undoRedo`, `.pasteboard`,
  `.textEditing`, `.toolbar`, `.sidebar`, `.help`. `replacing:` takes
  the platform's items out, as SwiftUI's does.
- **Their buttons are buttons:** a title, an action, a shortcut, a role,
  `disabled`. They're evaluated with the app's body, and observe what
  they read, so a command's title and state follow the app.
- **On a host with no menu bar** the commands' shortcuts still work, and
  the buttons aren't shown.

### Sheet detents

- **`presentationDetents(_:)`** and **`presentationDetents(_:selection:)`**
  in a sheet's content: `.medium`, `.large`, `.fraction(_:)` (of the
  screen's height) and `.height(_:)` (points). The sheet starts at the
  first, or at `selection`'s; the user drags between them, and the
  binding follows.
- **`presentationDragIndicator(.automatic | .visible | .hidden)`.**
- **`interactiveDismissDisabled(_:)`:** the user can't swipe the sheet
  away; the app closes it.
- **Where a host has no detents,** the sheet is its platform's size and
  the binding stays where it was set. A full-screen cover has none.

## The render IR

### Modifiers

| Modifier | Args | Reaches descendants |
|---|---|---|
| `dragGesture` | `minimumDistance`, `coordinateSpace` (`local`, `global`); report `drag` | no |
| `longPressGesture` | `minimumDuration`, `maximumDistance`; `pressing` (bool: report `pressing`); report `longPress` | no |
| `keyboardShortcut` | `key` (a character, or `return`, `escape`, `delete`, `deleteForward`, `tab`, `space`, `upArrow`, `downArrow`, `leftArrow`, `rightArrow`, `home`, `end`, `pageUp`, `pageDown`), `modifiers` (array of `command`, `shift`, `option`, `control`) | yes: to buttons without one |
| `presentationDetents` | `detents` (array: `medium`, `large`, `fraction:0.3`, `height:200`), `selection` (index) | no: it's the sheet's |
| `presentationDragIndicator` | `visibility` (`automatic`, `visible`, `hidden`) | no: it's the sheet's |
| `interactiveDismissDisabled` | `value` | no: it's the sheet's |

`presentationDetents` and the two after it are found on the root of a
`Sheet` node's content: the sheet reads them from there.

### Nodes

| Node | Props | Children | Events |
|---|---|---|---|
| `Commands` | — | the app's content, then `CommandMenu` and `CommandGroup` nodes | — |
| `CommandMenu` | `title` | buttons, dividers, sections, menus | — |
| `CommandGroup` | `placement` (`appInfo` … `help`), `position` (`before`, `after`, `replacing`) | buttons, dividers, sections, menus | — |

A `Commands` node is the root, around the window's content, when the app
gives commands; otherwise the root is the content, as now. A host that
doesn't know it shows its first child.

### Events

| Kind | Value | Payload |
|---|---|---|
| `longPress` | 9 | none, for `longPressGesture` (a `Map`'s keeps its own) |
| `drag` | 10 | `[phase, startX, startY, x, y, predictedEndX, predictedEndY]`: `phase` 0 changed, 1 ended, 2 cancelled |
| `pressing` | 11 | bool: a long press began touching, or stopped |
| `detent` | 12 | int: the index of the detent the user dragged the sheet to, sent to the `Sheet` node |

## For a host

- **Drags:** start after `minimumDistance`; send `drag` changed at most
  once a frame, and end with ended, or cancelled when the platform takes
  the gesture (a scroll, a system gesture). Positions are in points, in
  the node's space or the window's. The predicted end is the platform's,
  or the position with no prediction.
- **Long presses:** `longPress` once the duration has passed without
  moving further than `maximumDistance`; `pressing` true when a touch
  begins and false when it ends, if `pressing` is set.
- **Arbitration** is the platform's: a long press that fires takes the
  touch from a tap; a drag that starts takes it from both; a drag inside
  a scroll view goes to whichever the platform gives it.
- **Shortcuts** fire the button's `tap`, unless it's disabled or the key
  goes to a focused text field that uses it. The first button on screen
  with a shortcut wins over later ones; commands' come first.
- **Commands** go in the platform's menus, built again when the node
  changes. Selecting one sends its button's `tap`.
- **Detents:** apply them when the sheet is presented and when they
  change, move to `selection` when it differs from what was last
  rendered, and send `detent` when the user drags the sheet to another.

## Tests and an example

- **`DynamicSwiftUITests`:** each modifier's args; a drag's values in
  both spaces, its phases, and `@GestureState` reset when it ends or is
  cancelled; a long press and `pressing`; a shortcut on a button and on a
  view for its buttons, and a disabled one; `Commands` around the content,
  with its menus and groups, and a command's button tapped; detents and
  their selection both ways.
- **`ExampleUI`** gains a card the user drags and long-presses, shortcuts
  on its buttons, an app menu with a command, and detents on its sheet.
  On the three engines, against a test renderer that sends the events.

## Not in this design

- Combined and simultaneous gestures; magnify and rotate gestures in the
  guest.
- Key events (`onKeyPress`) and hover (`onHover`).
- Drag and drop between views or apps (`draggable`, `dropDestination`).
- Several windows, and commands per window.
- Popovers, and sheets sized by their content.

## Questions

1. **A drag crosses once a frame.** That's enough for a slider, a card
   or a reorder, and a lag of a frame against the finger. Should the
   host move the view itself while a drag lasts, as it zooms, with the
   guest told only where it ended?
2. **Commands at the root.** A `Commands` node wraps the content, so a
   host that doesn't know it shows its first child. The other way is a
   second tree, which needs a new `Renderer` method. Is wrapping enough?
3. **`.command` as Ctrl** off Apple's platforms, as Mac Catalyst and
   most cross-platform toolkits map it. Or should a shortcut name the
   platform's modifier only where the app asks?

import Testing
@testable import DynamicSwiftUI
import DynamicUI

/// Plain, not `@Observable`: the tests update the graph themselves.
final class Pad {
    var drags: [String] = []
    var presses: [String] = []
    var pressingNow: [Bool] = []
    var taps = 0
    var saves = 0
    var title = "New Tab"
    var showingSheet = true
    var detent = PresentationDetent.medium
}

struct Pane: View {

    let pad: Pad

    @GestureState var dragging = false

    @GestureState var holding = false

    var body: some View {
        VStack {
            Text(dragging ? "dragging" : "still")
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged { pad.drags.append("changed \($0.translation.width) \($0.translation.height)") }
                        .onEnded { pad.drags.append("ended \($0.predictedEndTranslation.width)") }
                )
            Text(holding ? "holding" : "free")
                .gesture(
                    LongPressGesture(minimumDuration: 1)
                        .updating($holding) { pressing, state, _ in state = pressing }
                        .onEnded { _ in pad.presses.append("gesture") }
                )
            Text("press")
                .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 20) {
                    pad.presses.append("modifier")
                } onPressingChanged: { pad.pressingNow.append($0) }
            Text("tap")
                .gesture(TapGesture(count: 2).onEnded { pad.taps += 1 })
            Button("Save") { pad.saves += 1 }
                .keyboardShortcut("s")
            Button("Done") { }
                .keyboardShortcut(.defaultAction)
            VStack {
                Button("A") { }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift, .option, .control])
            Button("Plain") { }
                .keyboardShortcut(nil)
        }
    }
}

struct SheetHost: View {

    let pad: Pad

    var body: some View {
        Text("under")
            .sheet(isPresented: Binding(get: { pad.showingSheet }, set: { pad.showingSheet = $0 })) {
                Text("places")
                    .presentationDetents([.medium, .large, .height(200)], selection: Binding(get: { pad.detent }, set: { pad.detent = $0 }))
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
            }
    }
}

struct UnorderedSheet: View {
    var body: some View {
        Text("under")
            .sheet(isPresented: .constant(true)) {
                Text("in").presentationDetents([.large, .fraction(0.25), .medium])
            }
    }
}

/// Gestures, shortcuts, commands and detents. Part of `ViewGraphTests`,
/// which is serialized.
extension ViewGraphTests {

    func modifier(_ node: RenderNode?, _ kind: String) -> ModifierNode? {
        node?.modifiers.first { $0.kind == kind }
    }

    // MARK: Gestures

    @Test func aDragIsReportedAndItsStateReset() throws {
        let pad = Pad()
        let sink = TestSink()
        let graph = ViewGraph(Pane(pad: pad), sink: sink)
        graph.update()
        let node = try #require(sink.screen?.find("Text", text: "still"))
        let drag = try #require(modifier(node, "dragGesture"))
        #expect(drag.args == ["minimumDistance": .double(4), "coordinateSpace": "global"])

        func send(_ values: [Double]) {
            #expect(graph.handle(node.id, kind: .drag, payload: .array(values.map { .double($0) })))
            graph.update()
        }
        send([0, 10, 10, 15, 30, 15, 30])
        #expect(pad.drags == ["changed 5.0 20.0"])
        #expect(sink.screen?.find("Text", text: "dragging") != nil, "the gesture state, while it lasts")
        send([1, 10, 10, 20, 30, 60, 30])
        #expect(pad.drags.last == "ended 50.0")
        #expect(sink.screen?.find("Text", text: "still") != nil, "back to its first value")

        // Cancelled: no end, and the state goes back too.
        send([0, 0, 0, 1, 1, 1, 1])
        #expect(sink.screen?.find("Text", text: "dragging") != nil)
        send([2, 0, 0, 1, 1, 1, 1])
        #expect(pad.drags.count == 3 && sink.screen?.find("Text", text: "still") != nil)
        // Whole numbers, as a host may send them; a short payload is ignored.
        #expect(graph.handle(node.id, kind: .drag, payload: .array([.int(0), .int(0), .int(0), .int(3), .int(4), .int(3), .int(4)])))
        #expect(pad.drags.last == "changed 3.0 4.0")
        #expect(graph.handle(node.id, kind: .drag, payload: .array([.int(1)])))
        #expect(pad.drags.count == 4)
    }

    @Test func aLongPressAndWhetherItsPressing() throws {
        let pad = Pad()
        let sink = TestSink()
        let graph = ViewGraph(Pane(pad: pad), sink: sink)
        graph.update()

        let gesture = try #require(sink.screen?.find("Text", text: "free"))
        #expect(modifier(gesture, "longPressGesture")?.args == ["minimumDuration": .double(1), "maximumDistance": .double(10), "pressing": .bool(true)])
        #expect(graph.handle(gesture.id, kind: .pressing, payload: .bool(true)))
        graph.update()
        #expect(sink.screen?.find("Text", text: "holding") != nil)
        #expect(graph.handle(gesture.id, kind: .longPress))
        #expect(pad.presses == ["gesture"])
        graph.update()
        #expect(sink.screen?.find("Text", text: "free") != nil, "it ended")

        let press = try #require(sink.screen?.find("Text", text: "press"))
        #expect(modifier(press, "longPressGesture")?.args == ["minimumDuration": .double(0.3), "maximumDistance": .double(20), "pressing": .bool(true)])
        #expect(graph.handle(press.id, kind: .pressing, payload: .bool(true)))
        #expect(graph.handle(press.id, kind: .longPress))
        #expect(graph.handle(press.id, kind: .pressing, payload: .bool(false)))
        #expect(pad.presses == ["gesture", "modifier"] && pad.pressingNow == [true, false])

        // A long press without `onPressingChanged` doesn't ask for it.
        let quiet = Text("q").onLongPressGesture { }
        let quietSink = TestSink()
        ViewGraph(quiet, sink: quietSink).update()
        #expect(modifier(quietSink.screen, "longPressGesture")?.args["pressing"] == nil)

        let tap = try #require(sink.screen?.find("Text", text: "tap"))
        #expect(modifier(tap, "onTapGesture")?.args == ["count": .int(2)])
        #expect(graph.handle(tap.id, kind: .tap))
        #expect(pad.taps == 1)
    }

    // MARK: Shortcuts

    @Test func shortcutsAreModifiersTheHostPresses() throws {
        let pad = Pad()
        let sink = TestSink()
        let graph = ViewGraph(Pane(pad: pad), sink: sink)
        graph.update()
        let stack = try #require(sink.screen)
        let save = try #require(stack.button("Save"))
        #expect(modifier(save, "keyboardShortcut")?.args == ["key": "s", "modifiers": .array(["command"])])
        #expect(graph.handle(save.id, kind: .tap) && pad.saves == 1, "pressing it is the button's tap")
        #expect(modifier(stack.button("Done"), "keyboardShortcut")?.args == ["key": "return", "modifiers": .array([])])
        let group = try #require(stack.children.first { $0.type == "VStack" })
        #expect(modifier(group, "keyboardShortcut")?.args["modifiers"] == .array(["command", "shift", "option", "control"]), "on a view, for its buttons")
        #expect(modifier(stack.button("Plain"), "keyboardShortcut")?.args == [:], "none, over one further out")
        #expect(KeyboardShortcut.cancelAction.key == .escape && KeyboardShortcut.cancelAction.modifiers.isEmpty)
    }

    // MARK: Commands

    @Test func commandsWrapTheContent() throws {
        let pad = Pad()
        let scene = WindowGroup {
            Text("content")
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(pad.title) { pad.saves += 1 }
                    .keyboardShortcut("t")
            }
            CommandMenu("History") {
                Button("Back") { }
                Divider()
            }
            CommandGroup(replacing: .help) { }
            CommandGroup(before: .sidebar) { Button("Inspector") { } }
        }
        let sink = TestSink()
        let graph = ViewGraph(scene.content, sink: sink)
        graph.update()
        let root = try #require(sink.screen)
        #expect(root.type == "Commands")
        #expect(root.children.map(\.type) == ["Text", "CommandGroup", "CommandMenu", "CommandGroup", "CommandGroup"], "the content first")
        #expect(root.children[1].props == ["placement": "newItem", "position": "after"])
        #expect(root.children[2].props == ["title": "History"])
        #expect(root.children[2].children.map(\.type) == ["Button", "Divider"])
        #expect(root.children[3].props == ["placement": "help", "position": "replacing"] && root.children[3].children.isEmpty)
        #expect(root.children[4].props["position"] == "before")

        // A command's button is a button; its title follows what it read.
        let command = try #require(root.children[1].button("New Tab"))
        #expect(graph.handle(command.id, kind: .tap) && pad.saves == 1)
        pad.title = "New Private Tab"
        graph.setNeedsUpdate()
        graph.update()
        #expect(sink.screen?.children[1].button("New Private Tab") != nil)
    }

    // MARK: Detents

    @Test func detentsAreTheSheetContentsAndReportedBack() throws {
        let pad = Pad()
        let sink = TestSink()
        let graph = ViewGraph(SheetHost(pad: pad), sink: sink)
        graph.update()
        let sheet = try #require(sink.screen?.find("Sheet"))
        let content = sheet.children[1]
        #expect(modifier(content, "presentationDetents")?.args == [
            "detents": .array(["medium", "large", .array(["height", .double(200)])]),
            "selection": .int(0),
        ])
        #expect(modifier(content, "presentationDragIndicator")?.args == ["visibility": "visible"])
        #expect(modifier(content, "interactiveDismissDisabled")?.args == ["value": .bool(true)])

        // The user dragged it to the second.
        #expect(graph.handle(sheet.id, kind: .detent, payload: .int(1)))
        #expect(pad.detent == .large)
        #expect(graph.handle(sheet.id, kind: .detent, payload: .int(9)))
        #expect(pad.detent == .large, "an index past the end changes nothing")
        graph.setNeedsUpdate()
        graph.update()
        #expect(modifier(sink.screen?.find("Sheet")?.children[1], "presentationDetents")?.args["selection"] == .int(1))

        // The app moves it.
        pad.detent = .height(200)
        graph.setNeedsUpdate()
        graph.update()
        #expect(modifier(sink.screen?.find("Sheet")?.children[1], "presentationDetents")?.args["selection"] == .int(2))

        // An array keeps its order; a set is ordered smallest first.
        let other = TestSink()
        ViewGraph(UnorderedSheet(), sink: other).update()
        let ordered = modifier(other.screen?.find("Sheet")?.children[1], "presentationDetents")?.args["detents"]
        #expect(ordered == .array(["large", .array(["fraction", .double(0.25)]), "medium"]), "an array keeps its order")
        #expect(UnorderedSheet.ordered([.large, .fraction(0.25), .medium, .height(600)]) == [.fraction(0.25), .medium, .height(600), .large])
    }
}

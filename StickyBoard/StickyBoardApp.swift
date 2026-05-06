import SwiftUI
import AppKit

// MARK: - Data Model

struct BoardElement: Codable, Identifiable {
    var id: UUID
    var type: ElementType
    var content: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    enum ElementType: String, Codable { case text, image }

    init(type: ElementType, content: String, x: Double, y: Double, w: Double, h: Double) {
        self.id = UUID()
        self.type = type; self.content = content
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

struct Desk: Codable {
    var name: String
    var elements: [BoardElement]
}

struct Board: Codable {
    var desks: [Desk]
    var activeDeskIndex: Int
    static let empty = Board(desks: [Desk(name: "Default", elements: [])], activeDeskIndex: 0)
    var activeDesk: Desk {
        get { desks[activeDeskIndex] }
        set { desks[activeDeskIndex] = newValue }
    }
}

// MARK: - Persistence

class BoardStore {
    static let shared = BoardStore()
    var board: Board

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickyBoard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("board.json")
    }

    private static var imagesDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickyBoard/images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let b = try? JSONDecoder().decode(Board.self, from: data) {
            board = b
        } else { board = .empty }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(board) else { return }
        try? data.write(to: Self.fileURL)
    }

    func saveImage(_ image: NSImage) -> String? {
        let id = UUID().uuidString
        let url = Self.imagesDir.appendingPathComponent("\(id).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return url.path
    }
}

// MARK: - App Entry

@main
struct StickyBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { SwiftUI.Settings { EmptyView() } }
}

// MARK: - Canvas Window (borderless but can become key for text input)

class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Canvas View

class CanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    weak var appDelegate: AppDelegate?

    override func mouseDown(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }
        let loc = convert(event.locationInWindow, from: nil)

        // Resize handle — always first priority
        if let (id, view) = d.hitTestResizeHandle(loc) {
            d.resizeElement = id
            d.resizeStart = loc
            d.resizeOriginalFrame = view.frame
            return
        }

        // Check if clicking on element's edge (border area) → drag
        if let (id, view) = d.hitTestBorder(loc) {
            d.dragElement = id
            d.dragStart = loc
            d.dragOrigin = view.frame.origin
            d.didDrag = false
            return
        }

        // Click inside element content → let the text field handle it naturally
        if d.hitTest(loc) != nil {
            return // pass through to text field
        }

        // Empty space → exit edit mode
        d.exitEditMode()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }
        let loc = convert(event.locationInWindow, from: nil)

        if let id = d.resizeElement, let view = d.elementViews[id] {
            let dx = loc.x - d.resizeStart.x
            let dy = loc.y - d.resizeStart.y
            view.frame.size = NSSize(width: max(40, d.resizeOriginalFrame.width + dx),
                                     height: max(20, d.resizeOriginalFrame.height + dy))
            d.syncHandlePositions()
        } else if let id = d.dragElement, let view = d.elementViews[id] {
            let dx = loc.x - d.dragStart.x
            let dy = loc.y - d.dragStart.y
            d.didDrag = true
            view.frame.origin = NSPoint(x: d.dragOrigin.x + dx, y: d.dragOrigin.y + dy)
            d.syncHandlePositions()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }
        d.dragElement = nil
        d.resizeElement = nil
        d.didDrag = false
        d.savePositions()
    }

    override func keyDown(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }
        // If a text field is active, don't intercept keys
        if d.canvas.firstResponder is NSTextView { return }
        if event.keyCode == 53 { d.exitEditMode() } // Esc
        else if event.keyCode == 51 { d.deleteSelectedElement() } // Delete
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    static weak var shared: AppDelegate?
    var statusItem: NSStatusItem!
    var canvas: NSWindow!
    var canvasView: CanvasView!
    var editMode = false
    var elementViews: [UUID: NSView] = [:]
    var store = BoardStore.shared

    var dragElement: UUID?
    var dragStart: NSPoint = .zero
    var dragOrigin: NSPoint = .zero
    var didDrag = false
    var resizeElement: UUID?
    var resizeStart: NSPoint = .zero
    var resizeOriginalFrame: NSRect = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        setupCanvas()
        setupMenu()
        renderElements()
    }

    // MARK: - Canvas

    func setupCanvas() {
        guard let screen = NSScreen.main else { return }
        canvas = CanvasWindow(contentRect: screen.frame,
                          styleMask: .borderless, backing: .buffered, defer: false)
        canvas.level = .floating
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.hasShadow = false
        canvas.ignoresMouseEvents = true
        canvas.collectionBehavior = [.canJoinAllSpaces, .stationary]

        canvasView = CanvasView(frame: screen.frame)
        canvasView.appDelegate = self
        canvasView.wantsLayer = true
        canvas.contentView = canvasView
        canvas.orderFrontRegardless()
    }

    // MARK: - Menu

    func setupMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.title = "📌"
        }
        let menu = NSMenu()

        let addText = NSMenuItem(title: "Add Text", action: #selector(addTextAction), keyEquivalent: "")
        addText.target = self; menu.addItem(addText)

        let paste = NSMenuItem(title: "Paste from Clipboard", action: #selector(pasteFromClipboard), keyEquivalent: "")
        paste.target = self; menu.addItem(paste)

        menu.addItem(.separator())

        let edit = NSMenuItem(title: "Edit Mode", action: #selector(toggleEditModeAction), keyEquivalent: "")
        edit.target = self; menu.addItem(edit)

        menu.addItem(.separator())

        let desksItem = NSMenuItem(title: "Desks", action: nil, keyEquivalent: "")
        let desksMenu = NSMenu()
        desksItem.submenu = desksMenu
        menu.addItem(desksItem)

        let newDesk = NSMenuItem(title: "New Desk…", action: #selector(newDesk), keyEquivalent: "")
        newDesk.target = self; desksMenu.addItem(newDesk)
        desksMenu.addItem(.separator())
        for (i, desk) in store.board.desks.enumerated() {
            let item = NSMenuItem(title: desk.name, action: #selector(switchDesk(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            if i == store.board.activeDeskIndex { item.state = .on }
            desksMenu.addItem(item)
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Toggle Visibility", action: #selector(toggleVisibility), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)

        statusItem.menu = menu
    }

    func rebuildMenu() { statusItem.menu = nil; setupMenu() }

    // MARK: - Render

    func renderElements() {
        removeHandles()
        elementViews.values.forEach { $0.removeFromSuperview() }
        elementViews.removeAll()
        for el in store.board.activeDesk.elements {
            let view = createView(for: el)
            canvasView.addSubview(view)
            elementViews[el.id] = view
        }
        if editMode { updateHandles() }
    }

    func createView(for el: BoardElement) -> NSView {
        let frame = NSRect(x: el.x, y: el.y, width: el.w, height: el.h)
        switch el.type {
        case .text:
            let label = NSTextField(frame: frame)
            label.stringValue = el.content
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = true
            label.backgroundColor = NSColor(white: 0.1, alpha: 0.85)
            label.textColor = .white
            label.font = .systemFont(ofSize: 14)
            label.focusRingType = .none
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = true
            label.delegate = self
            label.wantsLayer = true
            label.layer?.cornerRadius = 6
            if editMode { label.layer?.borderColor = NSColor.systemBlue.cgColor; label.layer?.borderWidth = 2 }
            return label
        case .image:
            let imgView = NSImageView(frame: frame)
            imgView.image = NSImage(contentsOfFile: el.content)
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 6
            imgView.layer?.masksToBounds = true
            if editMode { imgView.layer?.borderColor = NSColor.systemBlue.cgColor; imgView.layer?.borderWidth = 2 }
            return imgView
        }
    }

    // MARK: - Edit Mode

    @objc func toggleEditModeAction() {
        if editMode { exitEditMode() } else { enterEditMode() }
    }

    func enterEditMode() {
        editMode = true
        canvas.ignoresMouseEvents = false
        canvas.makeKeyAndOrderFront(nil)
        NSApp.activate()
        canvasView.layer?.backgroundColor = NSColor(white: 0, alpha: 0.03).cgColor
        elementViews.values.forEach {
            $0.layer?.borderColor = NSColor.systemBlue.cgColor
            $0.layer?.borderWidth = 2
            if let tf = $0 as? NSTextField {
                tf.isEditable = true
                tf.isSelectable = true
            }
        }
        updateHandles()
    }

    func exitEditMode() {
        editMode = false
        canvas.ignoresMouseEvents = true
        canvasView.layer?.backgroundColor = nil
        removeHandles()
        elementViews.values.forEach {
            $0.layer?.borderWidth = 0
            if let tf = $0 as? NSTextField {
                tf.isEditable = false
                tf.isSelectable = false
                tf.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
                canvas.makeFirstResponder(nil)
            }
        }
        savePositions()
    }

    // MARK: - Handles (outside elements, on canvasView)

    var dragHandles: [UUID: NSView] = [:]
    var resizeHandles: [UUID: NSView] = [:]

    func updateHandles() {
        removeHandles()
        let s: CGFloat = 12
        for (id, view) in elementViews {
            // Drag handle — top center, above element
            let dh = makeHandle(color: .systemBlue)
            dh.frame = NSRect(x: view.frame.midX - s/2, y: view.frame.minY - s - 4, width: s, height: s)
            canvasView.addSubview(dh)
            dragHandles[id] = dh

            // Resize handle — bottom right, below element
            let rh = makeHandle(color: .systemOrange)
            rh.frame = NSRect(x: view.frame.maxX - s/2, y: view.frame.maxY + 4, width: s, height: s)
            canvasView.addSubview(rh)
            resizeHandles[id] = rh
        }
    }

    func makeHandle(color: NSColor) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        v.layer?.cornerRadius = 6
        return v
    }

    func removeHandles() {
        dragHandles.values.forEach { $0.removeFromSuperview() }
        resizeHandles.values.forEach { $0.removeFromSuperview() }
        dragHandles.removeAll()
        resizeHandles.removeAll()
    }

    func syncHandlePositions() {
        let s: CGFloat = 12
        for (id, view) in elementViews {
            if let dh = dragHandles[id] {
                dh.frame = NSRect(x: view.frame.midX - s/2, y: view.frame.minY - s - 4, width: s, height: s)
            }
            if let rh = resizeHandles[id] {
                rh.frame = NSRect(x: view.frame.maxX - s/2, y: view.frame.maxY + 4, width: s, height: s)
            }
        }
    }

    // MARK: - Add Text (from menu)

    @objc func addTextAction() {
        enterEditMode()
        // Create text field at center of screen
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let point = NSPoint(x: screen.width / 2 - 100, y: screen.height / 2 - 15)
        createTextInline(at: point)
    }

    func createTextInline(at point: NSPoint) {
        let frame = NSRect(x: point.x, y: point.y, width: 200, height: 30)
        let field = NSTextField(frame: frame)
        field.placeholderString = "Type here…"
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 0.1, alpha: 0.85)
        field.textColor = .white
        field.font = .systemFont(ofSize: 14)
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.delegate = self
        field.tag = 9999 // marker for new text field
        canvasView.addSubview(field)
        canvas.makeFirstResponder(field)
    }

    // MARK: - Save on edit end

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field.tag == 9999 {
            let text = field.stringValue
            let frame = field.frame
            field.removeFromSuperview()
            guard !text.isEmpty else { return }
            let el = BoardElement(type: .text, content: text, x: frame.origin.x, y: frame.origin.y, w: frame.width, h: frame.height)
            store.board.activeDesk.elements.append(el)
            store.save()
            let view = createView(for: el)
            canvasView.addSubview(view)
            elementViews[el.id] = view
            if editMode { updateHandles() }
        } else {
            if let id = elementViews.first(where: { $0.value === field })?.key,
               let idx = store.board.activeDesk.elements.firstIndex(where: { $0.id == id }) {
                store.board.activeDesk.elements[idx].content = field.stringValue
                store.save()
            }
        }
    }

    // MARK: - Hit Testing

    func hitTest(_ point: NSPoint) -> (UUID, NSView)? {
        for (id, view) in elementViews {
            if view.frame.contains(point) { return (id, view) }
        }
        return nil
    }

    func hitTestBorder(_ point: NSPoint) -> (UUID, NSView)? {
        for (id, handle) in dragHandles {
            if handle.frame.contains(point), let view = elementViews[id] { return (id, view) }
        }
        return nil
    }

    func hitTestResizeHandle(_ point: NSPoint) -> (UUID, NSView)? {
        for (id, handle) in resizeHandles {
            if handle.frame.contains(point), let view = elementViews[id] { return (id, view) }
        }
        return nil
    }

    func elementType(_ id: UUID) -> BoardElement.ElementType? {
        store.board.activeDesk.elements.first { $0.id == id }?.type
    }

    // MARK: - Delete

    func deleteSelectedElement() {
        guard let id = dragElement, let view = elementViews[id] else { return }
        view.removeFromSuperview()
        elementViews.removeValue(forKey: id)
        store.board.activeDesk.elements.removeAll { $0.id == id }
        store.save()
        dragElement = nil
    }

    // MARK: - Save Positions

    func savePositions() {
        for (id, view) in elementViews {
            if let idx = store.board.activeDesk.elements.firstIndex(where: { $0.id == id }) {
                store.board.activeDesk.elements[idx].x = view.frame.origin.x
                store.board.activeDesk.elements[idx].y = view.frame.origin.y
                store.board.activeDesk.elements[idx].w = view.frame.width
                store.board.activeDesk.elements[idx].h = view.frame.height
            }
        }
        store.save()
    }

    // MARK: - Paste

    @objc func pasteFromClipboard() {
        let pb = NSPasteboard.general
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        if let image = NSImage(pasteboard: pb), let path = store.saveImage(image) {
            let w = min(Double(image.size.width), 400)
            let h = w * Double(image.size.height) / Double(image.size.width)
            let el = BoardElement(type: .image, content: path,
                                 x: screen.width / 2 - w / 2, y: screen.height / 2 - h / 2, w: w, h: h)
            addElement(el)
            return
        }

        if let text = pb.string(forType: .string), !text.isEmpty {
            let el = BoardElement(type: .text, content: text,
                                 x: screen.width / 2 - 75, y: screen.height / 2 - 20, w: 150, h: 40)
            addElement(el)
        }
    }

    func addElement(_ el: BoardElement) {
        store.board.activeDesk.elements.append(el)
        store.save()
        let view = createView(for: el)
        canvasView.addSubview(view)
        elementViews[el.id] = view
        if editMode { updateHandles() }
    }

    // MARK: - Desks

    @objc func newDesk() {
        let alert = NSAlert()
        alert.messageText = "New Desk"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "Desk name"
        alert.accessoryView = input
        alert.window.level = .modalPanel
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        store.board.desks.append(Desk(name: input.stringValue, elements: []))
        store.board.activeDeskIndex = store.board.desks.count - 1
        store.save(); renderElements(); rebuildMenu()
    }

    @objc func switchDesk(_ sender: NSMenuItem) {
        if editMode { exitEditMode() }
        store.board.activeDeskIndex = sender.tag
        store.save(); renderElements(); rebuildMenu()
    }

    @objc func toggleVisibility() {
        if canvas.isVisible { canvas.orderOut(nil) } else { canvas.orderFrontRegardless() }
    }

    @objc func doQuit() { NSApp.terminate(nil) }
}

import SwiftUI
import AppKit

// MARK: - Constants

let kEditOverlayAlpha: CGFloat = 0.3
let kEditFadeDuration: CFTimeInterval = 0.15

// MARK: - Data Model

struct BoardElement: Codable, Identifiable {
    var id: UUID
    var type: ElementType
    var content: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var rotation: Double

    enum ElementType: String, Codable { case text, image }

    init(type: ElementType, content: String, x: Double, y: Double, w: Double, h: Double) {
        self.id = UUID()
        self.type = type; self.content = content
        self.x = x; self.y = y; self.w = w; self.h = h
        self.rotation = 0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(ElementType.self, forKey: .type)
        content = try c.decode(String.self, forKey: .content)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w)
        h = try c.decode(Double.self, forKey: .h)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
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

class CanvasWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result, responder is NSTextView || responder is NSTextField {
            AppDelegate.shared?.wasEditingText = true
        }
        return result
    }
}

// MARK: - Canvas View

class CanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    weak var appDelegate: AppDelegate?

    override func mouseDown(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }
        let loc = convert(event.locationInWindow, from: nil)

        // If an element is selected, check its handles first
        if let selId = d.selectedElement, let selC = d.containers[selId] {
            if selC.hitHandle(selC.deleteHandle, point: loc) {
                d.deleteElement(selId); return
            }
            if selC.hitHandle(selC.menuHandle, point: loc) {
                d.showElementMenu(selId, at: loc); return
            }
            if selC.hitHandle(selC.rotateHandle, point: loc) {
                d.rotateElement = selId
                d.rotateStart = loc
                d.rotateOriginalAngle = selC.rotation
                return
            }
            if selC.hitHandle(selC.resizeHandle, point: loc) {
                d.resizeElement = selId
                d.resizeStart = loc
                d.resizeOriginalSize = selC.contentView.frame.size
                return
            }
            if selC.hitHandle(selC.dragHandle, point: loc) {
                d.dragElement = selId
                d.dragStart = loc
                d.dragOrigin = selC.contentFrame.origin
                d.didDrag = false
                return
            }
        }

        // Click/drag on any element
        if let (id, c) = d.hitTest(loc) {
            if d.selectedElement != nil && d.selectedElement != id { d.deselectElement() }
            d.dragElement = id
            d.dragStart = loc
            d.dragOrigin = c.contentFrame.origin
            d.didDrag = false
            return
        }

        // Empty space
        if d.selectedElement != nil {
            d.deselectElement()
            d.canvas.makeFirstResponder(d.canvasView)
        } else {
            d.exitEditMode()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }
        let loc = convert(event.locationInWindow, from: nil)

        if let id = d.rotateElement, let c = d.containers[id] {
            let center = NSPoint(x: c.contentFrame.midX, y: c.contentFrame.midY)
            let startAngle = atan2(d.rotateStart.y - center.y, d.rotateStart.x - center.x)
            let curAngle = atan2(loc.y - center.y, loc.x - center.x)
            let delta = (curAngle - startAngle) * 180 / .pi
            c.applyRotation(d.rotateOriginalAngle + delta)
        } else if let id = d.resizeElement, let c = d.containers[id] {
            let dx = loc.x - d.resizeStart.x
            let dy = loc.y - d.resizeStart.y
            let newSize = NSSize(width: max(40, d.resizeOriginalSize.width + dx),
                                 height: max(20, d.resizeOriginalSize.height + dy))
            c.updateContentSize(newSize)
        } else if let id = d.dragElement, let c = d.containers[id] {
            let dx = loc.x - d.dragStart.x
            let dy = loc.y - d.dragStart.y
            if abs(dx) > 3 || abs(dy) > 3 { d.didDrag = true }
            if d.didDrag {
                c.updatePosition(NSPoint(x: d.dragOrigin.x + dx, y: d.dragOrigin.y + dy))
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }

        // Click without drag → select element
        if let id = d.dragElement, !d.didDrag {
            d.selectElement(id)
        }

        d.dragElement = nil
        d.resizeElement = nil
        d.rotateElement = nil
        d.didDrag = false
        d.savePositions()
    }

    override func keyDown(with event: NSEvent) {
        guard let d = appDelegate, d.editMode else { return }
        if d.canvas.firstResponder is NSTextView { return }
        if event.keyCode == 53 { d.exitEditMode() } // Esc
    }
}

// MARK: - Element Container (content + handles)

class ElementContainerView: NSView {
    override var isFlipped: Bool { true }
    let contentView: NSView
    let dragHandle = NSView()
    let resizeHandle = NSView()
    let deleteHandle = NSView()
    let rotateHandle = NSView()
    let menuHandle = NSView()
    private let handleSize: CGFloat = 12
    var rotation: CGFloat = 0

    init(content: NSView) {
        self.contentView = content
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(contentView)

        dragHandle.wantsLayer = true
        dragHandle.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dragHandle.layer?.cornerRadius = handleSize / 2
        addSubview(dragHandle)

        resizeHandle.wantsLayer = true
        resizeHandle.layer?.backgroundColor = NSColor.systemOrange.cgColor
        resizeHandle.layer?.cornerRadius = handleSize / 2
        addSubview(resizeHandle)

        deleteHandle.wantsLayer = true
        deleteHandle.layer?.backgroundColor = NSColor.systemRed.cgColor
        deleteHandle.layer?.cornerRadius = handleSize / 2
        addSubview(deleteHandle)

        rotateHandle.wantsLayer = true
        rotateHandle.layer?.backgroundColor = NSColor.systemGreen.cgColor
        rotateHandle.layer?.cornerRadius = handleSize / 2
        addSubview(rotateHandle)

        menuHandle.wantsLayer = true
        menuHandle.layer?.backgroundColor = NSColor.systemGray.cgColor
        menuHandle.layer?.cornerRadius = handleSize / 2
        addSubview(menuHandle)

        setHandlesVisible(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func layout(for elementFrame: NSRect) {
        let pad: CGFloat = handleSize + 4
        frame = NSRect(x: elementFrame.origin.x - pad, y: elementFrame.origin.y - pad,
                       width: elementFrame.width + pad * 2, height: elementFrame.height + pad * 2)
        contentView.frame = NSRect(x: pad, y: pad, width: elementFrame.width, height: elementFrame.height)
        // All handles at same offset from content edges
        let hOff: CGFloat = -2 // overlap slightly with padding area
        deleteHandle.frame = NSRect(x: hOff, y: hOff, width: handleSize, height: handleSize)
        dragHandle.frame = NSRect(x: (frame.width - handleSize) / 2, y: hOff, width: handleSize, height: handleSize)
        rotateHandle.frame = NSRect(x: frame.width - handleSize - hOff, y: hOff, width: handleSize, height: handleSize)
        menuHandle.frame = NSRect(x: hOff, y: (frame.height - handleSize) / 2, width: handleSize, height: handleSize)
        resizeHandle.frame = NSRect(x: frame.width - handleSize - hOff, y: frame.height - handleSize - hOff, width: handleSize, height: handleSize)
    }

    func setHandlesVisible(_ visible: Bool) {
        dragHandle.isHidden = !visible
        resizeHandle.isHidden = !visible
        deleteHandle.isHidden = !visible
        rotateHandle.isHidden = !visible
        menuHandle.isHidden = !visible
    }

    /// Convert a point from superview coords to local coords accounting for rotation
    func localPoint(from point: NSPoint) -> NSPoint {
        convert(point, from: superview)
    }

    func hitHandle(_ handle: NSView, point: NSPoint) -> Bool {
        let local = localPoint(from: point)
        return handle.frame.insetBy(dx: -4, dy: -4).contains(local)
    }

    func hitContent(point: NSPoint) -> Bool {
        let local = localPoint(from: point)
        return contentView.frame.contains(local)
    }

    /// Content frame in canvasView coordinates
    var contentFrame: NSRect {
        NSRect(x: frame.origin.x + contentView.frame.origin.x,
               y: frame.origin.y + contentView.frame.origin.y,
               width: contentView.frame.width, height: contentView.frame.height)
    }

    /// Drag handle frame in canvasView coordinates
    var dragHandleFrame: NSRect {
        NSRect(x: frame.origin.x + dragHandle.frame.origin.x,
               y: frame.origin.y + dragHandle.frame.origin.y,
               width: dragHandle.frame.width, height: dragHandle.frame.height)
    }

    /// Resize handle frame in canvasView coordinates
    var resizeHandleFrame: NSRect {
        NSRect(x: frame.origin.x + resizeHandle.frame.origin.x,
               y: frame.origin.y + resizeHandle.frame.origin.y,
               width: resizeHandle.frame.width, height: resizeHandle.frame.height)
    }

    /// Delete handle frame in canvasView coordinates
    var deleteHandleFrame: NSRect {
        NSRect(x: frame.origin.x + deleteHandle.frame.origin.x,
               y: frame.origin.y + deleteHandle.frame.origin.y,
               width: deleteHandle.frame.width, height: deleteHandle.frame.height)
    }

    var rotateHandleFrame: NSRect {
        NSRect(x: frame.origin.x + rotateHandle.frame.origin.x,
               y: frame.origin.y + rotateHandle.frame.origin.y,
               width: rotateHandle.frame.width, height: rotateHandle.frame.height)
    }

    var menuHandleFrame: NSRect {
        NSRect(x: frame.origin.x + menuHandle.frame.origin.x,
               y: frame.origin.y + menuHandle.frame.origin.y,
               width: menuHandle.frame.width, height: menuHandle.frame.height)
    }

    func updateContentSize(_ size: NSSize) {
        let pad: CGFloat = handleSize + 4
        frame.size = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        contentView.frame.size = size
        dragHandle.frame.origin.x = (frame.width - handleSize) / 2
        rotateHandle.frame.origin.x = frame.width - handleSize
        resizeHandle.frame = NSRect(x: frame.width - handleSize, y: frame.height - handleSize, width: handleSize, height: handleSize)
        menuHandle.frame.origin.y = (frame.height - handleSize) / 2
    }

    func updatePosition(_ origin: NSPoint) {
        let pad: CGFloat = handleSize + 4
        frame.origin = NSPoint(x: origin.x - pad, y: origin.y - pad)
    }

    func applyRotation(_ degrees: CGFloat) {
        rotation = degrees
        frameCenterRotation = degrees
    }

    override func resetCursorRects() {
        // Don't let subviews set cursor rects
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // If not selected (handles hidden), only handles respond to clicks
        // Content clicks pass through to canvasView for drag/select logic
        if dragHandle.isHidden {
            return nil // pass everything through to canvasView
        }
        // Selected: let content and handles respond normally
        return super.hitTest(point)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    var statusItem: NSStatusItem!
    var canvas: NSWindow!
    var canvasView: CanvasView!
    var editMode = false
    var containers: [UUID: ElementContainerView] = [:]
    var store = BoardStore.shared

    var dragElement: UUID?
    var dragStart: NSPoint = .zero
    var dragOrigin: NSPoint = .zero
    var didDrag = false
    var wasEditingText = false
    var selectedElement: UUID?
    var resizeElement: UUID?
    var resizeStart: NSPoint = .zero
    var resizeOriginalSize: NSSize = .zero
    var rotateElement: UUID?
    var rotateStart: NSPoint = .zero
    var rotateOriginalAngle: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        setupCanvas()
        setupMenu()
        renderElements()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc func spaceChanged() {
        if editMode { exitEditMode() }
    }

    // MARK: - Canvas

    func setupCanvas() {
        guard let screen = NSScreen.main else { return }
        canvas = CanvasWindow(contentRect: screen.frame,
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        canvas.level = .floating
        canvas.hidesOnDeactivate = false
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
        let delDesk = NSMenuItem(title: "Delete Current Desk", action: #selector(deleteCurrentDesk), keyEquivalent: "")
        delDesk.target = self; desksMenu.addItem(delDesk)
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

        statusItem.menu = nil
        menu.delegate = self
        trayMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    var trayMenu: NSMenu!

    func menuWillOpen(_ menu: NSMenu) {}
    func menuDidClose(_ menu: NSMenu) {}

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            if editMode { exitEditMode() } else { enterEditMode() }
        } else {
            statusItem.menu = trayMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    func rebuildMenu() { setupMenu() }

    // MARK: - Render

    func renderElements() {
        containers.values.forEach { $0.removeFromSuperview() }
        containers.removeAll()
        for el in store.board.activeDesk.elements {
            let container = createContainer(for: el)
            canvasView.addSubview(container)
            containers[el.id] = container
        }
    }

    func createContainer(for el: BoardElement) -> ElementContainerView {
        let frame = NSRect(x: el.x, y: el.y, width: el.w, height: el.h)
        let content: NSView
        switch el.type {
        case .text:
            let label = NSTextField(frame: .zero)
            label.stringValue = el.content
            label.isEditable = editMode
            label.isSelectable = editMode
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
            content = label
        case .image:
            let imgView = NSImageView(frame: .zero)
            imgView.image = NSImage(contentsOfFile: el.content)
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 6
            imgView.layer?.masksToBounds = true
            content = imgView
        }
        if editMode {
            content.layer?.borderColor = NSColor.systemBlue.cgColor
            content.layer?.borderWidth = 2
        }  
        let container = ElementContainerView(content: content)
        container.layout(for: frame)
        container.setHandlesVisible(false)
        if el.rotation != 0 { container.applyRotation(CGFloat(el.rotation)) }
        return container
    }

    // MARK: - Edit Mode

    @objc func toggleEditModeAction() {
        if editMode { exitEditMode() } else { enterEditMode() }
    }

    func enterEditMode() {
        editMode = true
        canvas.ignoresMouseEvents = false
        canvas.makeKeyAndOrderFront(nil)
        canvas.makeFirstResponder(canvasView)
        animateBackground(to: NSColor(white: 0, alpha: kEditOverlayAlpha))
        containers.values.forEach { c in
            c.contentView.layer?.borderColor = NSColor.systemBlue.cgColor
            c.contentView.layer?.borderWidth = 2
            c.setHandlesVisible(false)
        }
    }

    func exitEditMode() {
        editMode = false
        deselectElement()
        canvas.ignoresMouseEvents = true
        canvas.resignKey()
        containers.values.forEach { c in
            c.contentView.layer?.borderWidth = 0
            if let tf = c.contentView as? NSTextField {
                tf.isEditable = false
                tf.isSelectable = false
            }
        }
        savePositions()
        animateBackground(to: .clear)
    }

    private func animateBackground(to color: NSColor) {
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = canvasView.layer?.backgroundColor
        anim.toValue = color.cgColor
        anim.duration = kEditFadeDuration
        canvasView.layer?.add(anim, forKey: "bg")
        canvasView.layer?.backgroundColor = color.cgColor
    }

    func selectElement(_ id: UUID) {
        deselectElement()
        selectedElement = id
        guard let c = containers[id] else { return }
        c.setHandlesVisible(true)
        if let tf = c.contentView as? NSTextField {
            tf.isEditable = true
            tf.isSelectable = true
        }
    }

    func deselectElement() {
        if let id = selectedElement, let c = containers[id] {
            c.setHandlesVisible(false)
            if let tf = c.contentView as? NSTextField {
                tf.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
                tf.isEditable = false
                tf.isSelectable = false
            }
        }
        selectedElement = nil
        wasEditingText = false
        canvas.makeFirstResponder(canvasView)
    }

    // MARK: - Add Text (from menu)

    @objc func addTextAction() {
        if !editMode { enterEditMode() }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let el = BoardElement(type: .text, content: "",
                             x: screen.width / 2 - 100, y: screen.height / 2 - 15, w: 200, h: 30)
        addElement(el)
        selectElement(el.id)
        // Focus the text field for immediate typing
        if let c = containers[el.id], let tf = c.contentView as? NSTextField {
            canvas.makeFirstResponder(tf)
        }
    }



    // MARK: - Save on edit end

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            wasEditingText = false
            canvas.makeFirstResponder(canvasView)
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let id = containers.first(where: { $0.value.contentView === field })?.key,
           let idx = store.board.activeDesk.elements.firstIndex(where: { $0.id == id }) {
            store.board.activeDesk.elements[idx].content = field.stringValue
            store.save()
        }
    }

    // MARK: - Hit Testing

    func hitTest(_ point: NSPoint) -> (UUID, ElementContainerView)? {
        for (id, c) in containers {
            if c.hitContent(point: point) { return (id, c) }
        }
        return nil
    }



    // MARK: - Delete

    func deleteElement(_ id: UUID) {
        if selectedElement == id { selectedElement = nil }
        guard let c = containers[id] else { return }
        c.removeFromSuperview()
        containers.removeValue(forKey: id)
        store.board.activeDesk.elements.removeAll { $0.id == id }
        store.save()
    }

    // MARK: - Element Context Menu

    func showElementMenu(_ id: UUID, at point: NSPoint) {
        guard let el = store.board.activeDesk.elements.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()

        if el.type == .text {
            menu.addItem(NSMenuItem(title: "Font Size…", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Text Color…", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }
        if el.type == .image {
            menu.addItem(NSMenuItem(title: "Resize to Original", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        let copy = NSMenuItem(title: "Copy", action: #selector(copyElement(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = id; menu.addItem(copy)
        let del = NSMenuItem(title: "Delete", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
        del.target = self; del.representedObject = id; menu.addItem(del)

        menu.popUp(positioning: nil, at: point, in: canvasView)
    }

    @objc func copyElement(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let el = store.board.activeDesk.elements.first(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if el.type == .text { pb.setString(el.content, forType: .string) }
        else if let img = NSImage(contentsOfFile: el.content) { pb.writeObjects([img]) }
    }

    @objc func deleteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        deleteElement(id)
    }

    // MARK: - Save Positions

    func savePositions() {
        for (id, c) in containers {
            if let idx = store.board.activeDesk.elements.firstIndex(where: { $0.id == id }) {
                let f = c.contentFrame
                store.board.activeDesk.elements[idx].x = f.origin.x
                store.board.activeDesk.elements[idx].y = f.origin.y
                store.board.activeDesk.elements[idx].w = f.width
                store.board.activeDesk.elements[idx].h = f.height
                store.board.activeDesk.elements[idx].rotation = Double(c.rotation)
            }
        }
        store.save()
    }

    // MARK: - Paste

    @objc func pasteFromClipboard() {
        if !editMode { enterEditMode() }
        let pb = NSPasteboard.general
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        if let image = NSImage(pasteboard: pb), let path = store.saveImage(image) {
            let w = min(Double(image.size.width), 400)
            let h = w * Double(image.size.height) / Double(image.size.width)
            let el = BoardElement(type: .image, content: path,
                                 x: screen.width / 2 - w / 2, y: screen.height / 2 - h / 2, w: w, h: h)
            addElement(el); selectElement(el.id)
            return
        }

        if let text = pb.string(forType: .string), !text.isEmpty {
            let el = BoardElement(type: .text, content: text,
                                 x: screen.width / 2 - 75, y: screen.height / 2 - 20, w: 150, h: 40)
            addElement(el); selectElement(el.id)
        }
    }

    func addElement(_ el: BoardElement) {
        store.board.activeDesk.elements.append(el)
        store.save()
        let container = createContainer(for: el)
        canvasView.addSubview(container)
        containers[el.id] = container
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

    @objc func deleteCurrentDesk() {
        if editMode { exitEditMode() }
        if store.board.desks.count > 1 {
            store.board.desks.remove(at: store.board.activeDeskIndex)
            store.board.activeDeskIndex = max(0, store.board.activeDeskIndex - 1)
        } else {
            store.board.desks[0] = Desk(name: "Default", elements: [])
        }
        store.save(); renderElements(); rebuildMenu()
    }

    @objc func toggleVisibility() {
        if canvas.isVisible { canvas.orderOut(nil) } else { canvas.orderFrontRegardless() }
    }

    @objc func doQuit() { NSApp.terminate(nil) }
}

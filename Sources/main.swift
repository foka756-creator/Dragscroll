import AppKit
import ApplicationServices

func log(_ m: String) {
    let line = "\(Date()) \(m)\n"
    let url = URL(fileURLWithPath: "/tmp/dragscroll.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// MARK: - Клавиша удвоения скорости

enum BoostKey: String, CaseIterable {
    case none, shift, control, option, command, fn

    var title: String {
        switch self {
        case .none: return "Нет"
        case .shift: return "Shift ⇧"
        case .control: return "Control ⌃"
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .fn: return "Fn"
        }
    }
    var mask: CGEventFlags? {
        switch self {
        case .none: return nil
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .fn: return .maskSecondaryFn
        }
    }
    func isDown(_ flags: CGEventFlags) -> Bool { mask.map { flags.contains($0) } ?? false }
}

// MARK: - Настройки

enum Prefs {
    static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var inverted: Bool {
        get { d.bool(forKey: "inverted") }
        set { d.set(newValue, forKey: "inverted") }
    }
    static var dialogCursor: Bool {
        get { d.object(forKey: "dialogCursor") as? Bool ?? true }
        set { d.set(newValue, forKey: "dialogCursor") }
    }
    static var boostKey: BoostKey {
        get { BoostKey(rawValue: d.string(forKey: "boostKey") ?? "") ?? .shift }
        set { d.set(newValue.rawValue, forKey: "boostKey") }
    }
    static var boostFactor: Double {
        get { d.object(forKey: "boostFactor") as? Double ?? 2.0 }
        set { d.set(newValue, forKey: "boostFactor") }
    }
    static var speed: Double {
        get { d.object(forKey: "speed") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "speed") }
    }
}

// MARK: - Красный курсор «рука» на время захвата

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

enum GrabCursor {
    static let cursor: NSCursor = {
        let size = NSSize(width: 32, height: 32)
        let cfg = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        let sym = NSImage(systemSymbolName: "hand.draw.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        let img = NSImage(size: size)
        img.lockFocus()
        if let sym = sym {
            let r = NSRect(x: (size.width - sym.size.width) / 2, y: (size.height - sym.size.height) / 2,
                           width: sym.size.width, height: sym.size.height)
            sym.draw(in: r)
            NSColor.systemRed.setFill()
            r.fill(using: .sourceAtop)  // перекрашиваем в красный
        }
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    /// Без этого фоновое приложение не может менять курсор вне своих окон.
    static func allowBackground() {
        _ = CGSSetConnectionProperty(CGSMainConnectionID(), CGSMainConnectionID(),
                                     "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
    static func show() { cursor.set() }
    static func hide() { NSCursor.arrow.set() }
}

// MARK: - Перетаскивание правой кнопкой

let syntheticMarker: Int64 = 0x44524147  // "DRAG": наши повторные клики не перехватываем

final class DragScroller {
    var tap: CFMachPort?
    var pressed = false
    var dragging = false
    var downLocation = CGPoint.zero
    var totalDx = 0, totalDy = 0
    var rest = (x: 0.0, y: 0.0)

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<DragScroller>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func reset() {
        if dragging { CGAssociateMouseAndMouseCursorPosition(1); GrabCursor.hide() }
        pressed = false; dragging = false
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if !Prefs.enabled || event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .rightMouseDown:
            log("rightDown")
            pressed = true; dragging = false
            downLocation = event.location
            totalDx = 0; totalDy = 0; rest = (0, 0)
            return nil  // откладываем клик до отпускания
        case .rightMouseDragged:
            guard pressed else { return Unmanaged.passUnretained(event) }
            let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
            totalDx += dx; totalDy += dy
            if !dragging {
                if DragMath.isClick(totalDx: totalDx, totalDy: totalDy) { return nil }
                dragging = true
                CGAssociateMouseAndMouseCursorPosition(0)  // курсор стоит на месте, пока тянем
                GrabCursor.show()
                postScroll(dx: totalDx, dy: totalDy, flags: event.flags)
            } else {
                GrabCursor.show()  // система сбрасывает курсор при прокрутке
                postScroll(dx: dx, dy: dy, flags: event.flags)
            }
            return nil
        case .rightMouseUp:
            guard pressed else { return Unmanaged.passUnretained(event) }
            let wasDragging = dragging
            reset()
            if !wasDragging { replayRightClick(at: downLocation) }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    func postScroll(dx: Int, dy: Int, flags: CGEventFlags) {
        let s = DragMath.scroll(dx: dx, dy: dy, inverted: Prefs.inverted, speed: DragMath.boosted(speed: Prefs.speed, active: Prefs.boostKey.isDown(flags), factor: Prefs.boostFactor), rest: &rest)
        guard s.x != 0 || s.y != 0 else { return }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: s.y, wheel2: s.x, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        e.post(tap: .cgSessionEventTap)
    }

    func replayRightClick(at p: CGPoint) {
        for t in [CGEventType.rightMouseDown, .rightMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - Курсор на кнопку по умолчанию

final class DialogWatcher {
    private var observers: [pid_t: AXObserver] = [:]
    private var lastHandled: [CFHashCode: Date] = [:]

    func start() {
        let ws = NSWorkspace.shared
        ws.runningApplications.forEach(attach)
        let nc = ws.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.attach(a) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.observers[a.processIdentifier] = nil
            }
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid(), observers[pid] == nil, app.activationPolicy != .prohibited || app.bundleIdentifier != nil else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            Unmanaged<DialogWatcher>.fromOpaque(refcon!).takeUnretainedValue().scheduleCheck(element)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let o = obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(o, appEl, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        observers[pid] = o
    }

    func scheduleCheck(_ element: AXUIElement) {
        // даём окну дорисовать кнопки
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.check(element) }
    }

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func check(_ el: AXUIElement) {
        guard Prefs.dialogCursor else { return }
        let role = attr(el, kAXRoleAttribute) as? String
        let sub = attr(el, kAXSubroleAttribute) as? String
        let isDialog = role == kAXSheetRole || sub == kAXDialogSubrole || sub == kAXSystemDialogSubrole
        guard isDialog, let btnRef = attr(el, kAXDefaultButtonAttribute) else { return }
        let key = CFHash(el)
        if let t = lastHandled[key], Date().timeIntervalSince(t) < 1 { return }
        lastHandled[key] = Date()
        let btn = btnRef as! AXUIElement
        guard let pv = attr(btn, kAXPositionAttribute), let sv = attr(btn, kAXSizeAttribute) else { return }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return }
        glide(to: CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2))
    }

    private var glideTimer: Timer?

    /// Плавно ведёт курсор к точке, чтобы глаз успел проследить путь.
    private func glide(to target: CGPoint) {
        glideTimer?.invalidate()
        let start = CGEvent(source: nil)?.location ?? target
        let dist = hypot(target.x - start.x, target.y - start.y)
        let total = CursorPath.duration(distance: dist)
        let t0 = Date()
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            let t = Date().timeIntervalSince(t0) / total
            CGWarpMouseCursorPosition(CursorPath.point(from: start, to: target, t: t))
            if t >= 1 { timer.invalidate(); self?.glideTimer = nil }
        }
    }
}

// MARK: - Приложение в строке меню

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let scroller = DragScroller()
    let watcher = DialogWatcher()
    var started = false
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        GrabCursor.allowBackground()
        item.button?.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "DragScroll")
        rebuildMenu()
        tryStart(prompt: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if self?.started == false { self?.tryStart(prompt: false) }
        }
    }

    func tryStart(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if prompt || trusted { log("trusted=\(trusted)") }
        guard trusted else { return }
        let ok = scroller.start()
        log("tap started=\(ok)")
        if ok {
            watcher.start()
            started = true
            rebuildMenu()
        }
    }

    func rebuildMenu() {
        let m = NSMenu()
        if !started {
            m.addItem(withTitle: "Нужен доступ: Конфиденциальность → Универсальный доступ", action: nil, keyEquivalent: "")
            m.addItem(.separator())
        }
        func toggle(_ title: String, _ on: Bool, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off; m.addItem(i)
        }
        toggle("Перетаскивание правой кнопкой", Prefs.enabled, #selector(toggleEnabled))
        toggle("Инвертировать движение", Prefs.inverted, #selector(toggleInvert))
        toggle("Курсор на кнопку по умолчанию в диалогах", Prefs.dialogCursor, #selector(toggleDialog))
        let sp = NSMenu()
        for v in [0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 7.0, 10.0] {
            let i = NSMenuItem(title: "×\(String(format: "%g", v))", action: #selector(setSpeed(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = v; i.state = Prefs.speed == v ? .on : .off
            sp.addItem(i)
        }
        let spItem = NSMenuItem(title: "Скорость", action: nil, keyEquivalent: "")
        spItem.submenu = sp
        m.addItem(spItem)
        let bk = NSMenu()
        for k in BoostKey.allCases {
            let i = NSMenuItem(title: k.title, action: #selector(setBoost(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = k.rawValue; i.state = Prefs.boostKey == k ? .on : .off
            bk.addItem(i)
        }
        let bkItem = NSMenuItem(title: "Клавиша ускорения", action: nil, keyEquivalent: "")
        bkItem.submenu = bk
        m.addItem(bkItem)
        let bf = NSMenu()
        for v in [1.25, 1.5, 2.0, 3.0, 4.0, 5.0, 8.0, 10.0] {
            let i = NSMenuItem(title: "×\(String(format: "%g", v))", action: #selector(setBoostFactor(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = v; i.state = Prefs.boostFactor == v ? .on : .off
            bf.addItem(i)
        }
        let bfItem = NSMenuItem(title: "Во сколько раз ускорять", action: nil, keyEquivalent: "")
        bfItem.submenu = bf
        m.addItem(bfItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    @objc func toggleEnabled() { Prefs.enabled.toggle(); rebuildMenu() }
    @objc func toggleInvert() { Prefs.inverted.toggle(); rebuildMenu() }
    @objc func toggleDialog() { Prefs.dialogCursor.toggle(); rebuildMenu() }
    @objc func setBoost(_ s: NSMenuItem) {
        Prefs.boostKey = BoostKey(rawValue: s.representedObject as? String ?? "") ?? .shift; rebuildMenu()
    }
    @objc func setBoostFactor(_ s: NSMenuItem) { Prefs.boostFactor = s.representedObject as? Double ?? 2; rebuildMenu() }
    @objc func setSpeed(_ s: NSMenuItem) { Prefs.speed = s.representedObject as? Double ?? 1; rebuildMenu() }
    func applicationWillTerminate(_ n: Notification) { scroller.reset() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

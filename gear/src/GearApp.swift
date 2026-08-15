// GearApp.swift
// A floating "speedometer" model switcher for Claude Code.
//
// Hand-coded AppKit app (no Xcode, no SwiftUI). It shows an always-on-top
// FLOATING WINDOW containing a car-speedometer-style gauge. Local models
// occupy the LEFT half of the arc sweep, provider (cloud) models the RIGHT
// half. A red needle points at the active model; clicking a tick/label sends a
// /switch to the router (on a background queue, since a local switch can block
// up to ~600s while the server boots / a model downloads).
//
// Talks to a local router proxy over HTTP on 127.0.0.1:<router_port>.
//
// Build:  swiftc -O GearApp.swift -o Gear -framework AppKit -framework Foundation
//         -target arm64-apple-macosx13

import AppKit
import Foundation

// MARK: - Router contract (Codable)  [UNCHANGED — reused as-is]

/// GET /state response.
struct RouterState: Codable {
    struct Active: Codable {
        let kind: String        // "local" | "provider"
        let model_id: String
    }
    struct LocalModel: Codable {
        let flag: String
        let id: String
        let name: String
        let size: String
        let desc: String
        let cached: Bool
    }
    struct ProviderModel: Codable {
        let id: String
        let name: String
        let tier: String
    }
    struct Catalog: Codable {
        let local: [LocalModel]
        let provider: [ProviderModel]
        // Router may expose a subset of `local` where cached==true. Optional so
        // an older router (without this field) still decodes cleanly.
        let local_installed: [LocalModel]?
    }
    /// One attached Claude Code session (display-only). All optional-tolerant so
    /// an older router that omits `sessions` still decodes.
    struct SessionInfo: Codable {
        let session_id: String?
        let cwd: String?
        let last_seen: Double?
        let age_secs: Int?
    }
    let active: Active
    let vllm_up: Bool
    let vllm_model: String?
    let catalog: Catalog
    // Attached sessions strip; optional so old router still decodes.
    let sessions: [SessionInfo]?
}

/// POST /switch request + response.
struct SwitchRequest: Codable {
    let kind: String
    let model_id: String
}
struct SwitchResponse: Codable {
    let ok: Bool
    let ready: Bool?
}

// MARK: - A flattened "slot" on the gauge

/// One selectable model position on the gauge. `isLocal` decides the half.
struct Slot {
    let kind: String            // "local" | "provider"
    let modelID: String
    let name: String
    let isLocal: Bool
    let cached: Bool            // meaningful only for local models
    var angle: CGFloat = 0      // radians, standard math convention (0 = +x, CCW+)
}

// MARK: - Router client  [UNCHANGED — reused as-is]

/// Thin URLSession wrapper. All completion handlers hop back to the main queue
/// so the caller can touch UI directly.
final class RouterClient {
    let port: Int
    private let session: URLSession

    init(port: Int) {
        self.port = port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        // A local /switch may block ~600s (server boot / model download).
        cfg.timeoutIntervalForResource = 650
        self.session = URLSession(configuration: cfg)
    }

    private var base: String { "http://127.0.0.1:\(port)" }

    /// GET /state. `completion(nil)` means the router was unreachable / bad reply.
    func fetchState(_ completion: @escaping (RouterState?) -> Void) {
        guard let url = URL(string: base + "/state") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let task = session.dataTask(with: url) { data, resp, _ in
            var parsed: RouterState? = nil
            if let data = data,
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                parsed = try? JSONDecoder().decode(RouterState.self, from: data)
            }
            DispatchQueue.main.async { completion(parsed) }
        }
        task.resume()
    }

    /// POST /switch. Runs the (possibly very slow) request; hands back the reply.
    func switchModel(kind: String, modelID: String,
                     completion: @escaping (SwitchResponse?) -> Void) {
        guard let url = URL(string: base + "/switch") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(SwitchRequest(kind: kind, model_id: modelID))
        let task = session.dataTask(with: req) { data, resp, _ in
            var parsed: SwitchResponse? = nil
            if let data = data,
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                parsed = try? JSONDecoder().decode(SwitchResponse.self, from: data)
            }
            DispatchQueue.main.async { completion(parsed) }
        }
        task.resume()
    }
}

// MARK: - The semicircle gauge view

/// Clean 180 degree speedometer gauge (NO model text on the arc -- two
/// dropdowns above handle model names now).
///
/// ============================ LAYOUT ============================
///
///   * A 180 degree arc across the top of the view. LEFT half = LOCAL (blue),
///     RIGHT half = PROVIDER (red). The words "LOCAL" / "PROVIDER" sit as
///     arc labels near each end.
///   * Minimal ticks: one small unlabeled tick per model slot position,
///     distributed evenly (locals over the left half, providers over the
///     right half).
///   * A NEEDLE from the hub points at the ACTIVE model's angle.
///   * A BIG glowing center readout = active model short name + kind, in the
///     active side's color. This is the centerpiece.
///   * A tiny dim monospace SESSION STRIP at the very bottom.
///
/// The class keeps the name `SpeedometerView` and the same public surface
/// (slots, layoutAngles, active*, routerOnline, switchInFlight, inFlight*,
/// sessionTags, syncNeedleToActive, sweepNeedle, onSelect) so AppDelegate's
/// existing wiring is unchanged.
/// =======================================================================
final class SpeedometerView: NSView {

    // ---- Layout constants ---------------------------------------------------
    private let bezelInset: CGFloat = 14      // gap from view edge to dark bezel
    private let topReserve: CGFloat = 8       // breathing room under the dropdown row (dropdowns are siblings above)
    private let sessionStripH: CGFloat = 22   // reserved band at the very bottom
    private let tickInset: CGFloat = 10       // tick length inward from the arc
    private let labelInset: CGFloat = 26      // LOCAL/PROVIDER label offset inward from arc

    // ---- Palette (dark board; blue local / red provider) --------------------
    private let colBG      = NSColor(calibratedRed: 0x14/255.0, green: 0x14/255.0, blue: 0x1E/255.0, alpha: 1)
    private let colBlue    = NSColor(calibratedRed: 0x35/255.0, green: 0x9C/255.0, blue: 0xF7/255.0, alpha: 1)
    private let colRed     = NSColor(calibratedRed: 0xF7/255.0, green: 0x4B/255.0, blue: 0x5C/255.0, alpha: 1)
    private let colWhite   = NSColor.white
    private let colDim     = NSColor(white: 1.0, alpha: 0.55)
    private let colDimmer  = NSColor(white: 1.0, alpha: 0.32)
    private let colGrey    = NSColor(white: 0.42, alpha: 1)
    private let colNeedle  = NSColor(calibratedRed: 0xFF/255.0, green: 0xE1/255.0, blue: 0x66/255.0, alpha: 1)

    // ---- Public state (surface used by AppDelegate) -------------------------
    var slots: [Slot] = [] { didSet { needsDisplay = true } }
    var activeKind: String = ""
    var activeModelID: String = ""
    var activeName: String = ""
    var routerOnline: Bool = true { didSet { needsDisplay = true } }
    var switchInFlight: Bool = false { didSet { updateSpinner(); needsDisplay = true } }
    var inFlightName: String = ""
    var inFlightModelID: String = ""
    /// Session info (basename, age) for the bottom session strip.
    var sessionTags: [(name: String, age: String)] = [] { didSet { needsDisplay = true } }

    /// Retained for API compatibility (dropdowns are the click targets now).
    var onSelect: ((Slot) -> Void)?

    // ---- Private drawing state ----------------------------------------------
    /// Needle angle in radians (math convention: 0 = +x pointing right, CCW+).
    /// The arc runs from angle 0 (rightmost, PROVIDER end) to pi (leftmost,
    /// LOCAL end). We animate toward the active slot's angle.
    private var needleAngle: CGFloat = .pi / 2
    private var animTimer: Timer?
    private var spinner: NSProgressIndicator?

    override var isFlipped: Bool { false }   // math-convention (y up) coords

    // MARK: Gauge geometry

    /// Dark content region (inside the bezel), minus the bottom session strip.
    private var gaugeRect: NSRect {
        let inner = bounds.insetBy(dx: bezelInset, dy: bezelInset)
        return NSRect(x: inner.minX, y: inner.minY + sessionStripH,
                      width: inner.width,
                      height: inner.height - sessionStripH - topReserve)
    }
    /// Hub sits on the horizontal baseline, centered, near the bottom of the
    /// gauge region so a 180 degree arc sweeps up over it.
    private var hubCenter: CGPoint {
        CGPoint(x: gaugeRect.midX, y: gaugeRect.minY + 12)
    }
    /// Arc radius fits inside the gauge region (bounded by width and height).
    private var arcRadius: CGFloat {
        min(gaugeRect.width / 2 - 16, gaugeRect.height - 24)
    }

    // MARK: Angle mapping

    /// Assign each slot an angle across the semicircle: LOCAL slots spread over
    /// the LEFT half (pi/2 ... pi), PROVIDER slots over the RIGHT half
    /// (0 ... pi/2). Angles are evenly distributed and centered within each half.
    func layoutAngles() {
        let locals = slots.enumerated().filter { $0.element.isLocal }.map { $0.offset }
        let providers = slots.enumerated().filter { !$0.element.isLocal }.map { $0.offset }

        // LEFT half: from just past vertical (pi/2) toward pi (leftmost).
        distribute(indices: locals, from: .pi / 2 + 0.12, to: .pi - 0.12)
        // RIGHT half: from 0 (rightmost) toward just before vertical (pi/2).
        distribute(indices: providers, from: 0.12, to: .pi / 2 - 0.12)
    }

    private func distribute(indices: [Int], from a: CGFloat, to b: CGFloat) {
        guard !indices.isEmpty else { return }
        if indices.count == 1 {
            slots[indices[0]].angle = (a + b) / 2
            return
        }
        let step = (b - a) / CGFloat(indices.count - 1)
        for (n, idx) in indices.enumerated() {
            slots[idx].angle = a + step * CGFloat(n)
        }
    }

    private func activeAngle() -> CGFloat {
        if let s = slots.first(where: { $0.kind == activeKind && $0.modelID == activeModelID }) {
            return s.angle
        }
        // Default: point straight up.
        return .pi / 2
    }

    // MARK: Public API expected by AppDelegate

    func syncNeedleToActive() { animateNeedle(to: activeAngle()) }

    func sweepNeedle(to slot: Slot) {
        if let s = slots.first(where: { $0.modelID == slot.modelID }) {
            animateNeedle(to: s.angle)
        }
    }

    // MARK: Needle animation (ease-out)

    private func norm(_ a: CGFloat) -> CGFloat {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x <= -(.pi) { x += 2 * .pi }
        if x > .pi { x -= 2 * .pi }
        return x
    }
    private func angularDelta(from: CGFloat, to: CGFloat) -> CGFloat { norm(to - from) }

    private func animateNeedle(to target: CGFloat) {
        animTimer?.invalidate()
        let start = needleAngle
        let delta = angularDelta(from: start, to: target)
        let duration: TimeInterval = 0.40
        let startTime = Date().timeIntervalSinceReferenceDate
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let elapsed = Date().timeIntervalSinceReferenceDate - startTime
            let frac = min(1.0, elapsed / duration)
            let eased = 1 - pow(1 - CGFloat(frac), 3)
            self.needleAngle = start + delta * eased
            self.needsDisplay = true
            if frac >= 1.0 { t.invalidate(); self.needleAngle = target }
        }
    }

    // MARK: Spinner (shown while a switch is in flight)

    private func updateSpinner() {
        if switchInFlight {
            if spinner == nil {
                let s = NSProgressIndicator()
                s.style = .spinning
                s.controlSize = .small
                s.isIndeterminate = true
                s.appearance = NSAppearance(named: .darkAqua)
                s.translatesAutoresizingMaskIntoConstraints = true
                addSubview(s)
                spinner = s
            }
            spinner?.isHidden = false
            spinner?.startAnimation(nil)
        } else {
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
        }
    }

    /// Position the spinner just above the center readout.
    private func positionSpinner() {
        guard let s = spinner, switchInFlight else { return }
        let c = hubCenter
        s.frame = NSRect(x: c.x - 8, y: c.y + arcRadius * 0.42, width: 16, height: 16)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dimmed = !routerOnline

        // Dark rounded bezel.
        let bezel = NSBezierPath(roundedRect: bounds.insetBy(dx: bezelInset, dy: bezelInset),
                                 xRadius: 20, yRadius: 20)
        colBG.setFill(); bezel.fill()

        drawArc(dimmed: dimmed)
        drawTicks(dimmed: dimmed)
        drawArcLabels(dimmed: dimmed)
        drawNeedle(dimmed: dimmed)
        drawCenterReadout(dimmed: dimmed)
        positionSpinner()
    }

    /// The 180 degree arc: left half blue (LOCAL), right half red (PROVIDER).
    private func drawArc(dimmed: Bool) {
        let c = hubCenter
        let r = arcRadius
        let lw: CGFloat = 6
        let blue = dimmed ? colGrey : colBlue
        let red  = dimmed ? colGrey : colRed

        // Right half (PROVIDER): 0 ... 90 degrees.
        let rightArc = NSBezierPath()
        rightArc.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 90)
        rightArc.lineWidth = lw; rightArc.lineCapStyle = .round
        red.setStroke(); rightArc.stroke()

        // Left half (LOCAL): 90 ... 180 degrees.
        let leftArc = NSBezierPath()
        leftArc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 180)
        leftArc.lineWidth = lw; leftArc.lineCapStyle = .round
        blue.setStroke(); leftArc.stroke()
    }

    /// One small unlabeled tick per model slot, at its assigned angle.
    private func drawTicks(dimmed: Bool) {
        let c = hubCenter
        let r = arcRadius
        for slot in slots {
            let a = slot.angle
            let outer = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            let inner = CGPoint(x: c.x + (r - tickInset) * cos(a), y: c.y + (r - tickInset) * sin(a))
            let tick = NSBezierPath()
            tick.move(to: inner); tick.line(to: outer)
            tick.lineWidth = 2; tick.lineCapStyle = .round
            let col = dimmed ? colGrey : (slot.isLocal ? colBlue : colRed)
            col.withAlphaComponent(0.9).setStroke()
            tick.stroke()
        }
    }

    /// "LOCAL" near the left end, "PROVIDER" near the right end, both CURVED to
    /// follow the arc.
    private func drawArcLabels(dimmed: Bool) {
        let font = monoFont(11, .bold)
        let r = arcRadius - labelInset
        // LOCAL centered at ~160 degrees (left/blue half).
        drawCurvedText("LOCAL", centerAngle: CGFloat(160) * .pi / 180, radius: r,
                       color: dimmed ? colDim : colBlue, font: font)
        // PROVIDER centered at ~20 degrees (right/red half).
        drawCurvedText("PROVIDER", centerAngle: CGFloat(20) * .pi / 180, radius: r,
                       color: dimmed ? colDim : colRed, font: font)
    }

    /// Draw `text` along the upper arc so it curves with the gauge and reads
    /// left-to-right, upright. Per-glyph placement: each character gets its own
    /// angle (stepped across a span centered on `centerAngle`), is positioned on
    /// `radius`, and is rotated so its baseline is tangent to the circle
    /// (rotation = glyphAngle - 90 degrees for the upper arc). Characters are
    /// laid out from the highest angle (leftmost) down to the lowest, matching
    /// left-to-right reading order across the top of the circle.
    private func drawCurvedText(_ text: String, centerAngle: CGFloat, radius: CGFloat,
                                color: NSColor, font: NSFont) {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        let c = hubCenter
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        // Angular spacing per glyph = advance width / radius (arc-length -> angle).
        // Use each glyph's own width so a monospace string stays evenly spaced.
        var widths: [CGFloat] = []
        var total: CGFloat = 0
        let kern: CGFloat = 1
        for ch in chars {
            let w = NSAttributedString(string: String(ch), attributes: attrs).size().width + kern
            widths.append(w)
            total += w
        }
        let totalAngle = total / radius
        // Start at the leftmost (highest angle) edge of the span and walk down.
        var angle = centerAngle + totalAngle / 2

        for (i, ch) in chars.enumerated() {
            let halfW = widths[i] / 2
            let halfA = halfW / radius
            let glyphAngle = angle - halfA          // center this glyph
            let p = CGPoint(x: c.x + radius * cos(glyphAngle),
                            y: c.y + radius * sin(glyphAngle))
            let s = NSAttributedString(string: String(ch), attributes: attrs)
            let sz = s.size()

            NSGraphicsContext.saveGraphicsState()
            let xform = NSAffineTransform()
            xform.translateX(by: p.x, yBy: p.y)
            // Upper arc: tangent (left->right) rotation = glyphAngle - 90 degrees.
            xform.rotate(byRadians: glyphAngle - .pi / 2)
            xform.concat()
            // Draw the single glyph centered on the (now translated/rotated) origin.
            s.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
            NSGraphicsContext.restoreGraphicsState()

            angle -= (widths[i] / radius)           // advance to next glyph slot
        }
    }

    /// Yellow needle from the hub pointing at the current (animated) angle.
    private func drawNeedle(dimmed: Bool) {
        let c = hubCenter
        let len = arcRadius - 14
        let tip = CGPoint(x: c.x + len * cos(needleAngle), y: c.y + len * sin(needleAngle))
        let tail = CGPoint(x: c.x - 14 * cos(needleAngle), y: c.y - 14 * sin(needleAngle))

        let needleCol = dimmed ? colGrey : colNeedle
        let line = NSBezierPath(); line.move(to: tail); line.line(to: tip)
        line.lineWidth = 3; line.lineCapStyle = .round

        NSGraphicsContext.saveGraphicsState()
        if !dimmed {
            let glow = NSShadow()
            glow.shadowColor = colNeedle.withAlphaComponent(0.85)
            glow.shadowBlurRadius = 8; glow.shadowOffset = .zero
            glow.set()
        }
        needleCol.setStroke(); line.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Hub cap.
        let hubR: CGFloat = 8
        let hub = NSBezierPath(ovalIn: NSRect(x: c.x - hubR, y: c.y - hubR, width: hubR*2, height: hubR*2))
        needleCol.setFill(); hub.fill()
        let inner = NSBezierPath(ovalIn: NSRect(x: c.x - hubR*0.4, y: c.y - hubR*0.4,
                                                width: hubR*0.8, height: hubR*0.8))
        colBG.setFill(); inner.fill()
    }

    /// BIG glowing center readout: active model short name + kind, in the
    /// active side's color. The centerpiece.
    private func drawCenterReadout(dimmed: Bool) {
        let c = hubCenter
        let baseY = c.y + arcRadius * 0.30   // sit above the hub, inside the arc

        let activeIsLocal = (activeKind == "local")
        let sideCol: NSColor = dimmed ? colDim : (activeIsLocal ? colBlue : colRed)

        let name: String
        let kindLabel: String
        if dimmed {
            name = "OFFLINE"; kindLabel = "router unreachable"
        } else if switchInFlight {
            name = inFlightName.isEmpty ? "..." : inFlightName
            kindLabel = "switching..."
        } else {
            name = activeName.isEmpty ? "--" : activeName
            kindLabel = activeKind.isEmpty ? "" : activeKind.uppercased()
        }

        let maxW = gaugeRect.width - 40
        let bigFont = monoFont(20, .heavy)
        let shownName = ellipsized(name, font: bigFont, maxWidth: maxW)

        // Glow pass then crisp pass.
        NSGraphicsContext.saveGraphicsState()
        if !dimmed {
            let glow = NSShadow()
            glow.shadowColor = sideCol.withAlphaComponent(0.7)
            glow.shadowBlurRadius = 10; glow.shadowOffset = .zero
            glow.set()
        }
        drawText(shownName, at: CGPoint(x: c.x, y: baseY), font: bigFont,
                 color: dimmed ? colDim : colWhite, centered: true)
        NSGraphicsContext.restoreGraphicsState()
        drawText(shownName, at: CGPoint(x: c.x, y: baseY), font: bigFont,
                 color: dimmed ? colDim : colWhite, centered: true)

        // Kind sub-label, in the active side's color.
        if !kindLabel.isEmpty {
            drawText(kindLabel, at: CGPoint(x: c.x, y: baseY - 20),
                     font: monoFont(10, .semibold), color: sideCol, centered: true, kern: 1.5)
        }
    }

    // MARK: Small draw helpers

    private func monoFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func ellipsized(_ s: String, font: NSFont, maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if NSAttributedString(string: s, attributes: attrs).size().width <= maxWidth { return s }
        var t = s
        while t.count > 1 {
            t = String(t.dropLast())
            let candidate = t + "\u{2026}"
            if NSAttributedString(string: candidate, attributes: attrs).size().width <= maxWidth {
                return candidate
            }
        }
        return "\u{2026}"
    }

    private func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor,
                          centered: Bool, kern: CGFloat = 0) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attrs[.kern] = kern }
        let str = NSAttributedString(string: s, attributes: attrs)
        let size = str.size()
        let origin = centered
            ? CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
            : p
        str.draw(at: origin)
    }
}
// MARK: - Window (floating, movable-by-background) delegate

/// Terminates the app when the floating window is closed (rather than leaving a
/// headless polling process running forever).
final class GearWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var windowDelegate: GearWindowDelegate!
    private var container: NSView!            // holds gauge + the two popups as siblings
    private var gauge: SpeedometerView!
    private var localPopup: NSPopUpButton!    // LEFT dropdown: cached-local models
    private var cloudPopup: NSPopUpButton!    // RIGHT dropdown: provider models
    private var sessionPopup: NSPopUpButton!  // BOTTOM dropdown: attached sessions (display-only)
    private var client: RouterClient!
    private var pollTimer: Timer?
    private var lastState: RouterState?

    /// Each menu item stores its Slot in `representedObject`; these arrays keep
    /// the slots per popup so a selection maps straight back to a switch.
    private var localSlots: [Slot] = []
    private var cloudSlots: [Slot] = []

    /// Attached sessions (basename + short age), fed to the Sessions dropdown.
    private var sessionTags: [(name: String, age: String)] = []

    // Window / layout metrics.
    private let winW: CGFloat = 480
    private let winH: CGFloat = 380
    private let dropRowH: CGFloat = 34       // height of a popup
    // Push the dropdown row DOWN so it sits just above the arc top (~10px gap).
    // With a full-height gauge, the arc top is at window y~258; a 34-tall row at
    // y~262 leaves a small gap above the arc and stays clear of the curved
    // LOCAL/PROVIDER labels (which sit near the arc ends, not the top center).
    private let dropTopPad: CGFloat = 46     // gap below the top window edge
    private let dropSideInset: CGFloat = 18
    private let dropGap: CGFloat = 12

    // MARK: Config

    /// Locate config.json relative to this executable so the binary is portable
    /// (no hardcoded absolute path). Layout: <repo>/gear/build/Gear[.app/...],
    /// config at <repo>/config/config.json. Walk up from the executable until a
    /// sibling `config/config.json` is found. `GEAR_CONFIG` env overrides.
    private func configPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["GEAR_CONFIG"], !override.isEmpty {
            return override
        }
        let fm = FileManager.default
        // Start at the executable's directory and climb toward the repo root.
        var dir = URL(fileURLWithPath: CommandLine.arguments.first
                        ?? Bundle.main.bundlePath).deletingLastPathComponent()
        for _ in 0..<6 {   // build/ -> gear/ -> repo/ is 2 hops; extra headroom for .app
            let candidate = dir.appendingPathComponent("config/config.json").path
            if fm.fileExists(atPath: candidate) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Read router_port from config.json; fall back to 9000.
    private func routerPort() -> Int {
        guard let path = configPath(),
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["router_port"] as? Int
        else { return 9000 }
        return port
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular activation policy — accessory made the (now abandoned) status
        // item invisible on this OS; a real floating window needs .regular.
        NSApp.setActivationPolicy(.regular)
        client = RouterClient(port: routerPort())

        let rect = NSRect(x: 0, y: 0, width: winW, height: winH)

        // Container content view: two dropdowns pinned across the TOP, the gauge
        // filling the rest below them (siblings — cleaner than overlaying popups
        // on the custom-drawing gauge view).
        container = NSView(frame: rect)
        container.wantsLayer = true

        // Dropdown row geometry (top of the window).
        let rowY = winH - dropTopPad - dropRowH
        let halfW = (winW - dropSideInset * 2 - dropGap) / 2
        let leftFrame  = NSRect(x: dropSideInset, y: rowY, width: halfW, height: dropRowH)
        let rightFrame = NSRect(x: dropSideInset + halfW + dropGap, y: rowY, width: halfW, height: dropRowH)

        localPopup = makePopup(frame: leftFrame, action: #selector(localPopupChanged))
        cloudPopup = makePopup(frame: rightFrame, action: #selector(cloudPopupChanged))
        container.addSubview(localPopup)
        container.addSubview(cloudPopup)

        // Gauge fills the FULL window so its arc geometry is stable; the
        // dropdowns are overlaid (z-above) in the empty dark band above the arc.
        let gaugeFrame = NSRect(x: 0, y: 0, width: winW, height: winH)
        gauge = SpeedometerView(frame: gaugeFrame)
        gauge.autoresizingMask = [.width, .height]
        gauge.onSelect = { [weak self] slot in self?.performSwitch(slot) }
        container.addSubview(gauge, positioned: .below, relativeTo: localPopup)

        // Bottom band: full-width Sessions dropdown (display-only) where the old
        // drawn session strip used to be. Anchored to the BOTTOM on resize.
        let sessRowH = dropRowH - 6
        let sessFrame = NSRect(x: dropSideInset, y: 8,
                               width: winW - dropSideInset * 2, height: sessRowH)
        sessionPopup = makePopup(frame: sessFrame, action: #selector(sessionPopupChanged))
        sessionPopup.autoresizingMask = [.maxYMargin]   // stick to bottom
        container.addSubview(sessionPopup)

        // ---- Proven floating-window pattern (renders correctly on this Mac) ----
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Gear"
        // Sci-fi dark chrome: transparent title bar, dark appearance, hidden
        // title text so the gauge bleeds under the bar (fullSizeContentView).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedRed: 0x14/255.0, green: 0x14/255.0, blue: 0x1E/255.0, alpha: 1)
        window.level = .floating                  // stays above normal windows
        window.isMovableByWindowBackground = true // drag anywhere on the body
        window.center()
        window.contentView = container
        windowDelegate = GearWindowDelegate()
        window.delegate = windowDelegate
        // Right-click the gauge for a Refresh / Quit menu.
        gauge.menu = makeContextMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Kick off polling.
        refreshState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    // MARK: Context menu (Refresh / Quit)

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func menuRefresh() { refreshState() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Dropdowns (Local / Cloud) — selection triggers an immediate switch

    /// Build a dark, native pull-down popup wired to `action` on self.
    private func makePopup(frame: NSRect, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: frame, pullsDown: false)
        p.appearance = NSAppearance(named: .darkAqua)
        p.target = self
        p.action = action
        p.autoenablesItems = false
        p.translatesAutoresizingMaskIntoConstraints = true
        // Keep the two popups anchored to the top-left/right on resize.
        p.autoresizingMask = [.minYMargin]
        return p
    }

    /// Rebuild both popup menus from the current slot lists, then select the
    /// item that matches the active model in its column.
    private func rebuildPopups(activeKind: String, activeModelID: String, online: Bool) {
        rebuild(popup: localPopup, header: "Local", slots: localSlots,
                activeKind: activeKind, activeModelID: activeModelID, online: online)
        rebuild(popup: cloudPopup, header: "Cloud", slots: cloudSlots,
                activeKind: activeKind, activeModelID: activeModelID, online: online)
    }

    private func rebuild(popup: NSPopUpButton, header: String, slots: [Slot],
                         activeKind: String, activeModelID: String, online: Bool) {
        popup.removeAllItems()
        popup.isEnabled = online && !slots.isEmpty

        // First item = the column header (a hint title, disabled, not a model).
        let head = NSMenuItem(title: "\(header) \u{25BE}", action: nil, keyEquivalent: "")
        head.isEnabled = false
        popup.menu?.addItem(head)

        var activeIndex: Int? = nil
        for slot in slots {
            let item = NSMenuItem(title: slot.name, action: nil, keyEquivalent: "")
            item.representedObject = slot   // Slot is a struct; boxed on assignment
            item.isEnabled = true
            popup.menu?.addItem(item)
            if slot.kind == activeKind && slot.modelID == activeModelID {
                activeIndex = popup.numberOfItems - 1
            }
        }

        // Reflect active selection in the matching column; otherwise show the
        // header (index 0) so this column reads as "no active selection here".
        if let idx = activeIndex {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func localPopupChanged(_ sender: NSPopUpButton) { popupChanged(sender) }
    @objc private func cloudPopupChanged(_ sender: NSPopUpButton) { popupChanged(sender) }

    /// Sessions dropdown is display-only: snap back to the header so a pick
    /// never sticks (the router is single-target — no per-session control).
    @objc private func sessionPopupChanged(_ sender: NSPopUpButton) {
        sender.selectItem(at: 0)
    }

    /// Rebuild the Sessions dropdown from `sessionTags`. Header shows the count;
    /// each row is "basename · age". Display-only — no representedObject.
    private func rebuildSessions(online: Bool) {
        sessionPopup.removeAllItems()
        sessionPopup.isEnabled = online

        let head = NSMenuItem(title: "Sessions \u{25BE} (\(sessionTags.count))",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        sessionPopup.menu?.addItem(head)

        if sessionTags.isEmpty {
            let none = NSMenuItem(title: "no sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sessionPopup.menu?.addItem(none)
        } else {
            for s in sessionTags {
                let label = s.age.isEmpty ? s.name : "\(s.name) · \(s.age)"
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false   // display-only
                sessionPopup.menu?.addItem(item)
            }
        }
        sessionPopup.selectItem(at: 0)   // always show the header/count
    }

    /// A dropdown selection -> immediate performSwitch (no confirm step).
    private func popupChanged(_ sender: NSPopUpButton) {
        guard gauge.routerOnline, !gauge.switchInFlight else {
            // Re-sync so the popup doesn't visually drift from the true state.
            resyncPopups()
            return
        }
        guard let item = sender.selectedItem,
              let slot = item.representedObject as? Slot else { return }
        // Ignore re-selecting the already-active model.
        if slot.kind == gauge.activeKind && slot.modelID == gauge.activeModelID {
            return
        }
        performSwitch(slot)
    }

    /// Reselect the active item in each popup from the gauge's current state.
    private func resyncPopups() {
        rebuildPopups(activeKind: gauge.activeKind, activeModelID: gauge.activeModelID,
                      online: gauge.routerOnline)
    }

    // MARK: State sync

    private func refreshState() {
        client.fetchState { [weak self] state in
            guard let self = self else { return }
            if let state = state {
                self.lastState = state
                self.applyState(state)
                self.gauge.routerOnline = true
            } else {
                self.gauge.routerOnline = false
                self.localPopup.isEnabled = false
                self.cloudPopup.isEnabled = false
                self.sessionPopup.isEnabled = false
            }
        }
    }

    /// Rebuild the gauge's slots + active markers from a fresh /state.
    /// [Logic preserved from the original applyState — local first, then provider.]
    private func applyState(_ state: RouterState) {
        var slots: [Slot] = []

        // LOCAL FILTER: prefer router's `local_installed` (cached subset) if
        // present & non-empty; else filter `local` by cached==true; else fall
        // back to the full local list so the gauge is never empty.
        let localModels: [RouterState.LocalModel]
        if let installed = state.catalog.local_installed, !installed.isEmpty {
            localModels = installed
        } else {
            let cached = state.catalog.local.filter { $0.cached }
            localModels = cached.isEmpty ? state.catalog.local : cached
        }

        for m in localModels {
            slots.append(Slot(kind: "local", modelID: m.id, name: m.name,
                              isLocal: true, cached: m.cached))
        }
        for m in state.catalog.provider {
            slots.append(Slot(kind: "provider", modelID: m.id, name: m.name,
                              isLocal: false, cached: false))
        }

        gauge.slots = slots
        gauge.layoutAngles()
        gauge.activeKind = state.active.kind
        gauge.activeModelID = state.active.model_id

        // Keep per-column slot lists for the dropdowns.
        localSlots = slots.filter { $0.isLocal }
        cloudSlots = slots.filter { !$0.isLocal }

        // Resolve the active model's display name from the catalog.
        var activeName = state.active.model_id
        if state.active.kind == "local",
           let m = state.catalog.local.first(where: { $0.id == state.active.model_id }) {
            activeName = m.name
        } else if state.active.kind == "provider",
                  let m = state.catalog.provider.first(where: { $0.id == state.active.model_id }) {
            activeName = m.name
        }
        gauge.activeName = activeName

        // Attached sessions (display only): basename of cwd + short age.
        sessionTags = (state.sessions ?? []).map { s in
            let base = (s.cwd as NSString?)?.lastPathComponent ?? "?"
            let age: String
            if let a = s.age_secs { age = "\(a)s" } else { age = "" }
            return (name: base.isEmpty ? "?" : base, age: age)
        }

        // Animate the needle to point at the active slot (unless switching).
        if !gauge.switchInFlight {
            gauge.syncNeedleToActive()
        }
        gauge.needsDisplay = true

        // Rebuild + re-select the dropdowns to reflect the fresh active state.
        rebuildPopups(activeKind: state.active.kind, activeModelID: state.active.model_id,
                      online: true)
        rebuildSessions(online: true)
    }

    // MARK: Switching  [Logic preserved]

    private func performSwitch(_ slot: Slot) {
        // Show the loading state immediately, sweep the needle to the target,
        // and dim the other ticks. The POST runs off the main thread.
        gauge.switchInFlight = true
        gauge.inFlightName = slot.name
        gauge.inFlightModelID = slot.modelID
        gauge.sweepNeedle(to: slot)

        client.switchModel(kind: slot.kind, modelID: slot.modelID) { [weak self] resp in
            guard let self = self else { return }
            self.gauge.switchInFlight = false
            if resp == nil {
                // Request failed / timed out; mark offline-ish but keep polling.
                self.gauge.routerOnline = false
            }
            self.refreshState()
        }
    }
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // set before run() so the window registers reliably
let delegate = AppDelegate()
app.delegate = delegate
app.run()

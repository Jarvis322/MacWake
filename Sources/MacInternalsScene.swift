import SwiftUI
import SceneKit

import IOKit

/// The parts of the cut-away Mac a click can focus on.
enum MacPart: String, CaseIterable {
    case battery, soc, ssd, port, fan, display
}

/// Enclosure colours Apple has shipped MacBooks in. macOS records the model but not the
/// colour, so the viewer picks theirs.
enum MacFinish: String, CaseIterable {
    case skyBlue, midnight, starlight, silver, spaceGray, spaceBlack
    // iMac (24-inch) colours.
    case blue, green, pink, yellow, orange, purple

    var color: NSColor {
        switch self {
        case .skyBlue: return NSColor(calibratedRed: 0.66, green: 0.75, blue: 0.84, alpha: 1)
        case .midnight: return NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.25, alpha: 1)
        case .starlight: return NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.77, alpha: 1)
        case .silver: return NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.87, alpha: 1)
        case .spaceGray: return NSColor(calibratedRed: 0.56, green: 0.56, blue: 0.57, alpha: 1)
        case .spaceBlack: return NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.42, green: 0.6, blue: 0.82, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.48, green: 0.7, blue: 0.56, alpha: 1)
        case .pink: return NSColor(calibratedRed: 0.9, green: 0.6, blue: 0.62, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.42, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.95, green: 0.6, blue: 0.42, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.82, alpha: 1)
        }
    }

    var nameKey: String { "FINISH_" + rawValue.uppercased() }
}

/// What the 3D model should look like for this Mac, derived from the device tree's
/// marketing name, e.g. "MacBook Air (13-inch, M4, 2025)". Dimensions are Apple's
/// published tech-spec figures, in centimetres.
struct MacChassisProfile: Equatable {
    enum Family: Equatable { case air, pro, mini, studio, iMac }

    struct Panel: Equatable {
        let inches: Double
        let pixelsWide: Double
        let pixelsHigh: Double

        /// Active area from the diagonal and the native resolution's aspect.
        var widthCm: Double { inches * 2.54 * pixelsWide / (pixelsWide * pixelsWide + pixelsHigh * pixelsHigh).squareRoot() }
        var heightCm: Double { widthCm * pixelsHigh / pixelsWide }
    }

    let family: Family
    let productName: String
    let chip: String?
    let width: Double
    let depth: Double
    /// Closed thickness for laptops, body height for desktops.
    let height: Double
    let panel: Panel?
    let hasNotch: Bool
    let hasTouchBar: Bool

    init(productName: String, chip: String?) {
        self.productName = productName
        self.chip = chip
        let lower = productName.lowercased()
        let inches = productName.range(of: #"(\d+)(?:\.\d+)?-inch"#, options: .regularExpression)
            .flatMap { Int(productName[$0].prefix { $0.isNumber }) }
        let isM1 = productName.contains("M1") && !productName.contains("M1 Pro") && !productName.contains("M1 Max")
        let year = productName.range(of: #"20\d\d"#, options: .regularExpression).flatMap { Int(productName[$0]) }
        let thirteenThree = Panel(inches: 13.3, pixelsWide: 2560, pixelsHigh: 1600)

        if lower.hasPrefix("macbook pro") {
            family = .pro
            switch inches ?? 14 {
            case ...13:
                (width, depth, height) = (30.41, 21.24, 1.56)
                panel = thirteenThree; hasNotch = false; hasTouchBar = true
            case 14...15:
                (width, depth, height) = (31.26, 22.12, 1.55)
                panel = Panel(inches: 14.2, pixelsWide: 3024, pixelsHigh: 1964); hasNotch = true; hasTouchBar = false
            default:
                (width, depth, height) = (35.57, 24.81, 1.68)
                panel = Panel(inches: 16.2, pixelsWide: 3456, pixelsHigh: 2234); hasNotch = true; hasTouchBar = false
            }
        } else if lower.hasPrefix("macbook") {
            // Air, and any other MacBook line, which have all followed the Air's form.
            family = .air
            hasTouchBar = false
            if isM1 {
                (width, depth, height) = (30.41, 21.24, 1.3)
                panel = thirteenThree; hasNotch = false
            } else if (inches ?? 13) >= 15 {
                (width, depth, height) = (34.04, 23.76, 1.15)
                panel = Panel(inches: 15.3, pixelsWide: 2880, pixelsHigh: 1864); hasNotch = true
            } else {
                (width, depth, height) = (30.41, 21.5, 1.13)
                panel = Panel(inches: 13.6, pixelsWide: 2560, pixelsHigh: 1664); hasNotch = true
            }
        } else if lower.hasPrefix("mac mini") {
            family = .mini
            let compact = (year ?? 0) >= 2024 || chip?.contains("M4") == true || chip?.contains("M5") == true
            (width, depth, height) = compact ? (12.7, 12.7, 5.0) : (19.7, 19.7, 3.6)
            panel = nil; hasNotch = false; hasTouchBar = false
        } else if lower.hasPrefix("imac") {
            family = .iMac
            (width, depth, height) = (54.7, 14.7, 46.1)
            panel = Panel(inches: 23.5, pixelsWide: 4480, pixelsHigh: 2520); hasNotch = false; hasTouchBar = false
        } else {
            // Mac Studio, and the Mac Pro or anything unrecognised as the nearest box.
            family = .studio
            (width, depth, height) = (19.7, 19.7, 9.5)
            panel = nil; hasNotch = false; hasTouchBar = false
        }
    }

    var isLaptop: Bool { family == .air || family == .pro }

    /// Colours this family was sold in, the likeliest one first.
    var finishes: [MacFinish] {
        switch family {
        case .air:
            return chip?.contains("M4") == true || chip?.contains("M5") == true
                ? [.starlight, .skyBlue, .midnight, .silver]
                : [.starlight, .midnight, .spaceGray, .silver]
        case .pro: return [.spaceBlack, .spaceGray, .silver]
        case .mini, .studio: return [.silver]
        case .iMac: return [.blue, .green, .pink, .silver, .yellow, .orange, .purple]
        }
    }

    /// The saved colour if this model came in it, else the likeliest one.
    func finish(saved: String?) -> MacFinish {
        saved.flatMap(MacFinish.init(rawValue:)).flatMap { finishes.contains($0) ? $0 : nil } ?? finishes[0]
    }

    static let current: MacChassisProfile = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        func string(_ key: String) -> String? {
            guard entry != 0,
                  let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? Data
            else { return nil }
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return MacChassisProfile(productName: string("product-name") ?? "Mac",
                                 chip: string("product-soc-name"))
    }()
}

/// Live readings the 3D model mirrors. Kept to plain values so SwiftUI can diff it and only
/// touch the scene when something visible actually changed.
struct MacSceneReadings: Equatable {
    var level: Int
    var plugged: Bool
    /// Current is actually flowing into the battery (plugged, not held off, not full).
    var charging: Bool
    var cpuTemperature: Double?
    var ssdTemperature: Double?
    var hasFans: Bool
    var fanRPM: Double?
}

/// A stylised, open-top MacBook: battery cells across the front, logic board with the SoC
/// and SSD at the back, fan (or heat spreader) and a MagSafe port on the left wall. Every
/// part is driven by a real reading rather than decoration.
@MainActor
final class MacInternalsScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let model = SCNNode()
    private let lookTarget = SCNNode()
    let profile: MacChassisProfile
    private let deck = SCNNode()
    /// Everything inside the shell, squashed vertically so it fits the real thickness.
    private let guts = SCNNode()
    private let lid = SCNNode()
    private let screen = SCNNode()
    private var finishMaterials: [SCNMaterial] = []
    private var screenLevel: Int?
    /// Nodes on this bit are drawn but never take clicks, so the see-through keyboard deck
    /// doesn't stand between the pointer and the parts under it.
    private static let decorativeCategory = 1 << 2
    private var cellFills: [SCNNode] = []
    private let batteryGlow = SCNNode()
    private let socHeat = SCNNode()
    private let socRim = SCNNode()
    private let ssdRim = SCNNode()
    private let fanRotor = SCNNode()
    private let fanHousing = SCNNode()
    private let heatSpreader = SCNNode()
    private let portLED = SCNNode()
    private let cable = SCNNode()
    private let flow = SCNNode()
    private var lastReadings: MacSceneReadings?
    private var motion = true

    /// Where the camera parks when a part is focused: (eye, target).
    private static let focus: [MacPart: (SCNVector3, SCNVector3)] = [
        .battery: (SCNVector3(0, 19, 24), SCNVector3(0, 0, 3.5)),
        .soc: (SCNVector3(1, 10, 6), SCNVector3(0, 0.5, -4.5)),
        .ssd: (SCNVector3(8, 9, 6), SCNVector3(6.5, 0.5, -4.5)),
        .port: (SCNVector3(-26, 6.5, 2), SCNVector3(-15.5, 1.6, -5.2)),
        .fan: (SCNVector3(-8, 10, 6), SCNVector3(-8.5, 0.5, -4.5)),
        .display: (SCNVector3(0, 14, 52), SCNVector3(0, 7.5, -12)),
    ]

    /// Internals are laid out on a 31 × 22 grid; the whole body is stretched to the real
    /// footprint so a 15-inch Air or 16-inch Pro keeps its proportions.
    /// Top of the bottom case. True to life: an Air is ~1.1 cm thick, a Pro ~1.55 cm.
    private var shellTop: CGFloat { CGFloat(profile.height) * 0.88 }

    private var footprintScale: (x: CGFloat, z: CGFloat) {
        profile.isLaptop ? (CGFloat(profile.width / 31), CGFloat(profile.depth / 22)) : (1, 1)
    }

    /// Notch as fractions of the panel. Measured from this Mac's own screen when it has
    /// one; otherwise the 13.6-inch Air's proportions, which every notched model shares
    /// closely enough at this size.
    private let notch: (width: CGFloat, height: CGFloat)

    /// Home framing (eye, target), scaled to the enclosure so a Mac mini and an iMac both
    /// fill the view.
    private var home: (SCNVector3, SCNVector3) {
        switch profile.family {
        case .air, .pro:
            return (SCNVector3(0, 25, 60), SCNVector3(0, 6.8, -3))
        case .mini, .studio:
            let w = CGFloat(profile.width), h = CGFloat(profile.height)
            return (SCNVector3(0, h + w * 1.25, w * 2.3), SCNVector3(0, h * 0.4, 0))
        case .iMac:
            return (SCNVector3(0, 30, 108), SCNVector3(0, 22, 0))
        }
    }

    init(profile: MacChassisProfile = .current, finish: MacFinish, measuredNotch: CGSize? = nil, screenSize: CGSize? = nil) {
        self.profile = profile
        if let measuredNotch, let screenSize, measuredNotch.width > 0, screenSize.width > 0 {
            notch = (measuredNotch.width / screenSize.width, measuredNotch.height / screenSize.height)
        } else {
            notch = (0.126, 0.037)
        }
        buildEnvironment()
        buildBoard()
        buildCooling()
        switch profile.family {
        case .air, .pro:
            buildChassis()
            buildBattery()
            buildPort()
            buildDeck()
            buildLid()
            // Internals were drawn between y 0.3 and 1.3; map that band into the shell.
            let fit = (shellTop - 0.13) / 1.0
            guts.scale = SCNVector3(1, fit, 1)
            guts.position.y = 0.05 - 0.3 * fit
        case .mini, .studio:
            buildBox()
        case .iMac:
            buildIMac()
        }
        model.addChildNode(guts)
        model.scale = SCNVector3(footprintScale.x, 1, footprintScale.z)
        scene.rootNode.addChildNode(model)
        setFinish(finish)
    }

    func setFinish(_ finish: MacFinish) {
        for material in finishMaterials { material.diffuse.contents = finish.color }
    }

    // MARK: - Live state

    func apply(_ readings: MacSceneReadings, motion: Bool) {
        // SwiftUI re-renders the panel every second; rewriting identical values would
        // still dirty the scene and cost a frame each time.
        guard readings != lastReadings || motion != self.motion else { return }
        let motionChanged = motion != self.motion
        self.motion = motion
        let previous = lastReadings
        lastReadings = readings

        SCNTransaction.begin()
        SCNTransaction.animationDuration = previous == nil || !motion ? 0 : 0.6

        let cells = Double(cellFills.count)
        let tint = Self.levelColor(readings.level)
        for (index, fill) in cellFills.enumerated() {
            let fraction = min(1, max(0, Double(readings.level) / 100 * cells - Double(index)))
            fill.scale = SCNVector3(max(0.001, fraction), 1, 1)
            fill.geometry?.firstMaterial?.emission.contents = tint
            fill.geometry?.firstMaterial?.diffuse.contents = tint.blended(withFraction: 0.6, of: .black)
        }
        batteryGlow.light?.color = tint
        batteryGlow.light?.intensity = 120 + CGFloat(readings.level) * 4

        let socColor = Self.heatColor(readings.cpuTemperature, warm: 65, hot: 85)
        socHeat.light?.color = socColor
        socHeat.light?.intensity = readings.cpuTemperature.map { 200 + CGFloat(max(0, $0 - 30)) * 12 } ?? 120
        socRim.geometry?.firstMaterial?.emission.contents = socColor
        ssdRim.geometry?.firstMaterial?.emission.contents = Self.heatColor(readings.ssdTemperature, warm: 55, hot: 70)

        fanHousing.isHidden = !readings.hasFans
        heatSpreader.isHidden = readings.hasFans

        cable.opacity = readings.plugged ? 1 : 0
        let led: NSColor = readings.charging ? .systemOrange : .systemGreen
        portLED.geometry?.firstMaterial?.emission.contents = readings.plugged ? led : NSColor.black
        SCNTransaction.commit()

        if previous?.charging != readings.charging || previous?.level != readings.level || motionChanged {
            updateChargingMotion(readings)
        }
        if let panel = profile.panel, screenLevel != readings.level || previous?.charging != readings.charging {
            screenLevel = readings.level
            screen.geometry?.firstMaterial?.emission.contents = Self.screenImage(
                level: profile.isLaptop ? readings.level : nil, charging: readings.charging,
                aspect: panel.pixelsWide / panel.pixelsHigh, notch: profile.hasNotch ? notch : nil)
        }
        if previous?.fanRPM != readings.fanRPM || previous?.hasFans != readings.hasFans || motionChanged {
            updateFan(readings)
        }
    }

    private func updateChargingMotion(_ readings: MacSceneReadings) {
        flow.removeAllActions()
        cellFills.forEach { $0.removeAction(forKey: "pulse"); $0.opacity = 1 }
        guard readings.charging, motion, profile.isLaptop else {
            flow.opacity = 0
            return
        }
        // A bead of current runs port → board edge → battery, over and over.
        let start = SCNVector3(-14.6, 0.9, Self.magSafeZ)
        let path = SCNAction.sequence([
            .move(to: start, duration: 0),
            .fadeOpacity(to: 1, duration: 0.15),
            .move(to: SCNVector3(-11.5, 0.9, Self.magSafeZ), duration: 0.35),
            .move(to: SCNVector3(-9, 1.0, -1), duration: 0.4),
            .move(to: SCNVector3(-6, 1.3, 1.6), duration: 0.35),
            .fadeOpacity(to: 0, duration: 0.25),
            .wait(duration: 0.3),
        ])
        flow.runAction(.repeatForever(path))

        // The cell currently filling breathes; the full ones stay steady.
        guard !cellFills.isEmpty else { return }
        let filling = min(cellFills.count - 1, Int(Double(readings.level) / 100 * Double(cellFills.count)))
        let pulse = SCNAction.sequence([.fadeOpacity(to: 0.45, duration: 0.7), .fadeOpacity(to: 1, duration: 0.7)])
        pulse.timingMode = .easeInEaseOut
        cellFills[filling].runAction(.repeatForever(pulse), forKey: "pulse")
    }

    private func updateFan(_ readings: MacSceneReadings) {
        fanRotor.removeAllActions()
        guard readings.hasFans, motion, let rpm = readings.fanRPM, rpm > 0 else { return }
        // Visual speed follows the fan's, compressed — real rpm would be a blur.
        let secondsPerTurn = max(0.25, min(3, 900 / rpm))
        fanRotor.runAction(.repeatForever(.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: secondsPerTurn)))
    }

    // MARK: - Interaction

    func part(at point: CGPoint, in view: SCNView) -> MacPart? {
        let options: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .categoryBitMask: ~Self.decorativeCategory,
        ]
        for hit in view.hitTest(point, options: options) {
            var node: SCNNode? = hit.node
            while let current = node {
                if let name = current.name, let part = MacPart(rawValue: name) { return part }
                node = current.parent
            }
        }
        return nil
    }

    func focus(on part: MacPart?, animated: Bool) {
        model.removeAction(forKey: "sway")
        var (eye, target) = home
        if let part {
            if profile.isLaptop, let tuned = Self.focus[part] {
                (eye, target) = (frontFacing(tuned.0), frontFacing(tuned.1))
                // The reading card covers the lower part of the view, so aim below the
                // part to lift it into the clear area above the card.
                target.y -= 1.6
            } else if let node = model.childNode(withName: part.rawValue, recursively: true) {
                (eye, target) = desktopFocus(on: node, part: part)
            }
            // Close-ups are framed for the model facing front, so turn it back as the
            // camera flies in. This runs as an action, not an implicit animation: the
            // turn is owned by actions (sway, this), and an implicit eulerAngles change
            // lost to them, leaving a turned model that sent the port shot into the lid.
            if animated {
                let face = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.75, usesShortestUnitArc: true)
                face.timingMode = .easeInEaseOut
                model.runAction(face, forKey: "face")
            } else {
                model.removeAction(forKey: "face")
                model.eulerAngles = SCNVector3Zero
            }
        }
        // Looking inside clears the keyboard deck away entirely: a lifted, faded deck sat
        // between the close-up camera and the parts as a dark veil.
        let opened = part != nil && part != .display
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.75 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.position = eye
        lookTarget.position = target
        deck.position.y = opened ? 3 : 0
        deck.opacity = opened ? 0 : 1
        SCNTransaction.commit()

        if part == nil, animated, motion { startSway() }
        if let part, animated, let node = model.childNode(withName: part.rawValue, recursively: true) {
            let pop = SCNAction.sequence([.scale(to: 1.06, duration: 0.15), .scale(to: 1, duration: 0.25)])
            pop.timingMode = .easeOut
            node.runAction(pop)
        }
    }

    /// Where a point in the model's own space ends up once the model faces front: just
    /// the footprint stretch, no turn. Close-ups are computed against this pose because
    /// that is where `focus` brings the model.
    private func frontFacing(_ local: SCNVector3) -> SCNVector3 {
        SCNVector3(local.x * model.scale.x + model.position.x,
                   local.y * model.scale.y + model.position.y,
                   local.z * model.scale.z + model.position.z)
    }

    /// Desktops have no tuned table: frame whatever the part's bounds turn out to be.
    private func desktopFocus(on node: SCNNode, part: MacPart) -> (SCNVector3, SCNVector3) {
        if part == .display {
            let (eye, target) = home
            return (SCNVector3(eye.x, target.y + (eye.y - target.y) * 0.8, target.z + (eye.z - target.z) * 0.8), target)
        }
        let (center, radius) = node.boundingSphere
        let world = frontFacing(node.convertPosition(center, to: model))
        let reach = max(CGFloat(radius) * 3.2, CGFloat(profile.width) * 0.35)
        let iMacAngle = profile.family == .iMac
        let eye = iMacAngle
            ? SCNVector3(world.x, world.y + reach * 0.4, world.z + reach * 1.1)
            : SCNVector3(world.x, world.y + reach * 0.9, world.z + reach * 0.75)
        return (eye, SCNVector3(world.x, world.y - reach * 0.18, world.z))
    }

    func rotate(by radians: CGFloat) {
        model.removeAction(forKey: "sway")
        model.removeAction(forKey: "face")
        model.eulerAngles.y = max(-0.9, min(0.9, model.eulerAngles.y + radians))
    }

    func startSway() {
        guard motion else { return }
        model.removeAction(forKey: "face")
        let left = SCNAction.rotateTo(x: 0, y: -0.18, z: 0, duration: 5, usesShortestUnitArc: true)
        let right = SCNAction.rotateTo(x: 0, y: 0.18, z: 0, duration: 5, usesShortestUnitArc: true)
        left.timingMode = .easeInEaseOut
        right.timingMode = .easeInEaseOut
        model.runAction(.repeatForever(.sequence([left, right])), forKey: "sway")
    }

    // MARK: - Construction

    private func buildEnvironment() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.environmentImage()
        scene.lightingEnvironment.intensity = 1.3

        let camera = SCNCamera()
        camera.fieldOfView = 30
        // Close-ups bring the camera within a few units of the parts.
        camera.zNear = 0.2
        camera.zFar = 200
        camera.wantsHDR = true
        // Exposure adaptation is temporal: it keeps requesting frames forever, which would
        // keep the scene drawing even while paused.
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.9
        camera.bloomThreshold = 0.7
        camera.bloomBlurRadius = 8
        cameraNode.camera = camera
        cameraNode.position = home.0
        lookTarget.position = home.1
        scene.rootNode.addChildNode(lookTarget)
        let look = SCNLookAtConstraint(target: lookTarget)
        look.isGimbalLockEnabled = true
        cameraNode.constraints = [look]
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        // Neutral white, so aluminium shows its own colour rather than the light's.
        key.light?.color = NSColor(calibratedWhite: 1, alpha: 1)
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 6
        key.light?.shadowSampleCount = 8
        key.light?.shadowColor = NSColor.black.withAlphaComponent(0.55)
        key.eulerAngles = SCNVector3(-1.05, -0.5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 160
        fill.light?.color = NSColor(calibratedWhite: 0.7, alpha: 1)
        scene.rootNode.addChildNode(fill)

        let floor = SCNNode(geometry: SCNPlane(width: 120, height: 120))
        floor.eulerAngles.x = -.pi / 2
        floor.position.y = -0.31
        let catcher = SCNMaterial()
        catcher.lightingModel = .shadowOnly
        floor.geometry?.firstMaterial = catcher
        scene.rootNode.addChildNode(floor)
    }

    private static func roundedRect(width: CGFloat, depth: CGFloat, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: NSRect(x: -width / 2, y: -depth / 2, width: width, height: depth),
                                xRadius: radius, yRadius: radius)
        path.flatness = 0.05
        return path
    }

    /// An extruded outline lying flat: the path's plane becomes the floor plan.
    private static func slab(_ path: NSBezierPath, thickness: CGFloat, chamfer: CGFloat) -> SCNNode {
        let shape = SCNShape(path: path, extrusionDepth: thickness)
        shape.chamferRadius = chamfer
        let node = SCNNode(geometry: shape)
        node.eulerAngles.x = -.pi / 2
        return node
    }

    /// A unibody bottom case: one rounded slab with a continuous rounded rim, the way the
    /// aluminium is milled, rather than a tray of separate walls.
    private func buildChassis() {
        let corner: CGFloat = 1.35
        let bottom = Self.slab(Self.roundedRect(width: 31, depth: 22, radius: corner), thickness: 0.25, chamfer: 0.1)
        bottom.geometry?.firstMaterial = finishMaterial(rough: 0.34)
        bottom.position.y = -0.03
        model.addChildNode(bottom)

        let rimPath = Self.roundedRect(width: 31, depth: 22, radius: corner)
        rimPath.append(Self.roundedRect(width: 30.4, depth: 21.4, radius: corner - 0.3))
        rimPath.windingRule = .evenOdd
        let rimHeight = shellTop + 0.12
        let rim = Self.slab(rimPath, thickness: rimHeight, chamfer: 0.14)
        rim.geometry?.firstMaterial = finishMaterial(rough: 0.26)
        rim.position.y = rimHeight / 2 - 0.15
        model.addChildNode(rim)

        guard profile.isLaptop else { return }
        // The thumb scoop in the front edge for lifting the lid.
        let scoop = SCNNode(geometry: SCNPlane(width: 3.2, height: shellTop * 0.45))
        (scoop.geometry as? SCNPlane)?.cornerRadius = shellTop * 0.22
        let shade = SCNMaterial()
        shade.lightingModel = .constant
        shade.diffuse.contents = NSColor.black.withAlphaComponent(0.28)
        scoop.geometry?.firstMaterial = shade
        scoop.position = SCNVector3(0, shellTop - shellTop * 0.22, 11.005)
        model.addChildNode(scoop)

        // Hinge barrel the display swings on.
        let hinge = SCNNode(geometry: SCNCylinder(radius: 0.34, height: 26))
        hinge.geometry?.firstMaterial = Self.material(NSColor(calibratedWhite: 0.12, alpha: 1), metal: 0.7, rough: 0.35)
        hinge.eulerAngles.z = .pi / 2
        hinge.position = SCNVector3(0, shellTop - 0.05, -10.7)
        model.addChildNode(hinge)

        buildSidePorts()
    }

    /// The real port layout on each flank. MagSafe itself is built in `buildPort`.
    private func buildSidePorts() {
        let recess = SCNMaterial()
        recess.lightingModel = .constant
        recess.diffuse.contents = NSColor(calibratedWhite: 0.03, alpha: 1)
        let y = shellTop * 0.5 - 0.02
        func opening(side: CGFloat, z: CGFloat, length: CGFloat, height: CGFloat) {
            let plane = SCNPlane(width: length, height: height)
            plane.cornerRadius = height / 2
            plane.firstMaterial = recess
            let node = SCNNode(geometry: plane)
            node.eulerAngles.y = side < 0 ? -.pi / 2 : .pi / 2
            node.position = SCNVector3(side * 15.505, y, z)
            model.addChildNode(node)
        }
        // Left: MagSafe at the back, then two Thunderbolt ports.
        opening(side: -1, z: -3.7, length: 0.9, height: 0.32)
        opening(side: -1, z: -2.2, length: 0.9, height: 0.32)
        if profile.family == .pro {
            opening(side: -1, z: 0.4, length: 0.36, height: 0.36)     // headphone
            opening(side: 1, z: -5.6, length: 1.5, height: 0.42)      // HDMI
            opening(side: 1, z: -3.4, length: 0.9, height: 0.32)      // Thunderbolt
            opening(side: 1, z: -0.9, length: 2.4, height: 0.22)      // SDXC
        } else {
            opening(side: 1, z: -6.2, length: 0.36, height: 0.36)     // headphone
        }
    }

    private func finishMaterial(rough: CGFloat) -> SCNMaterial {
        let material = Self.material(.gray, metal: 0.85, rough: rough)
        finishMaterials.append(material)
        return material
    }

    /// The top case as frosted glass with solid keys, so the glowing parts read through it.
    private func buildDeck() {
        // Unlit tint rather than a lit surface: at this grazing camera angle any specular
        // term turns into a near-mirror Fresnel sheen that hid everything under the deck.
        let glass = finishMaterial(rough: 0.15)
        glass.lightingModel = .constant
        glass.transparency = 0.14
        glass.writesToDepthBuffer = false
        let top = Self.slab(Self.roundedRect(width: 30.5, depth: 21.5, radius: 1.1), thickness: 0.06, chamfer: 0)
        top.geometry?.firstMaterial = glass
        top.position = SCNVector3(0, shellTop - 0.03, 0)
        deck.addChildNode(top)

        // Pro keyboards sit between speaker grilles, so they're narrower than the Air's.
        let pro = profile.family == .pro
        let keyboardWidth: Double = pro ? 25.5 : 27.5
        let keyMaterial = Self.material(NSColor(calibratedWhite: 0.06, alpha: 1), metal: 0.1, rough: 0.5)
        keyMaterial.transparency = 0.85
        let keys = SCNNode()
        let pitch = keyboardWidth / 15.5
        let keyY = Double(shellTop) + 0.03
        let topRowZ = -9.0
        // Function row: full-height keys on notched models, a strip on Touch Bar ones.
        if profile.hasTouchBar {
            let bar = SCNNode(geometry: SCNBox(width: CGFloat(keyboardWidth - pitch * 1.4), height: 0.1, length: CGFloat(pitch * 0.55), chamferRadius: 0.2))
            bar.geometry?.firstMaterial = Self.emissive(NSColor(calibratedRed: 0.15, green: 0.22, blue: 0.45, alpha: 1))
            bar.position = SCNVector3(-pitch * 0.6, keyY, topRowZ)
            keys.addChildNode(bar)
        } else {
            addKeyRow(to: keys, widths: Array(repeating: 1, count: 13), pitch: pitch, z: topRowZ,
                      depth: pitch * (profile.hasNotch ? 0.82 : 0.5), keyboardWidth: keyboardWidth, material: keyMaterial, y: keyY)
        }
        // Touch ID sits at the right end of the function row.
        let touchID = SCNNode(geometry: SCNBox(width: CGFloat(pitch * 0.82), height: 0.14, length: CGFloat(pitch * 0.8), chamferRadius: 0.2))
        touchID.geometry?.firstMaterial = Self.material(NSColor(calibratedWhite: 0.2, alpha: 1), metal: 0.9, rough: 0.15)
        touchID.position = SCNVector3(keyboardWidth / 2 - pitch * 0.45, keyY, topRowZ)
        keys.addChildNode(touchID)

        let rows: [[Double]] = [
            [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5],
            [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
            [1.8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.7],
            [2.3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.2],
        ]
        for (index, widths) in rows.enumerated() {
            addKeyRow(to: keys, widths: widths, pitch: pitch, z: topRowZ + pitch * Double(index + 1),
                      depth: pitch * 0.82, keyboardWidth: keyboardWidth, material: keyMaterial, y: keyY)
        }
        // Bottom row with the spacebar, then the inverted-T arrows tucked in at the right.
        addKeyRow(to: keys, widths: [1, 1, 1, 1.25, 5.2, 1.25, 1], pitch: pitch, z: topRowZ + pitch * 5,
                  depth: pitch * 0.82, keyboardWidth: keyboardWidth - pitch * 3.2, material: keyMaterial, y: keyY,
                  leading: -keyboardWidth / 2)
        let arrowsX = keyboardWidth / 2 - pitch * 1.6
        for (dx, dz, half) in [(-1.0, 0.25, true), (0.0, -0.0, false), (1.0, 0.25, true), (0.0, 0.5, true)] {
            let arrow = SCNNode(geometry: SCNBox(width: CGFloat(pitch * 0.82), height: 0.12,
                                                 length: CGFloat(pitch * (half ? 0.38 : 0.38)), chamferRadius: 0.1))
            arrow.geometry?.firstMaterial = keyMaterial
            arrow.position = SCNVector3(arrowsX + dx * pitch, keyY, topRowZ + pitch * 5 + (dz - 0.2) * pitch)
            keys.addChildNode(arrow)
        }
        deck.addChildNode(keys.flattenedClone())

        if pro {
            // Speaker grilles either side of the keyboard.
            let grille = Self.material(NSColor(calibratedWhite: 0.05, alpha: 1), metal: 0.3, rough: 0.6)
            grille.diffuse.contents = Self.grilleImage()
            grille.transparency = 0.9
            for side in [-1.0, 1.0] {
                let strip = SCNNode(geometry: SCNBox(width: 1.6, height: 0.05, length: CGFloat(pitch * 6), chamferRadius: 0.3))
                strip.geometry?.firstMaterial = grille
                strip.position = SCNVector3(side * (keyboardWidth / 2 + 1.25), keyY - 0.1, topRowZ + pitch * 2.5)
                deck.addChildNode(strip)
            }
        }

        let trackpadWidth: CGFloat = profile.family == .air ? 13 : 14
        let trackpad = SCNNode(geometry: SCNBox(width: trackpadWidth, height: 0.04, length: 8, chamferRadius: 0.02))
        let pad = finishMaterial(rough: 0.12)
        pad.lightingModel = .constant
        pad.transparency = 0.22
        trackpad.geometry?.firstMaterial = pad
        trackpad.position = SCNVector3(0, shellTop + 0.005, 6.2)
        deck.addChildNode(trackpad)

        deck.enumerateHierarchy { node, _ in node.categoryBitMask = Self.decorativeCategory }
        model.addChildNode(deck)
    }

    private func addKeyRow(to parent: SCNNode, widths: [Double], pitch: Double, z: Double, depth: Double,
                           keyboardWidth: Double, material: SCNMaterial, y: Double, leading: Double? = nil) {
        let gap = pitch * 0.18
        let total = widths.reduce(0, +)
        let unit = keyboardWidth / total
        var x = leading ?? -keyboardWidth / 2
        for width in widths {
            let w = width * unit - gap
            let key = SCNNode(geometry: SCNBox(width: CGFloat(w), height: 0.12, length: CGFloat(depth), chamferRadius: 0.12))
            key.geometry?.firstMaterial = material
            key.position = SCNVector3(x + w / 2 + gap / 2, y, z)
            parent.addChildNode(key)
            x += width * unit
        }
    }

    /// The display half, hinged at the back edge and tipped past upright like an open
    /// MacBook. The panel itself shows this Mac's live charge.
    private func buildLid() {
        guard let spec = profile.panel else { return }
        lid.name = MacPart.display.rawValue
        // Lid footprint matches the base; the panel is the spec's active area. x is in the
        // 31-unit design width (stretched later), y is true centimetres.
        let toDesignX = 31 / CGFloat(profile.width)
        let height = CGFloat(profile.depth) * 0.985
        let outline = NSBezierPath(roundedRect: NSRect(x: -15.5, y: 0, width: 31, height: height), xRadius: 1.35, yRadius: 1.35)
        outline.flatness = 0.05
        let shellShape = SCNShape(path: outline, extrusionDepth: 0.42)
        shellShape.chamferRadius = 0.14
        let shell = SCNNode(geometry: shellShape)
        shell.geometry?.firstMaterial = finishMaterial(rough: 0.3)
        shell.position.z = -0.21
        lid.addChildNode(shell)

        // Edge-to-edge cover glass with the panel's rounded corners, black where unlit.
        let glassPlane = SCNPlane(width: 30.6, height: height - 0.3)
        glassPlane.cornerRadius = 1.15
        glassPlane.firstMaterial = Self.material(NSColor(calibratedWhite: 0.015, alpha: 1), metal: 0.1, rough: 0.04)
        let glass = SCNNode(geometry: glassPlane)
        glass.position = SCNVector3(0, height / 2, 0.006)
        lid.addChildNode(glass)

        let panelWidth = CGFloat(spec.widthCm) * toDesignX
        let panelHeight = CGFloat(spec.heightCm)
        let topBezel: CGFloat = profile.hasNotch ? 0.45 : 0.95
        let panelPlane = SCNPlane(width: panelWidth, height: panelHeight)
        panelPlane.cornerRadius = profile.hasNotch ? 0.55 : 0.1
        let panel = SCNMaterial()
        panel.lightingModel = .constant
        panel.diffuse.contents = NSColor.black
        panel.emission.intensity = 0.9
        panelPlane.firstMaterial = panel
        screen.geometry = panelPlane
        // Pinned under the top bezel; whatever is left below becomes the chin, as on the real one.
        screen.position = SCNVector3(0, height - 0.15 - topBezel - panelHeight / 2, 0.012)
        lid.addChildNode(screen)

        lid.position = SCNVector3(0, shellTop + 0.05, -10.7)
        lid.eulerAngles.x = -0.22
        model.addChildNode(lid)
    }

    /// Mac mini / Mac Studio: a rounded-square aluminium block on a recessed dark foot,
    /// with a see-through top so the board and fan show, and the front I/O.
    private func buildBox() {
        let w = CGFloat(profile.width), h = CGFloat(profile.height)
        let corner = w * 0.16
        let foot = Self.slab(Self.roundedRect(width: w * 0.82, depth: w * 0.82, radius: corner * 0.8), thickness: 0.3, chamfer: 0.08)
        foot.geometry?.firstMaterial = Self.material(NSColor(calibratedWhite: 0.08, alpha: 1), metal: 0.3, rough: 0.6)
        foot.position.y = -0.15
        model.addChildNode(foot)

        let body = SCNNode()
        body.name = MacPart.display.rawValue
        let wallPath = Self.roundedRect(width: w, depth: w, radius: corner)
        wallPath.append(Self.roundedRect(width: w - 0.5, depth: w - 0.5, radius: corner - 0.25))
        wallPath.windingRule = .evenOdd
        let walls = Self.slab(wallPath, thickness: h, chamfer: min(0.6, h * 0.12))
        walls.geometry?.firstMaterial = finishMaterial(rough: 0.3)
        walls.position.y = h / 2 + 0.05
        body.addChildNode(walls)
        let floorPlate = Self.slab(Self.roundedRect(width: w - 0.4, depth: w - 0.4, radius: corner - 0.2), thickness: 0.2, chamfer: 0)
        floorPlate.geometry?.firstMaterial = finishMaterial(rough: 0.4)
        floorPlate.position.y = 0.15
        body.addChildNode(floorPlate)
        model.addChildNode(body)

        let glass = finishMaterial(rough: 0.15)
        glass.lightingModel = .constant
        glass.transparency = 0.3
        glass.writesToDepthBuffer = false
        let lidTop = Self.slab(Self.roundedRect(width: w - 0.1, depth: w - 0.1, radius: corner - 0.05), thickness: 0.08, chamfer: 0)
        lidTop.geometry?.firstMaterial = glass
        lidTop.position.y = h
        lidTop.categoryBitMask = Self.decorativeCategory
        model.addChildNode(lidTop)

        // Board and fan, scaled to the footprint and lifted to just under the top, where
        // they read through it instead of hiding behind the front wall.
        let fit = (w * 0.78) / 21
        guts.scale = SCNVector3(fit, fit, fit)
        guts.position = SCNVector3(0.5 * fit, h - 0.15 - 1.3 * fit, 5 * fit)

        // Front I/O: two USB-C and a headphone jack on the mini, USB-C and SD on the Studio.
        let recess = SCNMaterial()
        recess.lightingModel = .constant
        recess.diffuse.contents = NSColor(calibratedWhite: 0.03, alpha: 1)
        func opening(x: CGFloat, y: CGFloat, length: CGFloat, height: CGFloat) {
            let plane = SCNPlane(width: length, height: height)
            plane.cornerRadius = height / 2
            plane.firstMaterial = recess
            let node = SCNNode(geometry: plane)
            node.position = SCNVector3(x, y, w / 2 + 0.005)
            model.addChildNode(node)
        }
        if profile.family == .mini {
            let y = h * 0.42
            opening(x: -w * 0.3, y: y, length: 0.85, height: 0.3)
            opening(x: -w * 0.2, y: y, length: 0.85, height: 0.3)
            opening(x: -w * 0.11, y: y, length: 0.35, height: 0.35)
        } else {
            let y = h * 0.2
            opening(x: -w * 0.3, y: y, length: 0.85, height: 0.3)
            opening(x: -w * 0.2, y: y, length: 0.85, height: 0.3)
            opening(x: w * 0.22, y: y, length: 2.4, height: 0.22)
            // Power indicator, low on the front left.
            let led = SCNNode(geometry: SCNSphere(radius: 0.08))
            led.geometry?.firstMaterial = Self.emissive(.white)
            led.position = SCNVector3(-w * 0.42, h * 0.12, w / 2 + 0.01)
            model.addChildNode(led)
        }
    }

    /// iMac 24-inch: a thin colour slab with a white-bordered panel above the coloured
    /// chin, on a bent stand. The chin is see-through: that's where the board lives.
    private func buildIMac() {
        guard let spec = profile.panel else { return }
        let w = CGFloat(profile.width)
        let slabHeight: CGFloat = 41.5
        let bottom: CGFloat = 4.6
        let thickness: CGFloat = 1.15

        let body = SCNNode()
        body.name = MacPart.display.rawValue
        let outline = NSBezierPath(roundedRect: NSRect(x: -w / 2, y: 0, width: w, height: slabHeight), xRadius: 1.4, yRadius: 1.4)
        outline.flatness = 0.05
        let backShape = SCNShape(path: outline, extrusionDepth: thickness)
        backShape.chamferRadius = 0.3
        let back = SCNNode(geometry: backShape)
        back.geometry?.firstMaterial = finishMaterial(rough: 0.3)
        back.position = SCNVector3(0, bottom, -thickness / 2 - 0.02)
        body.addChildNode(back)

        let panelWidth = CGFloat(spec.widthCm), panelHeight = CGFloat(spec.heightCm)
        let borderWidth: CGFloat = 1.1
        let frontHeight = panelHeight + borderWidth * 2
        let front = SCNPlane(width: w - 0.4, height: frontHeight)
        front.cornerRadius = 1.2
        // Off-white border glass. Unlit, or it mirrors the blue sky and stops looking white.
        let border = SCNMaterial()
        border.lightingModel = .constant
        border.diffuse.contents = NSColor(calibratedWhite: 0.9, alpha: 1)
        front.firstMaterial = border
        let frontNode = SCNNode(geometry: front)
        frontNode.position = SCNVector3(0, bottom + slabHeight - frontHeight / 2 - 0.2, 0.01)
        body.addChildNode(frontNode)

        let panelPlane = SCNPlane(width: panelWidth, height: panelHeight)
        let panel = SCNMaterial()
        panel.lightingModel = .constant
        panel.diffuse.contents = NSColor.black
        panel.emission.intensity = 0.9
        panelPlane.firstMaterial = panel
        screen.geometry = panelPlane
        screen.position = SCNVector3(0, frontNode.position.y, 0.02)
        body.addChildNode(screen)
        model.addChildNode(body)

        let chinHeight = slabHeight - frontHeight - 0.2
        let chinGlass = finishMaterial(rough: 0.2)
        chinGlass.lightingModel = .constant
        chinGlass.transparency = 0.45
        chinGlass.writesToDepthBuffer = false
        let chin = SCNNode(geometry: SCNPlane(width: w - 0.4, height: chinHeight))
        (chin.geometry as? SCNPlane)?.cornerRadius = 1.2
        chin.geometry?.firstMaterial = chinGlass
        chin.position = SCNVector3(0, bottom + chinHeight / 2, 0.6)
        chin.categoryBitMask = Self.decorativeCategory
        model.addChildNode(chin)

        // The board stands upright inside the chin, facing out.
        let fit: CGFloat = 1.15
        guts.scale = SCNVector3(fit, fit, fit)
        guts.eulerAngles.x = .pi / 2
        guts.position = SCNVector3(0.5 * fit, bottom + 0.6 - 1.25 * fit, -0.15 - 0.3 * fit)

        // Stand: a bent sheet rising from a flat foot to the back of the slab.
        let standMaterial = finishMaterial(rough: 0.35)
        let foot = SCNNode(geometry: SCNBox(width: 13, height: 0.5, length: 14.7, chamferRadius: 0.25))
        foot.geometry?.firstMaterial = standMaterial
        foot.position = SCNVector3(0, 0.25, -5.5)
        model.addChildNode(foot)
        let arm = SCNNode(geometry: SCNBox(width: 13, height: 16, length: 0.5, chamferRadius: 0.25))
        arm.geometry?.firstMaterial = standMaterial
        arm.eulerAngles.x = 0.25
        arm.position = SCNVector3(0, 8, -9.5)
        model.addChildNode(arm)
    }

    private func buildBoard() {
        let pcb = SCNNode(geometry: SCNBox(width: 21, height: 0.25, length: 7.5, chamferRadius: 0.3))
        pcb.geometry?.firstMaterial = Self.material(NSColor(calibratedRed: 0.05, green: 0.1, blue: 0.16, alpha: 1), metal: 0.2, rough: 0.55)
        pcb.position = SCNVector3(-0.5, 0.45, -5)
        guts.addChildNode(pcb)

        // Passives scattered round the SoC: enough texture that the board reads as a board.
        let passive = Self.material(NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.3, alpha: 1), metal: 0.6, rough: 0.35)
        let dark = Self.material(NSColor(calibratedWhite: 0.1, alpha: 1), metal: 0.2, rough: 0.5)
        let spots: [(Double, Double, Bool)] = [
            (-3.2, -6.8, true), (-2.6, -6.8, true), (3.1, -2.4, true), (2.5, -2.4, true), (-3.4, -2.5, false),
            (3.4, -7.1, false), (9.4, -6.6, true), (9.4, -3.2, true), (-4.6, -4.4, true), (4.6, -4.6, true),
        ]
        for (x, z, small) in spots {
            let node = SCNNode(geometry: small
                ? SCNBox(width: 0.5, height: 0.22, length: 0.28, chamferRadius: 0.05)
                : SCNBox(width: 1.3, height: 0.3, length: 1.3, chamferRadius: 0.12))
            node.geometry?.firstMaterial = small ? passive : dark
            node.position = SCNVector3(x, 0.68, z)
            guts.addChildNode(node)
        }

        let soc = SCNNode()
        soc.name = MacPart.soc.rawValue
        let package = SCNNode(geometry: SCNBox(width: 4.4, height: 0.5, length: 4.4, chamferRadius: 0.35))
        package.geometry?.firstMaterial = Self.material(NSColor(calibratedWhite: 0.78, alpha: 1), metal: 1, rough: 0.18)
        package.position = SCNVector3(0, 0.85, -4.5)
        soc.addChildNode(package)
        socRim.geometry = SCNBox(width: 4.9, height: 0.12, length: 4.9, chamferRadius: 0.4)
        socRim.geometry?.firstMaterial = Self.emissive(.systemBlue)
        socRim.position = SCNVector3(0, 0.62, -4.5)
        soc.addChildNode(socRim)
        socHeat.light = SCNLight()
        socHeat.light?.type = .omni
        socHeat.light?.attenuationStartDistance = 1
        socHeat.light?.attenuationEndDistance = 9
        socHeat.position = SCNVector3(0, 3, -4.5)
        soc.addChildNode(socHeat)
        guts.addChildNode(soc)

        let ssd = SCNNode()
        ssd.name = MacPart.ssd.rawValue
        for z in [-5.9, -3.6] {
            let chip = SCNNode(geometry: SCNBox(width: 3.2, height: 0.35, length: 1.9, chamferRadius: 0.15))
            chip.geometry?.firstMaterial = Self.material(NSColor(calibratedWhite: 0.08, alpha: 1), metal: 0.1, rough: 0.4)
            chip.position = SCNVector3(6.5, 0.75, z)
            ssd.addChildNode(chip)
        }
        ssdRim.geometry = SCNBox(width: 3.8, height: 0.08, length: 4.6, chamferRadius: 0.2)
        ssdRim.geometry?.firstMaterial = Self.emissive(.systemBlue)
        ssdRim.position = SCNVector3(6.5, 0.6, -4.75)
        ssd.addChildNode(ssdRim)
        guts.addChildNode(ssd)
    }

    private func buildBattery() {
        let battery = SCNNode()
        battery.name = MacPart.battery.rawValue
        let shell = Self.material(NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.17, alpha: 1), metal: 0.3, rough: 0.45)
        let cellWidth: CGFloat = 8.4
        var index = 0
        for row in [1.6, 6.6] {
            for column in [-9.0, 0.0, 9.0] {
                let cell = SCNNode(geometry: SCNBox(width: cellWidth, height: 0.9, length: 4.4, chamferRadius: 0.35))
                cell.geometry?.firstMaterial = shell
                cell.position = SCNVector3(column, 0.75, row)
                battery.addChildNode(cell)

                // The charge strip grows from the cell's left edge, so pivot it there.
                let fill = SCNNode(geometry: SCNBox(width: cellWidth - 0.8, height: 0.12, length: 3.4, chamferRadius: 0.05))
                fill.geometry?.firstMaterial = Self.charge()
                fill.pivot = SCNMatrix4MakeTranslation(-(cellWidth - 0.8) / 2, 0, 0)
                fill.position = SCNVector3(CGFloat(column) - (cellWidth - 0.8) / 2, 1.24, CGFloat(row))
                battery.addChildNode(fill)
                cellFills.append(fill)
                index += 1
            }
        }
        // Order fills front-left → back-right so the level reads like a gauge.
        cellFills = [3, 4, 5, 0, 1, 2].map { cellFills[$0] }

        batteryGlow.light = SCNLight()
        batteryGlow.light?.type = .omni
        batteryGlow.light?.attenuationStartDistance = 2
        batteryGlow.light?.attenuationEndDistance = 16
        batteryGlow.position = SCNVector3(0, 4, 4)
        battery.addChildNode(batteryGlow)
        guts.addChildNode(battery)
    }

    private func buildCooling() {
        let cooling = SCNNode()
        cooling.name = MacPart.fan.rawValue

        let ring = SCNNode(geometry: SCNTube(innerRadius: 2.3, outerRadius: 2.6, height: 0.8))
        ring.geometry?.firstMaterial = Self.material(NSColor(calibratedWhite: 0.15, alpha: 1), metal: 0.4, rough: 0.4)
        fanHousing.addChildNode(ring)
        let hub = SCNNode(geometry: SCNCylinder(radius: 0.7, height: 0.6))
        hub.geometry?.firstMaterial = Self.material(NSColor(calibratedWhite: 0.25, alpha: 1), metal: 0.6, rough: 0.3)
        fanRotor.addChildNode(hub)
        let bladeMaterial = Self.material(NSColor(calibratedWhite: 0.32, alpha: 1), metal: 0.2, rough: 0.5)
        for blade in 0..<11 {
            let node = SCNNode(geometry: SCNBox(width: 1.6, height: 0.08, length: 0.42, chamferRadius: 0.04))
            node.geometry?.firstMaterial = bladeMaterial
            node.pivot = SCNMatrix4MakeTranslation(-1.35, 0, 0)
            node.eulerAngles = SCNVector3(0.35, CGFloat(blade) / 11 * .pi * 2, 0)
            fanRotor.addChildNode(node)
        }
        fanHousing.addChildNode(fanRotor)
        fanHousing.position = SCNVector3(-8.5, 0.9, -4.5)
        cooling.addChildNode(fanHousing)

        // Fanless Macs get the copper spreader they actually have instead.
        heatSpreader.geometry = SCNBox(width: 5.5, height: 0.15, length: 5, chamferRadius: 0.3)
        heatSpreader.geometry?.firstMaterial = Self.material(NSColor(calibratedRed: 0.78, green: 0.45, blue: 0.28, alpha: 1), metal: 1, rough: 0.28)
        heatSpreader.position = SCNVector3(-8.5, 0.68, -4.5)
        cooling.addChildNode(heatSpreader)
        guts.addChildNode(cooling)
    }

    /// MagSafe 3 on the left flank near the back, and — while plugged in — the braided,
    /// colour-matched cable with the LED on top of its plug.
    private func buildPort() {
        let port = SCNNode()
        port.name = MacPart.port.rawValue
        let y = shellTop * 0.5 - 0.02
        let z = Self.magSafeZ

        let slotPlane = SCNPlane(width: 1.65, height: 0.42)
        slotPlane.cornerRadius = 0.21
        let slotMaterial = SCNMaterial()
        slotMaterial.lightingModel = .constant
        slotMaterial.diffuse.contents = NSColor(calibratedWhite: 0.03, alpha: 1)
        slotPlane.firstMaterial = slotMaterial
        let slot = SCNNode(geometry: slotPlane)
        slot.eulerAngles.y = -.pi / 2
        slot.position = SCNVector3(-15.505, y, z)
        port.addChildNode(slot)

        // The opening is a sliver on the flank; give the click a generous, invisible target.
        let target = SCNNode(geometry: SCNBox(width: 4, height: 2.5, length: 4, chamferRadius: 0))
        let invisible = SCNMaterial()
        invisible.colorBufferWriteMask = []
        invisible.writesToDepthBuffer = false
        target.geometry?.firstMaterial = invisible
        target.castsShadow = false
        target.position = SCNVector3(-15.5, y, z)
        port.addChildNode(target)

        // Plug: a flat aluminium pill in the enclosure colour, as Apple ships it.
        let plug = SCNNode(geometry: SCNBox(width: 1.7, height: 0.46, length: 1.6, chamferRadius: 0.22))
        plug.geometry?.firstMaterial = finishMaterial(rough: 0.22)
        plug.position = SCNVector3(-16.35, y, z)
        cable.addChildNode(plug)
        let boot = SCNNode(geometry: SCNCone(topRadius: 0.2, bottomRadius: 0.3, height: 0.9))
        boot.geometry?.firstMaterial = finishMaterial(rough: 0.55)
        boot.eulerAngles.z = .pi / 2
        boot.position = SCNVector3(-17.6, y, z)
        cable.addChildNode(boot)

        let braid = finishMaterial(rough: 0.75)
        braid.metalness.contents = 0.0
        braid.normal.contents = Self.braidImage()
        braid.normal.wrapS = .repeat
        braid.normal.wrapT = .repeat
        braid.normal.contentsTransform = SCNMatrix4MakeScale(1, 14, 1)
        // The cord runs out from the flank and sags forward onto the desk.
        let start = SIMD3<Float>(-18.0, Float(y), Float(z))
        let control = SIMD3<Float>(-23.5, Float(y), Float(z) - 0.5)
        let end = SIMD3<Float>(-26.5, -0.05, Float(z) + 8)
        var previous = start
        for step in 1...10 {
            let t = Float(step) / 10
            let point = (1 - t) * (1 - t) * start + 2 * (1 - t) * t * control + t * t * end
            cable.addChildNode(Self.cord(from: previous, to: point, radius: 0.2, material: braid))
            previous = point
        }

        portLED.geometry = SCNSphere(radius: 0.075)
        portLED.geometry?.firstMaterial = Self.emissive(.systemOrange)
        portLED.position = SCNVector3(-15.95, y + 0.23, z)
        cable.addChildNode(portLED)
        port.addChildNode(cable)
        model.addChildNode(port)

        flow.geometry = SCNSphere(radius: 0.32)
        flow.geometry?.firstMaterial = Self.emissive(.systemCyan)
        flow.opacity = 0
        guts.addChildNode(flow)
    }

    // MARK: - Materials & palette

    private static func material(_ color: NSColor, metal: CGFloat, rough: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metal
        material.roughness.contents = rough
        return material
    }

    /// Lit strip on top of a cell: glows, but keeps enough shading to read as a surface
    /// rather than a flat neon sticker.
    private static func charge() -> SCNMaterial {
        let material = material(.systemGreen, metal: 0.2, rough: 0.25)
        material.emission.intensity = 0.75
        return material
    }

    private static func emissive(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        return material
    }

    static func levelColor(_ level: Int) -> NSColor {
        level > 50 ? .systemGreen : (level > 20 ? .systemOrange : .systemRed)
    }

    static func heatColor(_ value: Double?, warm: Double, hot: Double) -> NSColor {
        guard let value else { return NSColor.systemGray }
        return value >= hot ? .systemRed : (value >= warm ? .systemOrange : .systemCyan)
    }

    /// What the panel shows: a dark desktop with the menu bar (and the notch, at its measured
    /// size, where the model has one) and — on a laptop — the battery level large in the middle.
    private static func screenImage(level: Int?, charging: Bool, aspect: Double,
                                    notch: (width: CGFloat, height: CGFloat)?) -> NSImage {
        let size = NSSize(width: 1024, height: (1024 / aspect).rounded())
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        let mid = NSPoint(x: size.width / 2, y: size.height * 0.48)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.33, alpha: 1),
            NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.1, alpha: 1),
        ])?.draw(in: bounds, angle: -90)
        let tint = level.map(levelColor) ?? .systemTeal
        NSGradient(colors: [tint.withAlphaComponent(0.35), tint.withAlphaComponent(0)])?
            .draw(fromCenter: mid, radius: 0, toCenter: mid, radius: size.height * 0.53, options: [])

        let barHeight = notch.map { $0.height * size.height } ?? size.height * 0.037
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight).fill()
        if let notch {
            let notchWidth = notch.width * size.width
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: (size.width - notchWidth) / 2, y: size.height - barHeight,
                                             width: notchWidth, height: barHeight + 12),
                         xRadius: barHeight * 0.3, yRadius: barHeight * 0.3).fill()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let headline = level.map { "\($0)%" } ?? "MacWake"
        let number = NSAttributedString(string: headline, attributes: [
            .font: NSFont.systemFont(ofSize: level == nil ? 110 : 170, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let numberHeight: CGFloat = level == nil ? 140 : 210
        number.draw(in: NSRect(x: 0, y: mid.y - numberHeight * 0.45, width: size.width, height: numberHeight))
        if level != nil {
            let caption = NSAttributedString(string: charging ? "⚡︎ MacWake" : "MacWake", attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: tint,
                .paragraphStyle: paragraph,
            ])
            caption.draw(in: NSRect(x: 0, y: mid.y - numberHeight * 0.45 - 50, width: size.width, height: 50))
        }
        image.unlockFocus()
        return image
    }

    /// MagSafe 3 sits ~4.7 cm in from the back edge.
    private static let magSafeZ: CGFloat = -6.2

    private static func cord(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let length = simd_distance(a, b)
        // Overlap a little so the joints between segments don't show.
        let segment = SCNNode(geometry: SCNCapsule(capRadius: radius, height: CGFloat(length) + radius * 2))
        segment.geometry?.firstMaterial = material
        segment.simdPosition = (a + b) / 2
        segment.simdLook(at: b, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 1, 0))
        return segment
    }

    /// Diagonal weave as a normal map, so the braid catches light like the real cable.
    private static func braidImage() -> NSImage {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.5, green: 0.5, blue: 1, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for offset in stride(from: -32.0, to: 64, by: 8) {
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: offset, y: 0))
            stripe.line(to: NSPoint(x: offset + 32, y: 32))
            stripe.lineWidth = 3
            NSColor(calibratedRed: 0.7, green: 0.6, blue: 1, alpha: 1).setStroke()
            stripe.stroke()
        }
        image.unlockFocus()
        return image
    }

    private static func grilleImage() -> NSImage {
        let size = NSSize(width: 64, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.setFill()
        for y in stride(from: 4.0, to: 256, by: 8) {
            for x in stride(from: 4.0 + (y.truncatingRemainder(dividingBy: 16) == 4 ? 0 : 4), to: 64, by: 8) {
                NSBezierPath(ovalIn: NSRect(x: x - 2, y: y - 2, width: 4, height: 4)).fill()
            }
        }
        image.unlockFocus()
        return image
    }

    /// A small lat-long sky (soft light above, dark below) so the metal parts have
    /// something to reflect — physically based metals render black without one.
    private static func environmentImage() -> NSImage {
        let size = NSSize(width: 256, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            // Near-neutral, so aluminium finishes keep their own colour.
            NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.93, alpha: 1),
            NSColor(calibratedRed: 0.4, green: 0.42, blue: 0.48, alpha: 1),
            NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }
}

@MainActor
final class MacSceneController {
    let model: MacInternalsScene
    var finish: MacFinish

    init(finish: MacFinish) {
        self.finish = finish
        // The built-in panel is the only one with a notch, so it's the one to measure.
        let builtIn = NSScreen.screens.first { $0.miNotchSize != .zero }
        model = MacInternalsScene(finish: finish, measuredNotch: builtIn?.miNotchSize, screenSize: builtIn?.frame.size)
    }
    weak var view: SCNView?
    var focused: MacPart?
}

/// The cut-away Mac, clickable and draggable.
struct MacInternalsView: View {
    let readings: MacSceneReadings
    @Binding var selection: MacPart?
    /// False while the panel is closed: the scene stops rendering and its actions freeze.
    let active: Bool
    let motion: Bool
    let finish: MacFinish

    @State private var controller: MacSceneController

    init(readings: MacSceneReadings, selection: Binding<MacPart?>, active: Bool, motion: Bool, finish: MacFinish) {
        self.readings = readings
        _selection = selection
        self.active = active
        self.motion = motion
        self.finish = finish
        _controller = State(initialValue: MacSceneController(finish: finish))
    }

    var body: some View {
        MacSceneRepresentable(controller: controller, readings: readings, selection: $selection,
                              active: active, motion: motion, finish: finish)
            .accessibilityElement()
            .accessibilityLabel(Text("SCENE_HINT"))
    }
}

/// Handles the mouse itself. Gesture recognizers and SwiftUI gestures don't fire here: the
/// menu-bar panel never becomes key, but raw mouse events still reach a view that accepts
/// the first mouse.
private final class InteractiveSCNView: SCNView {
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var downLocation: CGPoint?
    private var lastX: CGFloat = 0
    private var dragging = false
    private var occlusionObserver: NSObjectProtocol?

    /// What SwiftUI asks for; actual playback also requires the panel to be on screen.
    var wantsActive = false { didSet { syncPlayback() } }
    var wantsMotion = false { didSet { syncPlayback() } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A closed menu-bar panel is only ordered out — the view stays alive and SwiftUI's
    // onDisappear doesn't reliably arrive — so without this the display link kept drawing
    // an invisible scene at 30 fps.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPlayback() }
            }
        }
        syncPlayback()
    }

    private func syncPlayback() {
        let onScreen = window?.occlusionState.contains(.visible) ?? false
        let running = wantsActive && onScreen
        scene?.isPaused = !running
        let playing = running && wantsMotion
        if isPlaying != playing { isPlaying = playing }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        downLocation = point
        lastX = point.x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = downLocation, !dragging, abs(point.x - start.x) + abs(point.y - start.y) > 3 {
            dragging = true
        }
        guard dragging else { return }
        onDrag?(point.x - lastX)
        lastX = point.x
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            onDragEnded?()
        } else if downLocation != nil {
            onClick?(convert(event.locationInWindow, from: nil))
        }
        downLocation = nil
        dragging = false
    }
}

private struct MacSceneRepresentable: NSViewRepresentable {
    let controller: MacSceneController
    let readings: MacSceneReadings
    @Binding var selection: MacPart?
    let active: Bool
    let motion: Bool
    let finish: MacFinish

    func makeNSView(context: Context) -> SCNView {
        let view = InteractiveSCNView(frame: .zero, options: nil)
        view.scene = controller.model.scene
        view.pointOfView = controller.model.cameraNode
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = false
        controller.view = view
        controller.focused = selection
        controller.model.apply(readings, motion: motion)
        controller.model.focus(on: selection, animated: false)
        if motion, selection == nil { controller.model.startSway() }
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if let view = view as? InteractiveSCNView {
            let controller = controller
            let selection = $selection
            view.onClick = { [weak view] point in
                guard let view else { return }
                let hit = controller.model.part(at: point, in: view)
                // Clicking the focused part again, or empty space, returns to the overview.
                selection.wrappedValue = hit == selection.wrappedValue ? nil : hit
            }
            view.onDrag = { dx in
                if selection.wrappedValue == nil { controller.model.rotate(by: dx * 0.01) }
            }
            view.onDragEnded = { [motion] in
                if selection.wrappedValue == nil, motion { controller.model.startSway() }
            }
        }
        controller.model.apply(readings, motion: motion)
        if controller.finish != finish {
            controller.finish = finish
            SCNTransaction.begin()
            SCNTransaction.animationDuration = motion ? 0.4 : 0
            controller.model.setFinish(finish)
            SCNTransaction.commit()
        }
        if controller.focused != selection {
            controller.focused = selection
            controller.model.focus(on: selection, animated: motion)
        }
        if let view = view as? InteractiveSCNView {
            view.wantsActive = active
            view.wantsMotion = motion
        }
    }
}

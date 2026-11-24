import Foundation

struct NormalizedPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    func clamped() -> NormalizedPoint {
        NormalizedPoint(min(max(x, 0), 1), min(max(y, 0), 1))
    }
}

struct MeshWarp: Codable, Equatable {
    // Optional so mapping files written before mesh resolution was configurable still decode.
    var subdivisions: Int?
    var controlOffsets: [NormalizedPoint]

    init(subdivisions: Int = 3, controlOffsets: [NormalizedPoint]? = nil) {
        let safeSubdivisions = min(max(subdivisions, 2), 6)
        self.subdivisions = safeSubdivisions
        self.controlOffsets = controlOffsets ?? Array(
            repeating: NormalizedPoint(0, 0),
            count: (safeSubdivisions - 1) * (safeSubdivisions - 1)
        )
    }

    var subdivisionCount: Int {
        min(max(subdivisions ?? 3, 2), 6)
    }

    func sanitized() -> MeshWarp {
        let count = (subdivisionCount - 1) * (subdivisionCount - 1)
        let offsets = (0..<count).map { index -> NormalizedPoint in
            guard controlOffsets.indices.contains(index) else { return NormalizedPoint(0, 0) }
            let point = controlOffsets[index]
            return NormalizedPoint(
                min(max(point.x.isFinite ? point.x : 0, -0.5), 0.5),
                min(max(point.y.isFinite ? point.y : 0, -0.5), 0.5)
            )
        }
        return MeshWarp(subdivisions: subdivisionCount, controlOffsets: offsets)
    }
}

enum SurfaceMaskKind: String, CaseIterable, Codable, Identifiable {
    case rectangle = "Rectangle"
    case cross = "Cross"
    case polygon = "Polygon"

    var id: String { rawValue }
}

struct ProjectionOutput: Codable, Identifiable, Equatable {
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let main = ProjectionOutput(id: mainID, name: "Main Output", width: 1920, height: 1080)

    var id: UUID
    var name: String
    var displayID: String?
    var width: Int
    var height: Int
    var exclusionPaths: [ProjectionMaskPath]?
    var exclusionFeather: Double?
    var blendLeft: Double
    var blendRight: Double
    var blendTop: Double
    var blendBottom: Double

    init(
        id: UUID = UUID(),
        name: String,
        displayID: String? = nil,
        width: Int = 1920,
        height: Int = 1080,
        exclusionPaths: [ProjectionMaskPath]? = nil,
        exclusionFeather: Double = 0,
        blendLeft: Double = 0,
        blendRight: Double = 0,
        blendTop: Double = 0,
        blendBottom: Double = 0
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayID = displayID
        self.width = min(max(width, 320), 7680)
        self.height = min(max(height, 240), 4320)
        self.exclusionPaths = exclusionPaths
        self.exclusionFeather = Self.boundedFeather(exclusionFeather)
        self.blendLeft = Self.boundedBlend(blendLeft)
        self.blendRight = Self.boundedBlend(blendRight)
        self.blendTop = Self.boundedBlend(blendTop)
        self.blendBottom = Self.boundedBlend(blendBottom)
    }

    private static func boundedBlend(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 0.25)
    }

    private static func boundedFeather(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 0.05)
    }

    func sanitized() -> ProjectionOutput {
        ProjectionOutput(
            id: id,
            name: name.isEmpty ? "Output" : name,
            displayID: displayID,
            width: width,
            height: height,
            exclusionPaths: (exclusionPaths ?? []).prefix(8).compactMap { path in
                guard (3...32).contains(path.points.count) else { return nil }
                return ProjectionMaskPath(
                    id: path.id,
                    name: path.name.isEmpty ? "Exclusion" : path.name,
                    operation: .exclude,
                    points: path.points
                )
            }.nilIfEmpty,
            exclusionFeather: Self.boundedFeather(exclusionFeather ?? 0),
            blendLeft: blendLeft,
            blendRight: blendRight,
            blendTop: blendTop,
            blendBottom: blendBottom
        )
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

enum CalibrationPattern: String, CaseIterable, Identifiable {
    case off = "Off"
    case grid = "Grid"
    case checkerboard = "Checkerboard"
    case colorBars = "Color Bars"
    case outlines = "Surface Outlines"

    var id: String { rawValue }

    var shaderValue: Float {
        switch self {
        case .off: return 0
        case .grid: return 1
        case .checkerboard: return 2
        case .colorBars: return 3
        case .outlines: return 4
        }
    }
}

struct SurfaceColorCorrection: Codable, Equatable {
    var contrast: Double
    var saturation: Double
    var exposure: Double
    var gamma: Double
    var redGain: Double
    var greenGain: Double
    var blueGain: Double
    var isGrayscale: Bool
    var isSepia: Bool
    var isInverted: Bool

    static let neutral = SurfaceColorCorrection()

    init(
        contrast: Double = 1,
        saturation: Double = 1,
        exposure: Double = 0,
        gamma: Double = 1,
        redGain: Double = 1,
        greenGain: Double = 1,
        blueGain: Double = 1,
        isGrayscale: Bool = false,
        isSepia: Bool = false,
        isInverted: Bool = false
    ) {
        self.contrast = contrast
        self.saturation = saturation
        self.exposure = exposure
        self.gamma = gamma
        self.redGain = redGain
        self.greenGain = greenGain
        self.blueGain = blueGain
        self.isGrayscale = isGrayscale
        self.isSepia = isSepia
        self.isInverted = isInverted
    }

    func sanitized() -> SurfaceColorCorrection {
        func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        return SurfaceColorCorrection(
            contrast: bounded(contrast, to: 0...2, fallback: 1),
            saturation: bounded(saturation, to: 0...2, fallback: 1),
            exposure: bounded(exposure, to: -4...4, fallback: 0),
            gamma: bounded(gamma, to: 0.1...4, fallback: 1),
            redGain: bounded(redGain, to: 0...2, fallback: 1),
            greenGain: bounded(greenGain, to: 0...2, fallback: 1),
            blueGain: bounded(blueGain, to: 0...2, fallback: 1),
            isGrayscale: isGrayscale,
            isSepia: isSepia,
            isInverted: isInverted
        )
    }
}

enum SurfaceEffectKind: String, Codable, CaseIterable, Identifiable {
    case blur = "Blur"
    case chromaKey = "Chroma Key"
    case brightness = "Brightness"
    case saturation = "Saturation"
    case grayscale = "Grayscale"
    case sepia = "Sepia"
    case invert = "Invert"
    case pixelate = "Pixelate"
    case hueRotation = "Hue Rotation"
    case tint = "Tint"
    case sharpen = "Sharpen"
    case vignette = "Vignette"
    case lumaKey = "Luma Key"
    case threshold = "Threshold"

    var id: String { rawValue }
}

struct SurfaceEffectColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let green = SurfaceEffectColor(red: 0.05, green: 0.8, blue: 0.15)
    static let blue = SurfaceEffectColor(red: 0.05, green: 0.25, blue: 0.9)

    func sanitized() -> SurfaceEffectColor {
        func bounded(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
        return SurfaceEffectColor(red: bounded(red), green: bounded(green), blue: bounded(blue))
    }
}

enum VisualGeneratorKind: String, Codable, CaseIterable, Identifiable {
    case solid
    case gradient
    case stars
    case clouds

    var id: String { rawValue }

    var shaderValue: Float {
        switch self {
        case .solid: return 1
        case .gradient: return 2
        case .stars: return 3
        case .clouds: return 4
        }
    }
}

struct VisualGenerator: Codable, Equatable, Identifiable {
    var name: String
    var kind: VisualGeneratorKind
    var primaryColor: SurfaceEffectColor
    var secondaryColor: SurfaceEffectColor
    var speed: Double
    var scale: Double
    var directionDegrees: Double

    var id: String { reference }
    var title: String { name }

    init(
        name: String,
        kind: VisualGeneratorKind,
        primaryColor: SurfaceEffectColor,
        secondaryColor: SurfaceEffectColor = SurfaceEffectColor(red: 1, green: 1, blue: 1),
        speed: Double = 0.12,
        scale: Double = 1,
        directionDegrees: Double = 0
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.primaryColor = primaryColor.sanitized()
        self.secondaryColor = secondaryColor.sanitized()
        self.speed = min(max(speed.isFinite ? speed : 0.12, 0.01), 2)
        self.scale = min(max(scale.isFinite ? scale : 1, 0.1), 8)
        self.directionDegrees = min(max(directionDegrees.isFinite ? directionDegrees : 0, -180), 180)
    }

    static let presets: [VisualGenerator] = [
        VisualGenerator(
            name: "Warm White",
            kind: .solid,
            primaryColor: SurfaceEffectColor(red: 1, green: 0.88, blue: 0.68)
        ),
        VisualGenerator(
            name: "Cool Blue",
            kind: .solid,
            primaryColor: SurfaceEffectColor(red: 0.22, green: 0.5, blue: 1)
        ),
        VisualGenerator(
            name: "Blue Gradient",
            kind: .gradient,
            primaryColor: SurfaceEffectColor(red: 0.015, green: 0.035, blue: 0.17),
            secondaryColor: SurfaceEffectColor(red: 0.04, green: 0.48, blue: 0.82),
            speed: 0.055,
            scale: 1.4
        ),
        VisualGenerator(
            name: "Warm Gradient",
            kind: .gradient,
            primaryColor: SurfaceEffectColor(red: 0.16, green: 0.025, blue: 0.1),
            secondaryColor: SurfaceEffectColor(red: 0.88, green: 0.24, blue: 0.07),
            speed: 0.04,
            scale: 1.2
        ),
        VisualGenerator(
            name: "Night Sky",
            kind: .stars,
            primaryColor: SurfaceEffectColor(red: 0.004, green: 0.008, blue: 0.035),
            secondaryColor: SurfaceEffectColor(red: 0.72, green: 0.86, blue: 1),
            speed: 0.08,
            scale: 1.2
        ),
        VisualGenerator(
            name: "Soft Clouds",
            kind: .clouds,
            primaryColor: SurfaceEffectColor(red: 0.025, green: 0.045, blue: 0.16),
            secondaryColor: SurfaceEffectColor(red: 0.48, green: 0.3, blue: 0.66),
            speed: 0.045,
            scale: 1.1
        )
    ]

    var reference: String {
        var components = URLComponents()
        components.scheme = "generator"
        components.host = kind.rawValue
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "primary", value: Self.hexColor(primaryColor)),
            URLQueryItem(name: "secondary", value: Self.hexColor(secondaryColor)),
            URLQueryItem(name: "speed", value: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), speed)),
            URLQueryItem(name: "scale", value: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), scale)),
            URLQueryItem(name: "direction", value: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), directionDegrees))
        ]
        return components.string ?? "generator://\(kind.rawValue)"
    }

    init?(reference: String) {
        guard let components = URLComponents(string: reference),
              components.scheme == "generator",
              let host = components.host,
              let kind = VisualGeneratorKind(rawValue: host) else { return nil }
        let values = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard let primaryColor = Self.color(fromHex: values["primary"] ?? "FFFFFF"),
              let secondaryColor = Self.color(fromHex: values["secondary"] ?? "FFFFFF") else { return nil }
        self.init(
            name: values["name"] ?? kind.rawValue.capitalized,
            kind: kind,
            primaryColor: primaryColor,
            secondaryColor: secondaryColor,
            speed: Double(values["speed"] ?? "0.12") ?? 0.12,
            scale: Double(values["scale"] ?? "1") ?? 1,
            directionDegrees: Double(values["direction"] ?? "0") ?? 0
        )
    }

    func sanitized() -> VisualGenerator {
        VisualGenerator(
            name: name.isEmpty ? kind.rawValue.capitalized : name,
            kind: kind,
            primaryColor: primaryColor,
            secondaryColor: secondaryColor,
            speed: speed,
            scale: scale,
            directionDegrees: directionDegrees
        )
    }

    private static func hexColor(_ color: SurfaceEffectColor) -> String {
        let value = color.sanitized()
        return String(
            format: "%02X%02X%02X",
            Int((value.red * 255).rounded()),
            Int((value.green * 255).rounded()),
            Int((value.blue * 255).rounded())
        )
    }

    private static func color(fromHex value: String) -> SurfaceEffectColor? {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let packed = UInt32(hex, radix: 16) else { return nil }
        return SurfaceEffectColor(
            red: Double((packed >> 16) & 0xFF) / 255,
            green: Double((packed >> 8) & 0xFF) / 255,
            blue: Double(packed & 0xFF) / 255
        )
    }
}

struct SurfaceEffect: Codable, Identifiable, Equatable {
    static let maximumStackSize = 8

    var id: UUID
    var kind: SurfaceEffectKind
    var isEnabled: Bool
    var radius: Double
    var keyColor: SurfaceEffectColor
    var threshold: Double
    var softness: Double

    init(
        id: UUID = UUID(),
        kind: SurfaceEffectKind,
        isEnabled: Bool = true,
        radius: Double = 5,
        keyColor: SurfaceEffectColor = .green,
        threshold: Double? = nil,
        softness: Double = 0.08
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.radius = radius
        self.keyColor = keyColor
        self.threshold = threshold ?? ((kind == .brightness || kind == .saturation) ? 0.5 : 0.18)
        self.softness = softness
    }

    func sanitized() -> SurfaceEffect {
        func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        return SurfaceEffect(
            id: id,
            kind: kind,
            isEnabled: isEnabled,
            radius: bounded(
                radius,
                to: kind == .hueRotation ? -180...180 : 0...64,
                fallback: kind == .hueRotation ? 0 : 5
            ),
            keyColor: keyColor.sanitized(),
            threshold: bounded(threshold, to: 0...1, fallback: (kind == .brightness || kind == .saturation) ? 0.5 : 0.18),
            softness: bounded(softness, to: 0.001...0.5, fallback: 0.08)
        )
    }
}

enum SurfaceEffectPreset: String, CaseIterable, Identifiable {
    case softFocus = "Soft Focus"
    case greenScreen = "Green Screen Key"
    case blueScreen = "Blue Screen Key"

    var id: String { rawValue }

    var effects: [SurfaceEffect] {
        switch self {
        case .softFocus:
            return [SurfaceEffect(kind: .blur, radius: 6)]
        case .greenScreen:
            return [SurfaceEffect(kind: .chromaKey, keyColor: .green, threshold: 0.2, softness: 0.12)]
        case .blueScreen:
            return [SurfaceEffect(kind: .chromaKey, keyColor: .blue, threshold: 0.2, softness: 0.12)]
        }
    }
}

struct UserEffectPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var effects: [SurfaceEffect]

    init(id: UUID = UUID(), name: String, effects: [SurfaceEffect]) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.effects = effects.prefix(SurfaceEffect.maximumStackSize).map { $0.sanitized() }
    }
}

struct SurfaceContentTransform: Codable, Equatable {
    var zoomX: Double
    var zoomY: Double
    var offsetX: Double
    var offsetY: Double
    var rotationDegrees: Double
    var isFlippedHorizontally: Bool
    var isFlippedVertically: Bool

    init(
        zoomX: Double = 1,
        zoomY: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0,
        rotationDegrees: Double = 0,
        isFlippedHorizontally: Bool = false,
        isFlippedVertically: Bool = false
    ) {
        self.zoomX = zoomX
        self.zoomY = zoomY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
    }

    static let identity = SurfaceContentTransform()

    func sanitized() -> SurfaceContentTransform {
        func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        return SurfaceContentTransform(
            zoomX: bounded(zoomX, to: 0.1...10, fallback: 1),
            zoomY: bounded(zoomY, to: 0.1...10, fallback: 1),
            offsetX: bounded(offsetX, to: -1...1, fallback: 0),
            offsetY: bounded(offsetY, to: -1...1, fallback: 0),
            rotationDegrees: bounded(rotationDegrees, to: -180...180, fallback: 0),
            isFlippedHorizontally: isFlippedHorizontally,
            isFlippedVertically: isFlippedVertically
        )
    }
}

enum ProjectionMaskOperation: String, Codable, CaseIterable, Identifiable {
    case include
    case exclude

    var id: String { rawValue }
}

struct ProjectionMaskPath: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var operation: ProjectionMaskOperation
    var points: [NormalizedPoint]

    init(
        id: UUID = UUID(),
        name: String,
        operation: ProjectionMaskOperation,
        points: [NormalizedPoint]
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.operation = operation
        self.points = points.map { $0.clamped() }
    }
}

struct ProjectionSurface: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var outputID: UUID?
    var corners: [NormalizedPoint]
    var maskKind: SurfaceMaskKind
    var maskPoints: [NormalizedPoint]
    var additionalMaskPaths: [ProjectionMaskPath]?
    var maskFeather: Double?
    var meshWarp: MeshWarp?
    var isMaskInverted: Bool
    var sourcePath: String?
    var contentTransform: SurfaceContentTransform?
    var usesLayerStack: Bool
    var isVisible: Bool
    var isLocked: Bool
    var isBlackout: Bool
    var brightness: Double
    var opacity: Double
    var colorCorrection: SurfaceColorCorrection?
    var effectStack: [SurfaceEffect]?

    static let rectanglePoints = [
        NormalizedPoint(0, 0), NormalizedPoint(1, 0),
        NormalizedPoint(1, 1), NormalizedPoint(0, 1)
    ]

    static let crossPoints = [
        NormalizedPoint(0.38, 0.04), NormalizedPoint(0.62, 0.04),
        NormalizedPoint(0.62, 0.38), NormalizedPoint(0.96, 0.38),
        NormalizedPoint(0.96, 0.62), NormalizedPoint(0.62, 0.62),
        NormalizedPoint(0.62, 0.96), NormalizedPoint(0.38, 0.96),
        NormalizedPoint(0.38, 0.62), NormalizedPoint(0.04, 0.62),
        NormalizedPoint(0.04, 0.38), NormalizedPoint(0.38, 0.38)
    ]

    init(
        id: UUID = UUID(),
        name: String,
        outputID: UUID? = nil,
        corners: [NormalizedPoint] = ProjectionSurface.rectanglePoints,
        maskKind: SurfaceMaskKind = .rectangle,
        maskPoints: [NormalizedPoint] = ProjectionSurface.rectanglePoints,
        sourcePath: String? = nil,
        usesLayerStack: Bool = false
    ) {
        self.id = id
        self.name = name
        self.outputID = outputID
        self.corners = corners
        self.maskKind = maskKind
        self.maskPoints = maskPoints
        additionalMaskPaths = nil
        maskFeather = nil
        meshWarp = nil
        isMaskInverted = false
        self.sourcePath = sourcePath
        contentTransform = nil
        self.usesLayerStack = usesLayerStack
        isVisible = true
        isLocked = false
        isBlackout = false
        brightness = 1
        opacity = 1
        colorCorrection = nil
        effectStack = nil
    }

    static var main: ProjectionSurface {
        ProjectionSurface(name: "Main Surface", usesLayerStack: true)
    }

    static func cross() -> ProjectionSurface {
        ProjectionSurface(name: "Cross", maskKind: .cross, maskPoints: crossPoints)
    }

    static func ceiling() -> ProjectionSurface {
        ProjectionSurface(
            name: "Ceiling",
            corners: [
                NormalizedPoint(0.16, 0.10), NormalizedPoint(0.84, 0.10),
                NormalizedPoint(0.96, 0.90), NormalizedPoint(0.04, 0.90)
            ]
        )
    }

    static func triangle() -> ProjectionSurface {
        ProjectionSurface(
            name: "Triangle",
            maskKind: .polygon,
            maskPoints: [
                NormalizedPoint(0.5, 0.04),
                NormalizedPoint(0.96, 0.94),
                NormalizedPoint(0.04, 0.94)
            ]
        )
    }

    static func ellipse(name: String = "Ellipse", horizontalRadius: Double = 0.46, verticalRadius: Double = 0.46) -> ProjectionSurface {
        // Keep enough spare vertices for users to refine the generated mask.
        let pointCount = 24
        let points = (0..<pointCount).map { index -> NormalizedPoint in
            let angle = Double(index) * 2 * .pi / Double(pointCount)
            return NormalizedPoint(
                0.5 + cos(angle) * horizontalRadius,
                0.5 + sin(angle) * verticalRadius
            )
        }
        return ProjectionSurface(name: name, maskKind: .polygon, maskPoints: points)
    }

    static func circle() -> ProjectionSurface {
        ellipse(name: "Circle", horizontalRadius: 0.26, verticalRadius: 0.46)
    }

    var hasUsableGeometry: Bool {
        ProjectiveTransform.isConvexQuad(corners) && hasValidMeshWarp
    }

    var meshGridPoints: [NormalizedPoint]? {
        guard meshWarp != nil else { return nil }
        let warp = meshWarp?.sanitized() ?? MeshWarp()
        let divisions = warp.subdivisionCount
        let side = divisions + 1
        let offsets = warp.controlOffsets
        var points: [NormalizedPoint] = []
        for row in 0..<side {
            for column in 0..<side {
                let source = NormalizedPoint(Double(column) / Double(divisions), Double(row) / Double(divisions))
                guard let base = ProjectiveTransform.sourceToOutput(source, corners: corners) else { return nil }
                let offsetIndex = (row > 0 && row < divisions && column > 0 && column < divisions)
                    ? (row - 1) * (divisions - 1) + column - 1
                    : nil
                let offset = offsetIndex.flatMap { offsets.indices.contains($0) ? offsets[$0] : nil } ?? NormalizedPoint(0, 0)
                points.append(NormalizedPoint(base.x + offset.x, base.y + offset.y))
            }
        }
        return points
    }

    var hasValidMeshWarp: Bool {
        guard meshWarp != nil else { return true }
        let divisions = meshWarp?.subdivisionCount ?? 3
        let side = divisions + 1
        guard let grid = meshGridPoints, grid.count == side * side else { return false }
        guard grid.allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else { return false }
        let expectedOrientation = ProjectiveTransform.signedArea(corners) >= 0 ? 1.0 : -1.0
        for row in 0..<divisions {
            for column in 0..<divisions {
                let topLeft = grid[row * side + column]
                let topRight = grid[row * side + column + 1]
                let bottomLeft = grid[(row + 1) * side + column]
                let bottomRight = grid[(row + 1) * side + column + 1]
                let areas = [
                    ProjectiveTransform.signedArea([topLeft, topRight, bottomRight]),
                    ProjectiveTransform.signedArea([topLeft, bottomRight, bottomLeft])
                ]
                guard areas.allSatisfy({ $0 * expectedOrientation > 0.000001 }) else { return false }
            }
        }
        return true
    }
}

struct MappingDocument: Codable {
    static let currentVersion = 1

    var formatVersion: Int
    var surfaces: [ProjectionSurface]
    var outputs: [ProjectionOutput]?

    init(surfaces: [ProjectionSurface], outputs: [ProjectionOutput] = [.main]) {
        formatVersion = Self.currentVersion
        self.surfaces = surfaces
        self.outputs = outputs
    }

    var sourcePaths: [String] {
        Array(Set(surfaces.compactMap(\.sourcePath))).sorted()
    }
}

struct SavedLayerState: Codable, Identifiable, Equatable {
    var id: UUID
    var sourcePath: String
    var layerName: String?
    var isEnabled: Bool
    var isSolo: Bool?
    var isLocked: Bool?
    var opacity: Double
    var contentTransform: SurfaceContentTransform?
    var isPlaying: Bool
    var playbackTime: Double
    var effectStack: [SurfaceEffect]?
    var isAudioMuted: Bool?
    var audioVolume: Double?
    var audioDelayMilliseconds: Double?

    init(
        id: UUID = UUID(),
        sourcePath: String,
        layerName: String? = nil,
        isEnabled: Bool = true,
        isSolo: Bool? = nil,
        isLocked: Bool? = nil,
        opacity: Double = 1,
        contentTransform: SurfaceContentTransform? = nil,
        isPlaying: Bool = false,
        playbackTime: Double = 0,
        effectStack: [SurfaceEffect]? = nil,
        isAudioMuted: Bool? = nil,
        audioVolume: Double? = nil,
        audioDelayMilliseconds: Double? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.layerName = layerName.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        self.isEnabled = isEnabled
        self.isSolo = isSolo
        self.isLocked = isLocked
        self.opacity = min(max(opacity, 0), 1)
        self.contentTransform = contentTransform?.sanitized()
        self.isPlaying = isPlaying
        self.playbackTime = max(playbackTime, 0)
        self.effectStack = effectStack?.prefix(SurfaceEffect.maximumStackSize).map { $0.sanitized() }
        self.isAudioMuted = isAudioMuted
        self.audioVolume = audioVolume.map { min(max($0, 0), 1) }
        self.audioDelayMilliseconds = audioDelayMilliseconds.map { min(max($0.isFinite ? $0 : 0, 0), 500) }
    }
}

struct SceneSurfaceState: Codable, Equatable {
    var surfaceID: UUID
    var sourcePath: String?
    var usesLayerStack: Bool
    var isVisible: Bool
    var isBlackout: Bool
    var isMaskInverted: Bool
    var brightness: Double
    var opacity: Double
    var colorCorrection: SurfaceColorCorrection?
    var effectStack: [SurfaceEffect]?
    var audioMuted: Bool?
    var audioVolume: Double?
    var audioDelayMilliseconds: Double?

    init(
        surface: ProjectionSurface,
        audioMuted: Bool? = nil,
        audioVolume: Double? = nil,
        audioDelayMilliseconds: Double? = nil
    ) {
        surfaceID = surface.id
        sourcePath = surface.sourcePath
        usesLayerStack = surface.usesLayerStack
        isVisible = surface.isVisible
        isBlackout = surface.isBlackout
        isMaskInverted = surface.isMaskInverted
        brightness = surface.brightness
        opacity = surface.opacity
        colorCorrection = surface.colorCorrection
        effectStack = surface.effectStack
        self.audioMuted = audioMuted
        self.audioVolume = audioVolume.map { min(max($0, 0), 1) }
        self.audioDelayMilliseconds = audioDelayMilliseconds.map { min(max($0.isFinite ? $0 : 0, 0), 500) }
    }
}

struct SavedSourceAudioState: Codable, Equatable, Identifiable {
    var sourcePath: String
    var audioMuted: Bool
    var audioVolume: Double
    var audioDelayMilliseconds: Double

    var id: String { sourcePath }

    init(sourcePath: String, audioMuted: Bool, audioVolume: Double, audioDelayMilliseconds: Double = 0) {
        self.sourcePath = sourcePath
        self.audioMuted = audioMuted
        self.audioVolume = min(max(audioVolume.isFinite ? audioVolume : 1, 0), 1)
        self.audioDelayMilliseconds = min(max(audioDelayMilliseconds.isFinite ? audioDelayMilliseconds : 0, 0), 500)
    }
}

struct ScenePreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var layers: [SavedLayerState]
    var surfaces: [SceneSurfaceState]
    var isBlackout: Bool?
    var operatorNotes: String?
    var autoAdvanceAfter: TimeInterval?

    init(
        id: UUID = UUID(),
        name: String,
        layers: [SavedLayerState],
        surfaces: [SceneSurfaceState],
        isBlackout: Bool? = nil,
        operatorNotes: String? = nil,
        autoAdvanceAfter: TimeInterval? = nil
    ) {
        self.id = id
        self.name = String(name.prefix(120))
        self.layers = layers
        self.surfaces = surfaces
        self.isBlackout = isBlackout
        self.operatorNotes = operatorNotes.map { String($0.prefix(2000)) }
        self.autoAdvanceAfter = autoAdvanceAfter.map { min(max($0.isFinite ? $0 : 0, 0), 3600) }
    }
}

struct ShowDocument: Codable {
    static let currentVersion = 1

    var formatVersion: Int
    var surfaces: [ProjectionSurface]
    var layers: [SavedLayerState]
    var scenes: [ScenePreset]
    var outputs: [ProjectionOutput]?
    var sourceAudio: [SavedSourceAudioState]?

    init(
        surfaces: [ProjectionSurface],
        layers: [SavedLayerState],
        scenes: [ScenePreset],
        outputs: [ProjectionOutput] = [.main],
        sourceAudio: [SavedSourceAudioState]? = nil
    ) {
        formatVersion = Self.currentVersion
        self.surfaces = surfaces
        self.layers = layers
        self.scenes = scenes
        self.outputs = outputs
        self.sourceAudio = sourceAudio
    }

    var mediaPaths: [String] {
        Array(Set(
            layers.map(\.sourcePath)
                + surfaces.compactMap(\.sourcePath)
                + scenes.flatMap { $0.layers.map(\.sourcePath) }
                + scenes.flatMap { $0.surfaces.compactMap(\.sourcePath) }
                + (sourceAudio ?? []).map(\.sourcePath)
        )).sorted()
    }

    func remappingMediaPaths(_ transform: (String) -> String) -> ShowDocument {
        var copy = self
        copy.surfaces = surfaces.map { surface in
            var updated = surface
            updated.sourcePath = surface.sourcePath.map(transform)
            return updated
        }
        copy.layers = layers.map { layer in
            var updated = layer
            updated.sourcePath = transform(layer.sourcePath)
            return updated
        }
        copy.scenes = scenes.map { scene in
            var updated = scene
            updated.layers = scene.layers.map { layer in
                var remapped = layer
                remapped.sourcePath = transform(layer.sourcePath)
                return remapped
            }
            updated.surfaces = scene.surfaces.map { surface in
                var remapped = surface
                remapped.sourcePath = surface.sourcePath.map(transform)
                return remapped
            }
            return updated
        }
        copy.sourceAudio = sourceAudio?.map { state in
            var updated = state
            updated.sourcePath = transform(state.sourcePath)
            return updated
        }
        return copy
    }
}

enum ProjectiveTransform {
    /// Returns a row-major homography mapping each input point to its paired output point.
    static func make(from input: [NormalizedPoint], to output: [NormalizedPoint]) -> [Double]? {
        guard input.count == 4, output.count == 4 else { return nil }
        var matrix = Array(repeating: Array(repeating: 0.0, count: 9), count: 8)

        for index in 0..<4 {
            let x = input[index].x
            let y = input[index].y
            let u = output[index].x
            let v = output[index].y
            let row = index * 2
            matrix[row] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            matrix[row + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }

        guard let solution = solve(matrix) else { return nil }
        return solution + [1]
    }

    static func sourceToOutput(_ point: NormalizedPoint, corners: [NormalizedPoint]) -> NormalizedPoint? {
        guard let transform = make(from: ProjectionSurface.rectanglePoints, to: corners) else { return nil }
        return apply(transform, to: point)
    }

    static func outputToSource(_ point: NormalizedPoint, corners: [NormalizedPoint]) -> NormalizedPoint? {
        guard let transform = make(from: corners, to: ProjectionSurface.rectanglePoints) else { return nil }
        return apply(transform, to: point)
    }

    static func apply(_ transform: [Double], to point: NormalizedPoint) -> NormalizedPoint? {
        guard transform.count == 9 else { return nil }
        let denominator = transform[6] * point.x + transform[7] * point.y + transform[8]
        guard abs(denominator) > 0.0000001 else { return nil }
        return NormalizedPoint(
            (transform[0] * point.x + transform[1] * point.y + transform[2]) / denominator,
            (transform[3] * point.x + transform[4] * point.y + transform[5]) / denominator
        )
    }

    static func contains(_ point: NormalizedPoint, in polygon: [NormalizedPoint]) -> Bool {
        guard polygon.count >= 3 else { return true }
        var isInside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            let crossesRay = (a.y > point.y) != (b.y > point.y)
                && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            if crossesRay { isInside.toggle() }
            previous = current
        }
        return isInside
    }

    static func signedArea(_ polygon: [NormalizedPoint]) -> Double {
        guard polygon.count > 2 else { return 0 }
        return polygon.indices.reduce(0) { area, index in
            let next = polygon[(index + 1) % polygon.count]
            return area + polygon[index].x * next.y - next.x * polygon[index].y
        } * 0.5
    }

    static func isConvexQuad(_ points: [NormalizedPoint]) -> Bool {
        guard points.count == 4, abs(signedArea(points)) > 0.0001 else { return false }
        let turns = points.indices.map { index -> Double in
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let c = points[(index + 2) % points.count]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return turns.allSatisfy { $0 > 0.000001 } || turns.allSatisfy { $0 < -0.000001 }
    }

    private static func solve(_ augmented: [[Double]]) -> [Double]? {
        var values = augmented
        let count = values.count
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(values[$0][column]) < abs(values[$1][column])
            }), abs(values[pivot][column]) > 0.0000001 else { return nil }
            values.swapAt(column, pivot)
            let divisor = values[column][column]
            for item in column...count { values[column][item] /= divisor }
            for row in 0..<count where row != column {
                let factor = values[row][column]
                for item in column...count { values[row][item] -= factor * values[column][item] }
            }
        }
        return values.map { $0[count] }
    }
}

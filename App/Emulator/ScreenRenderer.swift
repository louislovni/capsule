import Metal
import QuartzCore
import UIKit

/// How the game picture is drawn (Réglages > Rendu de l'image), and whether the weather and lights go over it.
enum ScreenLook: Int, CaseIterable, Identifiable {
    case original = 0, smooth = 1, lcd = 2, crt = 3, remaster = 4

    static let storageKey = "screenLook"
    static let effectsKey = "weatherEffects"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .smooth: return "Lissé HD"
        case .lcd: return "Écran LCD"
        case .crt: return "Télé CRT"
        case .remaster: return "Remaster"
        }
    }

    static var current: ScreenLook {
        ScreenLook(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .original
    }

    /// Météo et lumières: on unless turned off.
    static var effects: Bool {
        UserDefaults.standard.object(forKey: effectsKey) as? Bool ?? true
    }
}

/// What the core says about the scene after a frame (lr_scene): the frontend's weather and light follow it.
struct SceneInfo: Equatable {
    var weather = -1
    var mapType = -1
    var battle = false
    var field = false
    var caveDarkness = 0
    var tint = (r: 256, g: 256, b: 256)
    /// MÉTÉO DS: the core drew the weather's particles (HeartGold's) this frame; the shader keeps only its colours.
    var coreWeather = false
    /// The night's lights on screen (lr_lights): x, y, w, h in the frame's 0..1 and a kind (0 door, 1 window), 5 a light.
    var lights: [Float] = []

    static func == (a: SceneInfo, b: SceneInfo) -> Bool {
        a.weather == b.weather && a.mapType == b.mapType && a.battle == b.battle && a.field == b.field &&
            a.caveDarkness == b.caveDarkness && a.coreWeather == b.coreWeather && a.tint.r == b.tint.r && a.tint.g == b.tint.g && a.tint.b == b.tint.b && a.lights == b.lights
    }

    init() {}

    init(values: [Int32]) {
        guard values.count >= 8 else { return }
        weather = Int(values[0])
        mapType = Int(values[1])
        battle = values[2] != 0
        field = values[3] != 0
        caveDarkness = max(Int(values[4]), 0)
        tint = (Int(values[5]), Int(values[6]), Int(values[7]))
        coreWeather = values.count > 8 && values[8] > 0
    }

    /// pret's MAP_TYPE_* under the sky (town, city, route, ocean route); unknown counts as outdoors.
    var outdoors: Bool { mapType < 0 || [1, 2, 3, 6].contains(mapType) }

    /// DAY AND NIGHT's tint as a night amount: 0 by day, about 1 at the bluest.
    var night: Float {
        let blue = Float(tint.r + tint.g) / 512
        return max(0, min(1, (1 - blue) / 0.45))
    }
}

/// Draws the frames with ScreenShaders.metal into a CAMetalLayer: the look, then the weather (eased in and out) and the
/// night's lights. On a queue of its own, never the main thread (a GPU running late would freeze the whole interface),
/// at most one frame waiting: a frame that comes while one is still being drawn replaces the waiting one.
final class ScreenRenderer {
    private let renderQueue = DispatchQueue(label: "capsule.render", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending: (Data, Int, Int, SceneInfo, CAMetalLayer, CGSize)?
    private var scheduled = false
    /// GPU frames in flight, at most two.
    private let inFlight = DispatchSemaphore(value: 2)

    /// Hands a frame over (any thread): drawn soon on the render queue.
    func submit(_ pixels: Data, width: Int, height: Int, scene: SceneInfo, into layer: CAMetalLayer, size: CGSize) {
        pendingLock.lock()
        pending = (pixels, width, height, scene, layer, size)
        let start = !scheduled
        scheduled = true
        pendingLock.unlock()
        guard start else { return }
        renderQueue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while true {
            pendingLock.lock()
            guard let job = pending else {
                scheduled = false
                pendingLock.unlock()
                return
            }
            pending = nil
            pendingLock.unlock()
            // A GPU two frames behind: this one waits a little, else it's dropped for the next.
            guard inFlight.wait(timeout: .now() + 0.05) == .success else { continue }
            if !draw(job.0, width: job.1, height: job.2, scene: job.3, into: job.4, size: job.5) {
                inFlight.signal()
            }
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// One texture per frame in flight (plus one): a frame is never written while the GPU still reads it.
    private var textures: [MTLTexture] = []
    private var nextTexture = 0
    private let start = CACurrentMediaTime()

    // The weather shown, eased: a new one fades in after the old fades out.
    private var shownWeather = -1
    private var strength: Float = 0
    private var flash: Float = 0
    private var nextFlash: CFTimeInterval = 0
    /// Météo et lumières' own time of day (when PokeDaisy's DAY AND NIGHT is off): the grade now, eased.
    private var grade = SIMD3<Float>(1, 1, 1)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "screen_vertex"),
              let fragment = library.makeFunction(name: "screen_fragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
    }

    /// One frame: RGBX bytes, [width] x [height].
    /// Draws one frame; false if nothing went to the GPU (its in-flight slot is given back by the caller).
    private func draw(_ pixels: Data, width: Int, height: Int, scene: SceneInfo, into layer: CAMetalLayer, size: CGSize) -> Bool {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return false }
        if textures.count != 3 || textures[0].width != width || textures[0].height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = .shaderRead
            textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard textures.count == 3 else {
                textures = []
                return false
            }
        }
        let texture = textures[nextTexture]
        nextTexture = (nextTexture + 1) % textures.count
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base,
                            bytesPerRow: width * 4)
        }
        guard size.width >= 1, size.height >= 1, let drawable = layer.nextDrawable() else { return false }

        let now = CACurrentMediaTime()
        let look = ScreenLook.current
        let effects = ScreenLook.effects
        // The weather: active only on the free field outdoors (a cave's light anywhere on the field).
        let wanted = effects && scene.field && !scene.battle && scene.outdoors && Self.drawn(scene.weather) ? scene.weather : -1
        if wanted != shownWeather {
            strength = max(strength - 0.05, 0)
            if strength == 0 {
                shownWeather = wanted
            }
        } else if wanted >= 0 {
            strength = min(strength + 0.04, 1)
        }
        let lightsOn = effects && scene.field && !scene.battle
        // Lightning in a storm, now and then: a quick bright flash that fades.
        if shownWeather == 5 || shownWeather == 13, strength > 0.5, now >= nextFlash {
            flash = 1
            nextFlash = now + Double.random(in: 4...11)
        }
        flash = max(flash - 0.07, 0)
        let lightStrength: Float = lightsOn ? 1 : 0
        // The time of day: PokeDaisy's DAY AND NIGHT tints the game itself; without it the shader grades the picture by the
        // phone's clock (outdoors on the field, eased so a menu or a door doesn't flash it).
        let coreTinted = scene.tint.r != 256 || scene.tint.g != 256 || scene.tint.b != 256
        let target = effects && !coreTinted && scene.outdoors && scene.field && !scene.battle
            ? Self.dayGrade(Date()) : SIMD3<Float>(1, 1, 1)
        grade += (target - grade) * 0.03
        let ownNight = max(0, min(1, (1 - (grade.x + grade.y) / 2) / 0.45))
        let night = scene.outdoors ? max(scene.night, ownNight) : 0
        let cave = Float(min(scene.caveDarkness, 4)) / 4

        var uniforms = [
            SIMD4<Float>(Float(width), Float(height), Float(size.width), Float(size.height)),
            SIMD4<Float>(Float(look.rawValue), Float(now - start), Float(max(shownWeather, 0)),
                         shownWeather >= 0 ? strength : (lightsOn && (night > 0.01 || cave > 0) ? 1 : 0)),
            SIMD4<Float>(night * lightStrength, flash * strength, cave * lightStrength, scene.outdoors ? 1 : 0),
            SIMD4<Float>(grade.x, grade.y, grade.z, 0),
            SIMD4<Float>(scene.coreWeather ? 1 : 0, 0, 0, 0),
        ]
        // The doors and windows that light up at night: a rect and its kind each (the shader's buffer 1).
        var lights = [SIMD4<Float>](repeating: .zero, count: 2 * Int(LR_LIGHTS_MAX))
        var lightCount = 0
        if night > 0.01 && lightsOn {
            let raw = scene.lights
            var i = 0
            while i + 4 < raw.count && lightCount < Int(LR_LIGHTS_MAX) {
                lights[2 * lightCount] = SIMD4<Float>(raw[i], raw[i + 1], raw[i + 2], raw[i + 3])
                lights[2 * lightCount + 1] = SIMD4<Float>(raw[i + 4], 0, 0, 0)
                lightCount += 1
                i += 5
            }
        }
        uniforms[3].w = Float(lightCount)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeMutableBytes { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        lights.withUnsafeMutableBytes { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        let slots = inFlight
        buffer.addCompletedHandler { _ in slots.signal() }
        buffer.commit()
        return true
    }

    /// The day's colours by the clock (PokeDaisy's DayNight.kt): deep blue at night, pink at dawn, orange at dusk.
    static func dayGrade(_ date: Date) -> SIMD3<Float> {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = Float(parts.hour ?? 12) + Float(parts.minute ?? 0) / 60
        let nightC = SIMD3<Float>(0.5, 0.56, 0.86), dawn = SIMD3<Float>(0.96, 0.86, 0.86), day = SIMD3<Float>(1, 1, 1)
        let dusk = SIMD3<Float>(1.0, 0.8, 0.66)
        let keys: [(Float, SIMD3<Float>)] = [(0, nightC), (4.5, nightC), (6, dawn), (7.5, day), (16.5, day), (18, dusk),
                                             (19.5, nightC), (24, nightC)]
        var i = 0
        while i < keys.count - 2 && keys[i + 1].0 <= hour { i += 1 }
        let (h0, a) = keys[i], (h1, b) = keys[i + 1]
        let t = h1 > h0 ? (hour - h0) / (h1 - h0) : 0
        return a + (b - a) * t
    }

    /// The weathers the shader draws (the games' WEATHER_*).
    private static func drawn(_ weather: Int) -> Bool {
        (0...14).contains(weather)
    }
}

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

    static func == (a: SceneInfo, b: SceneInfo) -> Bool {
        a.weather == b.weather && a.mapType == b.mapType && a.battle == b.battle && a.field == b.field &&
            a.caveDarkness == b.caveDarkness && a.tint.r == b.tint.r && a.tint.g == b.tint.g && a.tint.b == b.tint.b
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
/// night's lights. Main thread.
final class ScreenRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private let start = CACurrentMediaTime()

    // The weather shown, eased: a new one fades in after the old fades out.
    private var shownWeather = -1
    private var strength: Float = 0
    private var flash: Float = 0
    private var nextFlash: CFTimeInterval = 0

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
    func draw(_ pixels: Data, width: Int, height: Int, scene: SceneInfo, into layer: CAMetalLayer) {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return }
        if texture == nil || texture!.width != width || texture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = texture else { return }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base,
                            bytesPerRow: width * 4)
        }
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1, let drawable = layer.nextDrawable() else { return }

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
        let night = scene.outdoors ? scene.night : 0
        let cave = Float(min(scene.caveDarkness, 4)) / 4

        var uniforms = [
            SIMD4<Float>(Float(width), Float(height), Float(size.width), Float(size.height)),
            SIMD4<Float>(Float(look.rawValue), Float(now - start), Float(max(shownWeather, 0)),
                         shownWeather >= 0 ? strength : (lightsOn && (night > 0.01 || cave > 0) ? 1 : 0)),
            SIMD4<Float>(night * lightStrength, flash * strength, cave * lightStrength, scene.outdoors ? 1 : 0),
            SIMD4<Float>(0, 0, 0, 0),
        ]

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeMutableBytes { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// The weathers the shader draws (the games' WEATHER_*).
    private static func drawn(_ weather: Int) -> Bool {
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14].contains(weather)
    }
}

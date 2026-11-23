import MetalKit
import UIKit
import simd
import QuartzCore

struct FrameUniforms {
    var viewProj: simd_float4x4
}

struct DrawUniforms {
    var model: simd_float4x4
}

struct HandVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Uma "tela" de renderização: a tela inteira (modo normal) ou um olho (modo VR).
private struct EyeRect {
    var viewport: MTLViewport
    var scissor: MTLScissorRect
    var side: Float          // -1 olho esquerdo, +1 olho direito, 0 normal
}

private let boneLinks: [(Int, Int)] = [
    (0, 1), (1, 2), (2, 3), (3, 4),
    (0, 5), (5, 6), (6, 7), (7, 8),
    (5, 9), (9, 10), (10, 11), (11, 12),
    (9, 13), (13, 14), (14, 15), (15, 16),
    (13, 17), (17, 18), (18, 19), (19, 20),
    (0, 17)
]

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let model: AppModel
    private var scene: LoadedScene
    private var animator: SceneAnimator?
    private var lastFrameTime: CFTimeInterval = 0
    private var textures: [MTLTexture?] = []
    private let fallback: MTLTexture
    private let psoScene: MTLRenderPipelineState
    private let psoHand: MTLRenderPipelineState
    private let psoHandSDF: MTLRenderPipelineState
    private let dsScene: MTLDepthStencilState
    private let dsOff: MTLDepthStencilState
    private let sampler: MTLSamplerState

    private var aspect: Float = 0.5
    private let eye = SIMD3<Float>(0, 1.6, 0)
    private let fovY: Float = 65.0 * Float.pi / 180.0

    var yawOffset: Float = 0
    var pitchOffset: Float = 0

    weak var mtkView: MTKView?
    private var walkPos = SIMD3<Float>(0, 0, 0)
    private var jumpY: Float = 0
    private var jumpV: Float = 0
    private var crouchK: Float = 0
    private var dwellId: String?
    private var dwellStart: CFTimeInterval = 0
    private var dwellBlock: CFTimeInterval = 0
    private var fpsFrames = 0
    private var fpsT: CFTimeInterval = 0
    private var autoScale: CGFloat = 0.85
    private var goodSeconds = 0
    private var appliedScale: CGFloat = 0
    private var appliedCap = 0

    private var pinchWas: [String: Bool] = [:]
    private var pinchPrev: [String: SIMD2<Float>] = [:]
    private var pressKind: [String: PressKind] = [:]
    private var pointerPrev: [String: CGPoint] = [:]

    private(set) var currentEnv = "desert"
    private var switching = false
    private var snapshotHandler: ((UIImage?) -> Void)?

    /// Pede uma foto do próximo quadro (cena + mãos, sem o menu).
    func requestSnapshot(_ handler: @escaping (UIImage?) -> Void) {
        snapshotHandler = handler
    }

    private func image(from tex: MTLTexture) -> UIImage? {
        let w = tex.width
        let h = tex.height
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        tex.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    static var lastError = ""
    var summary: String {
        let ok = textures.filter { $0 != nil }.count
        return "cena ok: \(scene.draws.count) draws, \(ok)/\(textures.count) texturas"
    }

    init?(view: MTKView, model: AppModel) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            Renderer.lastError = "sem GPU Metal"
            return nil
        }
        guard let library = dev.makeDefaultLibrary() else {
            Renderer.lastError = "shaders nao encontrados"
            return nil
        }
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.62, green: 0.74, blue: 0.9, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false   // permite ler o quadro para tirar foto
        view.isOpaque = false          // deixa o passthrough (câmera) aparecer por trás

        // ambiente salvo no menu; se não estiver incluído no app, usa o primeiro disponível
        var envId = model.menu.homeEnv
        if !MenuModel.isAvailable(envId) {
            envId = MenuModel.environments.first(where: { MenuModel.isAvailable($0.id) })?.id ?? "desert"
        }

        let loaded: LoadedScene
        do {
            loaded = try SceneLoader.load(device: dev, name: envId)
        } catch {
            Renderer.lastError = "scene.bin: \(error)"
            return nil
        }

        // vertex: pos float3 + uv float2 = 20 bytes
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = 12
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 20
        vd.layouts[0].stepFunction = .perVertex

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = library.makeFunction(name: "scene_vertex")
        sd.fragmentFunction = library.makeFunction(name: "scene_fragment")
        sd.vertexDescriptor = vd
        sd.rasterSampleCount = view.sampleCount
        sd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        sd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        let sceneState: MTLRenderPipelineState
        do { sceneState = try dev.makeRenderPipelineState(descriptor: sd) } catch {
            Renderer.lastError = "pipeline cena: \(error.localizedDescription)"
            return nil
        }

        let hd = MTLRenderPipelineDescriptor()
        hd.vertexFunction = library.makeFunction(name: "hand_vertex")
        hd.fragmentFunction = library.makeFunction(name: "hand_fragment")
        hd.rasterSampleCount = view.sampleCount
        hd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        let ca = hd.colorAttachments[0]!
        ca.pixelFormat = view.colorPixelFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let handState: MTLRenderPipelineState
        do { handState = try dev.makeRenderPipelineState(descriptor: hd) } catch {
            Renderer.lastError = "pipeline maos: \(error.localizedDescription)"
            return nil
        }

        let sdfDesc = MTLRenderPipelineDescriptor()
        sdfDesc.vertexFunction = library.makeFunction(name: "handsdf_vertex")
        sdfDesc.fragmentFunction = library.makeFunction(name: "handsdf_fragment")
        sdfDesc.rasterSampleCount = view.sampleCount
        sdfDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        let sa = sdfDesc.colorAttachments[0]!
        sa.pixelFormat = view.colorPixelFormat
        sa.isBlendingEnabled = true
        sa.rgbBlendOperation = .add
        sa.alphaBlendOperation = .add
        sa.sourceRGBBlendFactor = .sourceAlpha
        sa.destinationRGBBlendFactor = .oneMinusSourceAlpha
        sa.sourceAlphaBlendFactor = .one
        sa.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let sdfState: MTLRenderPipelineState
        do { sdfState = try dev.makeRenderPipelineState(descriptor: sdfDesc) } catch {
            Renderer.lastError = "pipeline mao sdf: \(error.localizedDescription)"
            return nil
        }

        let d1 = MTLDepthStencilDescriptor()
        d1.depthCompareFunction = .less
        d1.isDepthWriteEnabled = true
        let d2 = MTLDepthStencilDescriptor()
        d2.depthCompareFunction = .always
        d2.isDepthWriteEnabled = false
        guard let ds1 = dev.makeDepthStencilState(descriptor: d1),
              let ds2 = dev.makeDepthStencilState(descriptor: d2) else { return nil }

        let sampd = MTLSamplerDescriptor()
        sampd.minFilter = .linear
        sampd.magFilter = .linear
        sampd.mipFilter = .linear
        sampd.sAddressMode = .repeat
        sampd.tAddressMode = .repeat
        sampd.maxAnisotropy = 4
        guard let samp = dev.makeSamplerState(descriptor: sampd) else { return nil }

        let fd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let fb = dev.makeTexture(descriptor: fd) else { return nil }
        var white: [UInt8] = [200, 200, 200, 255]
        fb.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)

        let texs = Renderer.loadTextures(loaded.textureNames, env: envId, device: dev)

        self.device = dev
        self.queue = q
        self.model = model
        self.scene = loaded
        self.textures = texs
        self.fallback = fb
        self.psoScene = sceneState
        self.psoHand = handState
        self.psoHandSDF = sdfState
        self.dsScene = ds1
        self.dsOff = ds2
        self.sampler = samp
        super.init()
        self.currentEnv = envId
        self.animator = SceneAnimator(scene: loaded, device: dev)
    }

    private static func loadTextures(_ names: [String], env: String, device: MTLDevice) -> [MTLTexture?] {
        var out: [MTLTexture?] = []
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: env) {
                out.append(KTXLoader.load(url: url, device: device))
            } else {
                out.append(nil)
            }
        }
        return out
    }

    /// Carrega outro ambiente em segundo plano e troca a cena quando estiver pronto.
    func switchEnvironment(_ id: String, completion: @escaping (Bool, String) -> Void) {
        if switching {
            completion(false, "Aguarde o ambiente atual carregar")
            return
        }
        guard MenuModel.isAvailable(id) else {
            completion(false, "Esse ambiente não está incluído no app")
            return
        }
        switching = true
        let dev = device
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let loaded = try SceneLoader.load(device: dev, name: id)
                let texs = Renderer.loadTextures(loaded.textureNames, env: id, device: dev)
                let anim = SceneAnimator(scene: loaded, device: dev)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.scene = loaded
                    self.animator = anim
                    self.textures = texs
                    self.currentEnv = id
                    self.switching = false
                    self.model.renderInfo = self.summary
                    completion(true, "")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.switching = false
                    completion(false, "Falha ao carregar o ambiente")
                }
            }
        }
    }

    // MARK: - interação

    func addLook(yaw: Float, pitch: Float) {
        yawOffset += yaw
        pitchOffset = max(-1.4, min(1.4, pitchOffset + pitch))
    }

    func recenter() {
        yawOffset = 0
        pitchOffset = 0
        model.motion.recenter()
    }

    /// Converte um ponto normalizado da câmera (0...1) para um retângulo w x h
    /// (a imagem da câmera preenche o retângulo, cortando o que sobra).
    private func mapToRect(_ n: SIMD2<Float>, width w: Float, height h: Float) -> SIMD2<Float> {
        let ca = max(cameraAspect, 0.1)
        let s = max(w / ca, h)
        let r = Float(model.settings.get("reach"))
        let nx = 0.5 + (n.x - 0.5) * r
        let ny = 0.5 + (n.y - 0.5) * r
        let x = w * 0.5 + (nx - 0.5) * ca * s
        let y = h * 0.5 + (ny - 0.5) * s
        return SIMD2<Float>(x, y)
    }

    /// `eyeSize` = tamanho de um olho (ou da tela) em pontos; `shift` = deslocamento do olho esquerdo em pontos.
    /// Os cursores recebem coordenadas locais do olho; o teste de toque usa as globais (local + shift).
    private func updateInteraction(_ hands: [TrackedHand], eyeSize: CGSize, shift: CGFloat) {
        let menu = model.menu
        var seen = Set<String>()
        var dots: [PointerDot] = []
        var hoverPoint: CGPoint?
        var hoverIndex = -1
        let primary = Int(model.settings.get("primaryHand"))

        for h in hands {
            let m = mapToRect(h.pinchPoint, width: Float(eyeSize.width), height: Float(eyeSize.height))
            let local = CGPoint(x: CGFloat(m.x), y: CGFloat(m.y))
            // mão principal: a outra só aparece, não mexe no menu
            let isPrimary = primary == 0 || (primary == 1 && h.label == "Right") || (primary == 2 && h.label == "Left")
            if !isPrimary {
                dots.append(PointerDot(id: h.label, point: local, pinching: h.pinching))
                continue
            }
            seen.insert(h.label)
            let was = pinchWas[h.label] ?? false
            let pt = CGPoint(x: local.x + shift, y: local.y)
            let prevPt = pointerPrev[h.label] ?? pt
            dots.append(PointerDot(id: h.label, point: local, pinching: h.pinching))
            if !h.pinching && hoverPoint == nil {
                hoverPoint = pt
                hoverIndex = dots.count - 1
            }

            if h.pinching {
                if !was {
                    // usa a posição do quadro anterior: ao fechar a pinça o ponto se desloca um pouco
                    let kind = menu.pressBegan(at: prevPt)
                    pressKind[h.label] = kind
                    if case .scene = kind { model.audio.play("sfx_grab") }
                } else if let kind = pressKind[h.label] {
                    if case .scene = kind {
                        if let prev = pinchPrev[h.label] {
                            let dx = h.pinchPoint.x - prev.x
                            let dy = h.pinchPoint.y - prev.y
                            // arrastar a cena: mão para a direita gira a câmera para a esquerda
                            addLook(yaw: dx * 3.2, pitch: dy * 2.4)
                        }
                    } else {
                        let delta = CGPoint(x: pt.x - prevPt.x, y: pt.y - prevPt.y)
                        pressKind[h.label] = menu.pressMoved(kind, to: pt, delta: delta)
                    }
                }
                pinchPrev[h.label] = h.pinchPoint
            } else {
                if was, let kind = pressKind[h.label] {
                    if case .scene = kind {
                        model.audio.play("sfx_release_main")
                    } else {
                        menu.pressEnded(kind)
                    }
                }
                pressKind.removeValue(forKey: h.label)
                pinchPrev.removeValue(forKey: h.label)
            }
            pinchWas[h.label] = h.pinching
            pointerPrev[h.label] = pt
        }

        for k in pinchWas.keys where !seen.contains(k) {
            if let kind = pressKind[k] { menu.pressEnded(kind) }
            pinchWas.removeValue(forKey: k)
            pinchPrev.removeValue(forKey: k)
            pressKind.removeValue(forKey: k)
            pointerPrev.removeValue(forKey: k)
        }

        menu.setHover(hoverPoint)

        // clique segurando o dedo: 1 s sobre um botão
        let nowT = CACurrentMediaTime()
        var hoverBtn: String?
        if model.settings.b("dwell") && menu.isOpen && hoverPoint != nil && nowT > dwellBlock, let hid = menu.hoverId {
            let n = (hid.hasPrefix("s:") || hid.hasPrefix("t:")) ? String(hid.dropFirst(2)) : hid
            if n.hasPrefix("b:") { hoverBtn = hid }
        }
        if let hid = hoverBtn {
            if dwellId != hid {
                dwellId = hid
                dwellStart = nowT
            }
            let prog = min(1, (nowT - dwellStart) / 1.0)
            if hoverIndex >= 0 && hoverIndex < dots.count { dots[hoverIndex].progress = CGFloat(prog) }
            if prog >= 1 {
                dwellId = nil
                dwellBlock = nowT + 1.2
                menu.activate(hid)
            }
        } else {
            dwellId = nil
        }

        if !dots.isEmpty || !model.pointer.dots.isEmpty {
            model.pointer.dots = dots
        }
    }

    // MARK: - mãos (silhueta translúcida, desenhada pelo shader handsdf_*)

    /// Dados da mão para um olho: tudo em pixels do quadro (ver Shaders.metal).
    private func buildHandData(_ hands: [TrackedHand], viewport vp: MTLViewport) -> [SIMD4<Float>] {
        var data = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: 50)
        let w = Float(vp.width)
        let h = Float(vp.height)
        let ox = Float(vp.originX)
        let oy = Float(vp.originY)
        data[0] = SIMD4<Float>(ox, oy, w, h)
        var count: Float = 0
        var hi = 0
        for hand in hands {
            if hi >= 2 { break }
            if hand.points.count < 21 { continue }
            let base = 2 + hi * 24
            var pix: [SIMD2<Float>] = []
            var minX = Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude
            for k in 0..<21 {
                let m = mapToRect(SIMD2<Float>(hand.points[k].x, hand.points[k].y), width: w, height: h)
                let q = SIMD2<Float>(m.x + ox, m.y + oy)
                pix.append(q)
                data[base + k] = SIMD4<Float>(q.x, q.y, 0, 0)
                minX = min(minX, q.x)
                minY = min(minY, q.y)
                maxX = max(maxX, q.x)
                maxY = max(maxY, q.y)
            }
            let palm = max(distance(pix[0], pix[9]), 8)
            data[base + 21] = SIMD4<Float>(hand.pinching ? 1 : 0, palm, 0, 0)
            let pad = palm * 1.8
            data[base + 22] = SIMD4<Float>(minX - pad, minY - pad, maxX + pad, maxY + pad)
            hi += 1
            count += 1
        }
        data[1] = SIMD4<Float>(count, Float(model.settings.get("handStyle")), Float(model.settings.get("skin")), 0)
        return data
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.height > 0 {
            aspect = Float(size.width / size.height)
        }
    }

    func draw(in view: MTKView) {
        let passthrough = model.menu.passthrough
        let vr = model.vrMode

        // orientação atual da interface (retrato / paisagem do modo VR)
        if let o = view.window?.windowScene?.interfaceOrientation {
            model.motion.interfaceOrientation = o
            model.tracker.setInterfaceOrientation(o)
        }

        if passthrough {
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        } else if vr {
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        } else {
            view.clearColor = MTLClearColor(red: 0.62, green: 0.74, blue: 0.9, alpha: 1)
        }
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        let dw = Float(view.drawableSize.width)
        let dh = Float(view.drawableSize.height)
        if dh > 0 { aspect = dw / dh }

        // um "olho" no modo normal, dois no modo VR
        var eyes: [EyeRect] = []
        var eyeSizePts = view.bounds.size
        var shiftPts: CGFloat = 0
        if vr && dw > 4 {
            let half = dw * 0.5
            let sh = model.menu.vrShiftFraction * dw
            let scaleX = Float(view.bounds.size.width) / max(dw, 1)
            shiftPts = CGFloat(sh * scaleX)
            eyeSizePts = CGSize(width: view.bounds.size.width * 0.5, height: view.bounds.size.height)
            eyes.append(EyeRect(
                viewport: MTLViewport(originX: Double(sh), originY: 0, width: Double(half), height: Double(dh), znear: 0, zfar: 1),
                scissor: MTLScissorRect(x: 0, y: 0, width: Int(half), height: Int(dh)),
                side: -1))
            eyes.append(EyeRect(
                viewport: MTLViewport(originX: Double(half - sh), originY: 0, width: Double(half), height: Double(dh), znear: 0, zfar: 1),
                scissor: MTLScissorRect(x: Int(half), y: 0, width: Int(dw) - Int(half), height: Int(dh)),
                side: 1))
        } else {
            eyes.append(EyeRect(
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(dw), height: Double(dh), znear: 0, zfar: 1),
                scissor: MTLScissorRect(x: 0, y: 0, width: Int(dw), height: Int(dh)),
                side: 0))
        }

        let hands = model.tracker.currentHands()
        updateInteraction(hands, eyeSize: eyeSizePts, shift: shiftPts)

        // controle (GameController): analógico direito gira a vista
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
        lastFrameTime = now
        model.controllers.poll()
        let stick = model.controllers.stick
        if abs(stick.x) > 0.01 || abs(stick.y) > 0.01 {
            let ls = Float(model.settings.get("lookSens"))
            let inv: Float = model.settings.b("invertY") ? -1 : 1
            addLook(yaw: -stick.x * 1.8 * ls * dt, pitch: stick.y * 1.3 * ls * inv * dt)
        }
        if !passthrough { animator?.update(time: now) }
        model.menu.tick(Double(dt))

        let camRot = rotationY(yawOffset) * model.motion.rotation() * rotationX(pitchOffset)
        let rightDir = camRot * SIMD3<Float>(1, 0, 0)

        // andar (analógico esquerdo), pular e agachar
        let fwd3 = camRot * SIMD3<Float>(0, 0, -1)
        var fx = fwd3.x
        var fz = fwd3.z
        let fl = sqrt(fx * fx + fz * fz)
        if fl > 0.05 { fx /= fl; fz /= fl }
        let wk = model.controllers.walk
        if model.settings.b("walk") && (abs(wk.x) > 0.01 || abs(wk.y) > 0.01) {
            let sp = Float(model.settings.get("walkSpeed")) * dt
            walkPos.x += (fx * wk.y + (-fz) * wk.x) * sp
            walkPos.z += (fz * wk.y + fx * wk.x) * sp
            let r = sqrt(walkPos.x * walkPos.x + walkPos.z * walkPos.z)
            if r > 8 { walkPos.x *= 8 / r; walkPos.z *= 8 / r }
        }
        if model.controllers.takeJump() && jumpY <= 0.001 { jumpV = 2.6 }
        if jumpY > 0 || jumpV > 0 {
            jumpV -= 9.8 * dt
            jumpY += jumpV * dt
            if jumpY < 0 { jumpY = 0; jumpV = 0 }
        }
        let crTarget: Float = model.controllers.crouching ? 1 : 0
        crouchK += (crTarget - crouchK) * min(1, dt * 10)
        let eyeNow = SIMD3<Float>(eye.x + walkPos.x, eye.y + jumpY - 0.6 * crouchK, eye.z + walkPos.z)

        // menu flutuante: fica preso a um ponto do mundo
        let fview = camRot * SIMD3<Float>(0, 0, -1)
        let camYaw = atan2(fview.x, -fview.z)
        let camPitch = asin(max(-1, min(1, fview.y)))
        let fpx = Float(eyeSizePts.height) * 0.5 / tanf(fovY * 0.5)
        model.floating.update(yaw: camYaw, pitch: camPitch, fpx: fpx, dt: dt, active: menu0Open(),
                              locked: model.settings.b("floatMenu"), time: now)
        let halfIPD: Float = 0.032

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setCullMode(.none)

        for e in eyes {
            enc.setViewport(e.viewport)
            enc.setScissorRect(e.scissor)

            let eyePos = eyeNow + rightDir * (e.side * halfIPD)
            let viewM = simd_float4x4(rotation: camRot.transpose) * simd_float4x4.translation(-eyePos)
            let eyeAspect = Float(e.viewport.width / max(e.viewport.height, 1))
            let proj = simd_float4x4.perspective(fovY: fovY, aspect: eyeAspect, near: 0.05, far: 4000)

            // cena
            enc.setRenderPipelineState(psoScene)
            enc.setDepthStencilState(dsScene)
            var fu = FrameUniforms(viewProj: proj * viewM)
            enc.setVertexBytes(&fu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)

            for (di, d) in scene.draws.enumerated() {
                if passthrough { break }   // passthrough: só câmera + mãos + menu
                let mesh = scene.meshes[d.mesh]
                var modelM = d.world
                var vbuf = mesh.vertexBuffer
                if let a = animator {
                    if let sb = a.skinnedBuffer(forDraw: di) {
                        vbuf = sb
                        modelM = matrix_identity_float4x4
                    } else if d.node >= 0 && d.node < a.world.count {
                        modelM = a.world[d.node]
                    }
                }
                var du = DrawUniforms(model: modelM)
                enc.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setVertexBuffer(vbuf, offset: 0, index: 0)
                var tex: MTLTexture = fallback
                if mesh.material >= 0 && mesh.material < scene.materials.count {
                    let ti = scene.materials[mesh.material].texture
                    if ti >= 0 && ti < textures.count, let t = textures[ti] {
                        tex = t
                    }
                }
                enc.setFragmentTexture(tex, index: 0)
                enc.drawIndexedPrimitives(type: .triangle,
                                          indexCount: mesh.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: mesh.indexBuffer,
                                          indexBufferOffset: 0)
            }

            // mãos translúcidas (por cima de tudo)
            if !hands.isEmpty && model.settings.get("handStyle") < 3.5 {
                var hd = buildHandData(hands, viewport: e.viewport)
                enc.setRenderPipelineState(psoHandSDF)
                enc.setDepthStencilState(dsOff)
                enc.setFragmentBytes(&hd, length: hd.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        enc.endEncoding()
        cb.present(drawable)
        if let snap = snapshotHandler {
            snapshotHandler = nil
            let tex = drawable.texture
            cb.addCompletedHandler { [weak self] _ in
                let img = self?.image(from: tex)
                DispatchQueue.main.async { snap(img) }
            }
        }
        cb.addCompletedHandler { [weak self] c in
            if let e = c.error {
                DispatchQueue.main.async { self?.model.renderInfo = "GPU erro: \(e.localizedDescription)" }
            }
        }
        cb.commit()
        updatePerformance(view: view, now: now)
    }

    private func menu0Open() -> Bool { return model.menu.isOpen }

    // MARK: - desempenho (resolução automática, limite de quadros)

    /// Aplica a resolução e o limite de quadros escolhidos no menu.
    func applyPerformance() {
        guard let v = mtkView else { return }
        let cap = model.settings.get("fpsCap") < 45 ? 30 : 60
        if cap != appliedCap {
            appliedCap = cap
            v.preferredFramesPerSecond = cap
        }
        let native = v.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let mode = Int(model.settings.get("res"))
        var k: CGFloat = autoScale
        switch mode {
        case 1: k = 0.5
        case 2: k = 0.75
        case 3: k = 1.0
        default: k = autoScale
        }
        let target = max(1.0, (native * k * 10).rounded() / 10)
        if abs(target - appliedScale) > 0.01 {
            appliedScale = target
            v.contentScaleFactor = target
        }
        model.perf.scaleText = String(format: "%.1f× (%@)", Double(target), mode == 0 ? "auto" : "fixa")
    }

    private func updatePerformance(view: MTKView, now: CFTimeInterval) {
        if appliedScale == 0 { applyPerformance() }
        fpsFrames += 1
        if fpsT == 0 { fpsT = now }
        if now - fpsT < 1.0 { return }
        let fps = Int((Double(fpsFrames) / (now - fpsT)).rounded())
        fpsFrames = 0
        fpsT = now
        model.perf.fps = fps
        model.tracker.renderFPS = Double(fps)
        if Int(model.settings.get("res")) == 0 {
            let cap = Double(appliedCap == 30 ? 30 : 60)
            if Double(fps) < cap * 0.72 && autoScale > 0.5 {
                autoScale = max(0.5, autoScale - 0.1)
                goodSeconds = 0
            } else if Double(fps) >= cap * 0.93 && autoScale < 1.0 {
                goodSeconds += 1
                if goodSeconds >= 6 {
                    autoScale = min(1.0, autoScale + 0.05)
                    goodSeconds = 0
                }
            } else {
                goodSeconds = 0
            }
        }
        applyPerformance()
    }
}

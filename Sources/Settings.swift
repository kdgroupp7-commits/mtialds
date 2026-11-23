import Foundation
import SwiftUI
import QuartzCore

struct SliderSpec {
    let min: Double
    let max: Double
    let step: Double
}

struct ControlAction {
    let id: String
    let title: String
    let defaultCode: String
}

/// Parâmetros do rastreamento lidos pela thread da câmera.
struct TrackingParams {
    var smooth: Float = 0.6
    var lead: Float = 40
    var sens: Int = 1
    var maxHands: Int = 2
    var rate: Int = 0
    var pinchOn: Float = 0.22
    var swap: Bool = false
}

/// Contadores de desempenho (atualizados 1x por segundo).
final class PerfModel: ObservableObject {
    @Published var fps = 0
    @Published var scaleText = "—"
}

/// Posição "flutuante" do menu: o painel fica preso a um ponto do mundo (como no Quest)
/// e se desloca na tela quando a cabeça gira.
final class FloatModel: ObservableObject {
    @Published var offset = CGSize.zero
    private var anchorYaw: Float = 0
    private var anchorPitch: Float = 0
    private var anchored = false
    private var cur = CGSize.zero
    private var lastPublished = CGSize.zero

    func reanchor() { anchored = false }

    private func wrap(_ a: Float) -> Float {
        var v = a
        while v > Float.pi { v -= 2 * Float.pi }
        while v < -Float.pi { v += 2 * Float.pi }
        return v
    }

    /// `fpx` = distância focal em pontos (altura/2 / tan(fovY/2)).
    func update(yaw: Float, pitch: Float, fpx: Float, dt: Float, active: Bool, locked: Bool, time: Double) {
        if !active {
            anchored = false
            if lastPublished != .zero || cur != .zero {
                cur = .zero
                lastPublished = .zero
                offset = .zero
            }
            return
        }
        if !anchored {
            anchorYaw = yaw
            anchorPitch = pitch
            anchored = true
            cur = .zero
        }
        var tx: CGFloat = 0
        var ty: CGFloat = 0
        if locked {
            let dyaw = max(-1.2, min(1.2, wrap(anchorYaw - yaw)))
            let dpitch = max(-1.0, min(1.0, pitch - anchorPitch))
            tx = CGFloat(fpx * tanf(dyaw))
            ty = CGFloat(fpx * tanf(dpitch))
        }
        let k = CGFloat(min(1, dt * 18))
        cur.width += (tx - cur.width) * k
        cur.height += (ty - cur.height) * k
        // balanço suave de quem flutua
        let bobX = CGFloat(sin(time * 0.8) * 1.2)
        let bobY = CGFloat(sin(time * 1.1) * 2.4)
        let target = CGSize(width: cur.width + bobX, height: cur.height + bobY)
        if abs(target.width - lastPublished.width) > 0.2 || abs(target.height - lastPublished.height) > 0.2 {
            lastPublished = target
            offset = target
        }
    }
}

/// Todas as configurações de mãos, rastreamento, controle e desempenho (salvas no aparelho).
final class SettingsModel: ObservableObject {
    static let defaults: [String: Double] = [
        "handStyle": 0, "skin": 1, "maxHands": 2, "swapHands": 0, "primaryHand": 0, "dwell": 0,
        "trkSens": 1, "smoothH": 0.6, "lead": 40, "rate": 0, "reach": 1.0, "pinchSens": 0.22, "debug": 0,
        "ctlCrouchMode": 0, "deadzone": 0.18, "lookSens": 1.0, "invertY": 0, "walk": 1, "walkSpeed": 1.5,
        "res": 0, "fpsCap": 60, "menuScale": 1.0, "floatMenu": 1
    ]

    static let sliders: [String: SliderSpec] = [
        "smoothH": SliderSpec(min: 0, max: 1, step: 0.05),
        "lead": SliderSpec(min: 0, max: 100, step: 5),
        "reach": SliderSpec(min: 0.8, max: 2.2, step: 0.05),
        "pinchSens": SliderSpec(min: 0.14, max: 0.30, step: 0.01),
        "deadzone": SliderSpec(min: 0.05, max: 0.5, step: 0.01),
        "lookSens": SliderSpec(min: 0.4, max: 2.5, step: 0.05),
        "walkSpeed": SliderSpec(min: 0.5, max: 4.0, step: 0.1),
        "menuScale": SliderSpec(min: 0.7, max: 1.6, step: 0.05)
    ]

    static let controlActions: [ControlAction] = [
        ControlAction(id: "jump", title: "Pular", defaultCode: ""),
        ControlAction(id: "crouch", title: "Agachar", defaultCode: ""),
        ControlAction(id: "menu", title: "Abrir / fechar menu", defaultCode: "pad:buttonMenu"),
        ControlAction(id: "back", title: "Voltar", defaultCode: "pad:buttonB"),
        ControlAction(id: "recenter", title: "Centralizar vista", defaultCode: "pad:buttonY")
    ]

    @Published private(set) var vals: [String: Double]
    @Published private(set) var binds: [String: String]
    var onChange: ((String) -> Void)?

    init() {
        let d = UserDefaults.standard
        var v: [String: Double] = [:]
        for (k, def) in SettingsModel.defaults {
            let key = "set_" + k
            v[k] = d.object(forKey: key) == nil ? def : d.double(forKey: key)
        }
        vals = v
        var b: [String: String] = [:]
        for a in SettingsModel.controlActions {
            let key = "bind_" + a.id
            b[a.id] = d.object(forKey: key) == nil ? a.defaultCode : (d.string(forKey: key) ?? "")
        }
        binds = b
    }

    func get(_ k: String) -> Double { return vals[k] ?? SettingsModel.defaults[k] ?? 0 }
    func b(_ k: String) -> Bool { return get(k) > 0.5 }
    func bind(_ id: String) -> String { return binds[id] ?? "" }

    func set(_ k: String, _ v: Double) {
        var x = v
        if let s = SettingsModel.sliders[k] { x = max(s.min, min(s.max, x)) }
        if vals[k] == x { return }
        vals[k] = x
        UserDefaults.standard.set(x, forKey: "set_" + k)
        onChange?(k)
    }

    func toggle(_ k: String) { set(k, b(k) ? 0 : 1) }

    /// `f` = posição do controle deslizante (0...1).
    func setSlider(_ k: String, _ f: Double) {
        guard let s = SettingsModel.sliders[k] else { return }
        let fr = max(0, min(1, f))
        var v = s.min + (s.max - s.min) * fr
        if s.step > 0 { v = (((v - s.min) / s.step).rounded()) * s.step + s.min }
        set(k, Double((v * 1000).rounded() / 1000))
    }

    func fraction(_ k: String) -> Double {
        guard let s = SettingsModel.sliders[k], s.max > s.min else { return 0 }
        return max(0, min(1, (get(k) - s.min) / (s.max - s.min)))
    }

    func setBind(_ id: String, _ code: String) {
        if code != "" {
            for a in SettingsModel.controlActions where a.id != id && binds[a.id] == code {
                binds[a.id] = ""
                UserDefaults.standard.set("", forKey: "bind_" + a.id)
            }
        }
        binds[id] = code
        UserDefaults.standard.set(code, forKey: "bind_" + id)
        onChange?("bind")
    }

    func resetBinds() {
        for a in SettingsModel.controlActions { setBind(a.id, a.defaultCode) }
    }

    func resetAll() {
        for (k, def) in SettingsModel.defaults { set(k, def) }
        resetBinds()
    }

    var trackingParams: TrackingParams {
        var p = TrackingParams()
        p.smooth = Float(get("smoothH"))
        p.lead = Float(get("lead"))
        p.sens = Int(get("trkSens"))
        p.maxHands = Int(get("maxHands"))
        p.rate = Int(get("rate"))
        p.pinchOn = Float(get("pinchSens"))
        p.swap = b("swapHands")
        return p
    }

    // ---------- opções de escolha ----------

    static let handStyles: [(Double, String)] = [(0, "Translúcida"), (1, "Realista"), (2, "Contorno"), (3, "Ossos"), (4, "Oculta")]
    static let skins: [(Double, String)] = [(0, "Claro"), (1, "Médio"), (2, "Moreno"), (3, "Escuro"), (4, "Neutro")]
    static let skinColors: [UInt32] = [0xFFF3CFB7, 0xFFD9A37C, 0xFFA97250, 0xFF6C4533, 0xFFCDD6E4]

    /// Converte uma lista (valor, rótulo) no formato do ChoiceRow: ação "b:set:chave:valor".
    func choice(_ key: String, _ opts: [(Double, String)]) -> (options: [(String, String)], selected: Int) {
        var out: [(String, String)] = []
        var sel = 0
        let cur = get(key)
        for (i, o) in opts.enumerated() {
            out.append(("b:set:" + key + ":" + String(o.0), o.1))
            if abs(o.0 - cur) < 0.0001 { sel = i }
        }
        return (out, sel)
    }
}

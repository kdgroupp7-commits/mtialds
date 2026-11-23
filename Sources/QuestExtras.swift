import simd
import SwiftUI
import UIKit
import GameController

// MARK: - Controles (GameController): botões configuráveis, analógico esquerdo = andar, direito = girar a vista

/// Controles Bluetooth (Xbox, PlayStation, MFi) e teclado Bluetooth. Os botões são lidos a cada quadro.
final class ControllersModel: ObservableObject {
    struct Info: Identifiable {
        let id: String
        let name: String
        let battery: Int?     // 0...100
        let charging: Bool
    }

    struct PadButton {
        let id: String
        let label: String
        let read: (GCExtendedGamepad) -> GCControllerButtonInput?
    }

    static let padButtons: [PadButton] = [
        PadButton(id: "buttonA", label: "A", read: { $0.buttonA }),
        PadButton(id: "buttonB", label: "B", read: { $0.buttonB }),
        PadButton(id: "buttonX", label: "X", read: { $0.buttonX }),
        PadButton(id: "buttonY", label: "Y", read: { $0.buttonY }),
        PadButton(id: "leftShoulder", label: "L1", read: { $0.leftShoulder }),
        PadButton(id: "rightShoulder", label: "R1", read: { $0.rightShoulder }),
        PadButton(id: "leftTrigger", label: "L2", read: { $0.leftTrigger }),
        PadButton(id: "rightTrigger", label: "R2", read: { $0.rightTrigger }),
        PadButton(id: "buttonMenu", label: "Menu", read: { $0.buttonMenu }),
        PadButton(id: "buttonOptions", label: "Opções", read: { $0.buttonOptions }),
        PadButton(id: "leftThumbstickButton", label: "L3", read: { $0.leftThumbstickButton }),
        PadButton(id: "rightThumbstickButton", label: "R3", read: { $0.rightThumbstickButton }),
        PadButton(id: "dpadUp", label: "Cruz ↑", read: { $0.dpad.up }),
        PadButton(id: "dpadDown", label: "Cruz ↓", read: { $0.dpad.down }),
        PadButton(id: "dpadLeft", label: "Cruz ←", read: { $0.dpad.left }),
        PadButton(id: "dpadRight", label: "Cruz →", read: { $0.dpad.right })
    ]

    /// Nome legível de um código salvo ("pad:buttonA" ou "key:Espaço").
    static func name(for code: String) -> String {
        if code.isEmpty { return "" }
        if code.hasPrefix("pad:") {
            let id = String(code.dropFirst(4))
            return "Botão " + (padButtons.first(where: { $0.id == id })?.label ?? id)
        }
        if code.hasPrefix("key:") { return "Tecla " + String(code.dropFirst(4)) }
        return code
    }

    @Published private(set) var list: [Info] = []
    @Published private(set) var lastPressed = ""
    @Published private(set) var listening: String?
    weak var app: AppModel? {
        didSet { refresh() }
    }

    /// Analógico direito (gira a vista) e esquerdo (anda), já com zona morta aplicada. Lidos pelo Renderer.
    private(set) var stick = SIMD2<Float>(0, 0)
    private(set) var walk = SIMD2<Float>(0, 0)

    private var prevDown = Set<String>()
    private var keyDown = Set<String>()
    private var listenStart: CFTimeInterval = 0
    private var jumpPending = false
    private var crouchHeld = false
    private var crouchTog = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        var out: [Info] = []
        for c in GCController.controllers() {
            var level: Int? = nil
            var charging = false
            if let b = c.battery {
                if b.batteryLevel >= 0 { level = Int((b.batteryLevel * 100).rounded()) }
                charging = (b.batteryState == .charging)
            }
            let name = c.vendorName ?? c.productCategory
            out.append(Info(id: String(UInt(bitPattern: ObjectIdentifier(c).hashValue)), name: name, battery: level, charging: charging))
        }
        if GCController.controllers().isEmpty { stick = SIMD2<Float>(0, 0); walk = SIMD2<Float>(0, 0) }
        list = out
        app?.objectWillChange.send()
    }

    var padName: String { return list.first?.name ?? "" }

    // MARK: - ações configuráveis

    func listen(_ id: String) {
        if listening == id {
            listening = nil
        } else {
            listening = id
            listenStart = CACurrentMediaTime()
            app?.menu.showToast("Aperte o botão do controle")
        }
    }

    func clear(_ id: String) {
        app?.settings.setBind(id, "")
        if id == "crouch" { crouchHeld = false; crouchTog = false }
    }

    var crouching: Bool {
        return (app?.settings.get("ctlCrouchMode") ?? 0) > 0.5 ? crouchTog : crouchHeld
    }

    func takeJump() -> Bool {
        let j = jumpPending
        jumpPending = false
        return j
    }

    /// Teclado Bluetooth (vem do MetalView).
    func key(_ name: String, down: Bool) {
        let code = "key:" + name
        if down { keyDown.insert(code) } else { keyDown.remove(code) }
    }

    private func codeDown(_ code: String) {
        guard let app = app else { return }
        lastPressed = ControllersModel.name(for: code)
        if let id = listening {
            listening = nil
            app.settings.setBind(id, code)
            let title = SettingsModel.controlActions.first(where: { $0.id == id })?.title ?? id
            app.menu.showToast(title + " = " + ControllersModel.name(for: code))
            return
        }
        for a in SettingsModel.controlActions where app.settings.bind(a.id) == code {
            switch a.id {
            case "jump": jumpPending = true
            case "crouch":
                if app.settings.get("ctlCrouchMode") > 0.5 { crouchTog.toggle() } else { crouchHeld = true }
            case "menu": app.menu.activate("b:toggle")
            case "back": app.menu.activate("b:back")
            case "recenter": app.recenter()
            default: break
            }
        }
    }

    private func codeUp(_ code: String) {
        guard let app = app else { return }
        if app.settings.bind("crouch") == code && app.settings.get("ctlCrouchMode") < 0.5 { crouchHeld = false }
    }

    private func radial(_ x: Float, _ y: Float, _ dead: Float) -> SIMD2<Float> {
        let l = sqrt(x * x + y * y)
        if l <= dead { return SIMD2<Float>(0, 0) }
        let k = min(1, (l - dead) / max(1 - dead, 0.01)) / l
        return SIMD2<Float>(x * k, y * k)
    }

    /// Chamado pelo Renderer a cada quadro: lê botões e analógicos.
    func poll() {
        let dead = Float(app?.settings.get("deadzone") ?? 0.18)
        var down = keyDown
        var rs = SIMD2<Float>(0, 0)
        var ls = SIMD2<Float>(0, 0)
        for c in GCController.controllers() {
            guard let pad = c.extendedGamepad else { continue }
            let r = SIMD2<Float>(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
            let l = SIMD2<Float>(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            if simd_length(r) > simd_length(rs) { rs = r }
            if simd_length(l) > simd_length(ls) { ls = l }
            for b in ControllersModel.padButtons {
                if let btn = b.read(pad), btn.isPressed || btn.value > 0.6 { down.insert("pad:" + b.id) }
            }
        }
        stick = radial(rs.x, rs.y, dead)
        walk = radial(ls.x, ls.y, dead)
        for code in down.subtracting(prevDown) { codeDown(code) }
        for code in prevDown.subtracting(down) { codeUp(code) }
        prevDown = down
        if listening != nil && CACurrentMediaTime() - listenStart > 15 {
            listening = nil
            app?.menu.showToast("Tempo esgotado")
        }
    }
}

// MARK: - Transmitir (Cast)

/// O iOS só deixa espelhar a tela pela Central de Controle; aqui o app apenas detecta se a tela está sendo transmitida/gravada.
final class CastModel: ObservableObject {
    @Published private(set) var active = false
    weak var app: AppModel?

    init() {
        active = UIScreen.main.isCaptured
        NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.active = UIScreen.main.isCaptured
            self.app?.objectWillChange.send()
        }
    }
}

// MARK: - Biblioteca de apps (iOS não deixa listar apps instalados: atalhos fixos + favoritos do navegador)

struct LibraryApp: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let url: String      // "web:<url>" abre no navegador do Metulas
}

enum AppLibrary {
    static let apps: [LibraryApp] = [
        LibraryApp(id: "store", title: "Loja", subtitle: "App Store", icon: "bag.fill", url: "itms-apps://apps.apple.com/"),
        LibraryApp(id: "explore", title: "Explorar", subtitle: "Descobrir na web", icon: "sparkles", url: "web:https://www.youtube.com/"),
        LibraryApp(id: "people", title: "Pessoas", subtitle: "FaceTime", icon: "person.2.fill", url: "facetime://"),
        LibraryApp(id: "messages", title: "Mensagens", subtitle: "Conversar", icon: "message.fill", url: "sms:"),
        LibraryApp(id: "maps", title: "Mapas", subtitle: "Lugares e rotas", icon: "map.fill", url: "maps://"),
        LibraryApp(id: "music", title: "Música", subtitle: "Ouvir", icon: "music.note", url: "music://"),
        LibraryApp(id: "photos", title: "Fotos", subtitle: "Álbum do iPhone", icon: "photo.fill", url: "photos-redirect://"),
        LibraryApp(id: "files", title: "Arquivos (iOS)", subtitle: "App Arquivos", icon: "folder.fill", url: "shareddocuments://"),
        LibraryApp(id: "mail", title: "E-mail", subtitle: "Escrever", icon: "envelope.fill", url: "mailto:")
    ]
}

import SwiftUI
import MetalKit

/// MTKView que também recebe teclas (controles de óculos VR e teclados Bluetooth que mandam teclas).
final class KeyMTKView: MTKView {
    weak var controllers: ControllersModel?

    override var canBecomeFirstResponder: Bool { return true }

    private func name(_ press: UIPress) -> String? {
        guard let key = press.key else { return nil }
        let c = key.charactersIgnoringModifiers
        if c == " " { return "Espaço" }
        if !c.isEmpty && c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) { return c.uppercased() }
        return "#\(key.keyCode.rawValue)"
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let n = name(p) { controllers?.key(n, down: true); handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let n = name(p) { controllers?.key(n, down: false); handled = true }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for p in presses {
            if let n = name(p) { controllers?.key(n, down: false) }
        }
        super.pressesCancelled(presses, with: event)
    }
}

struct MetalView: UIViewRepresentable {
    let model: AppModel

    final class Coordinator: NSObject {
        var renderer: Renderer?

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            renderer?.addLook(yaw: Float(t.x) * 0.005, pitch: Float(t.y) * 0.005)
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = KeyMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.controllers = model.controllers
        if let r = Renderer(view: view, model: model) {
            context.coordinator.renderer = r
            model.renderer = r
            r.mtkView = view
            view.delegate = r
            DispatchQueue.main.async {
                model.renderInfo = r.summary
                model.menu.homeEnv = r.currentEnv
                model.audio.setEnvironment(r.currentEnv)
                r.applyPerformance()
                view.becomeFirstResponder()
            }
        } else {
            DispatchQueue.main.async { model.renderInfo = "ERRO renderer: " + Renderer.lastError }
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

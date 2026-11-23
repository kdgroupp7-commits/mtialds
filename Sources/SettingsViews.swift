import SwiftUI

// MARK: - janela flutuante

/// Aplica o deslocamento do menu: arrasto do usuário + posição "presa ao mundo" (muda quando a cabeça gira).
struct FloatWrap<Content: View>: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var fm: FloatModel
    let content: Content

    init(menu: MenuModel, fm: FloatModel, @ViewBuilder content: () -> Content) {
        self.menu = menu
        self.fm = fm
        self.content = content()
    }

    var body: some View {
        content.offset(CGSize(width: menu.offset.width + fm.offset.width,
                              height: menu.offset.height + fm.offset.height))
    }
}

// MARK: - grade de duas colunas (não preguiçosa: a altura do conteúdo é sempre exata)

struct TwoCols: View {
    let spacing: CGFloat
    let items: [AnyView]

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<((items.count + 1) / 2), id: \.self) { r in
                HStack(alignment: .top, spacing: spacing) {
                    items[r * 2]
                    if r * 2 + 1 < items.count {
                        items[r * 2 + 1]
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }
}

// MARK: - abas laterais

struct TabButton: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme
    let tab: MenuPage

    var body: some View {
        let id = "t:b:tab:" + tab.tabKey
        let active = menu.settingsTab == tab
        return Button(action: { menu.activate(id) }) {
            VStack(spacing: 3) {
                Image(systemName: tab.tabIcon)
                    .font(.system(size: 18, weight: .medium))
                Text(tab.tabLabel)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundColor(active ? Color.white : theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(active ? theme.accent : theme.card))
            .hoverFX(menu, id, theme, 14)
        }
        .buttonStyle(PlainButtonStyle())
        .target(id)
    }
}

struct TabSidebar: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme

    var body: some View {
        ScrollPanel(menu: menu, region: .tabs) {
            VStack(spacing: 6) {
                ForEach(MenuPage.settingsTabs, id: \.self) { t in
                    TabButton(menu: menu, theme: theme, tab: t)
                }
            }
        }
    }
}

// MARK: - linhas de configuração

struct SettingSliderRow: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var settings: SettingsModel
    let theme: Theme
    let key: String
    let title: String
    let format: (Double) -> String

    var body: some View {
        let s = menu.ts
        let id = "s:sl:set:" + key
        let f = settings.fraction(key)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 15 * s, weight: .medium))
                    .foregroundColor(theme.text)
                Spacer(minLength: 8)
                Text(format(settings.get(key)))
                    .font(.system(size: 14 * s))
                    .foregroundColor(theme.sub)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track).frame(height: 8)
                    Capsule().fill(theme.accent)
                        .frame(width: max(8, g.size.width * CGFloat(f)), height: 8)
                    Circle().fill(Color.white)
                        .frame(width: 22, height: 22)
                        .offset(x: max(0, min(g.size.width - 22, g.size.width * CGFloat(f) - 11)))
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            menu.touchLock = true
                            menu.applySlider("sl:set:" + key, Double(v.location.x / max(g.size.width, 1)))
                        }
                        .onEnded { _ in menu.touchLock = false }
                )
            }
            .frame(height: 30)
            .target(id)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
        .hoverFX(menu, id, theme)
    }
}

/// Escolha de uma lista de valores (ação "b:set:chave:valor").
struct SettingChoiceRow: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var settings: SettingsModel
    let theme: Theme
    let key: String
    let title: String
    let opts: [(Double, String)]

    var body: some View {
        let c = settings.choice(key, opts)
        return ChoiceRow(menu: menu, theme: theme, title: title, options: c.options, selected: c.selected)
    }
}

struct SettingToggleRow: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var settings: SettingsModel
    let theme: Theme
    let key: String
    let title: String
    let subtitle: String

    var body: some View {
        ToggleRow(menu: menu, theme: theme, action: "b:tgl:" + key, title: title,
                  subtitle: subtitle, isOn: settings.b(key))
    }
}

struct NoteText: View {
    let text: String
    let theme: Theme
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11 * scale))
            .foregroundColor(theme.sub)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Linha de botão do controle: toque, aperte o botão do controle e ele fica salvo.
struct BindRow: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var controllers: ControllersModel
    let theme: Theme
    let action: ControlAction

    var body: some View {
        let s = menu.ts
        let listening = controllers.listening == action.id
        let code = settings.bind(action.id)
        let mainId = "s:b:ctl:listen:" + action.id
        let clearId = "s:b:ctl:clear:" + action.id
        let sub: String = listening ? "Aperte um botão do controle…" : (code.isEmpty ? "Sem botão" : ControllersModel.name(for: code))
        return HStack(spacing: 8) {
            Button(action: { menu.activate(mainId) }) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .font(.system(size: 15 * s, weight: .medium))
                            .foregroundColor(theme.text)
                        Text(sub)
                            .font(.system(size: 12 * s))
                            .foregroundColor(listening ? theme.accent : theme.sub)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: listening ? "dot.radiowaves.left.and.right" : "gamecontroller")
                        .font(.system(size: 17))
                        .foregroundColor(listening ? theme.accent : theme.sub)
                }
                .contentShape(Rectangle())
                .hoverFX(menu, mainId, theme)
            }
            .buttonStyle(PlainButtonStyle())
            .target(mainId)
            if !code.isEmpty && !listening {
                Button(action: { menu.activate(clearId) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.text)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.toggleOff))
                        .overlay(Circle().fill(menu.hoverId == clearId ? theme.hover : Color.clear))
                }
                .buttonStyle(PlainButtonStyle())
                .target(clearId)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(listening ? theme.accent.opacity(0.25) : theme.card))
    }
}

// MARK: - páginas

struct HandsPage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var app: AppModel
    @ObservedObject var tracker: HandTracker
    @ObservedObject var settings: SettingsModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        return VStack(spacing: 10) {
            SectionTitle(text: "Mãos", theme: theme, scale: s)
            ToggleRow(menu: menu, theme: theme, action: "b:tog:hands", title: "Rastreio de mãos",
                      subtitle: "Usa a câmera escolhida abaixo para detectar suas mãos", isOn: menu.handTracking)
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "handStyle",
                             title: "Visual da mão", opts: SettingsModel.handStyles)
            if settings.get("handStyle") == 1 {
                SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "skin",
                                 title: "Tom da pele", opts: SettingsModel.skins)
            }
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "maxHands",
                             title: "Número de mãos", opts: [(1, "1 mão"), (2, "2 mãos")])
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "primaryHand",
                             title: "Mão que controla o menu", opts: [(0, "Auto"), (1, "Direita"), (2, "Esquerda")])
            SettingToggleRow(menu: menu, settings: settings, theme: theme, key: "swapHands",
                             title: "Inverter esquerda/direita", subtitle: "Use se o aplicativo confundir qual é qual")
            SettingToggleRow(menu: menu, settings: settings, theme: theme, key: "dwell",
                             title: "Clique segurando o dedo", subtitle: "Segure o ponteiro 1 s sobre um botão")
            ToggleRow(menu: menu, theme: theme, action: "b:tog:camera", title: "Mostrar a câmera",
                      subtitle: "Miniatura da câmera no canto da tela", isOn: app.showCamera)
            InfoRow(theme: theme, scale: s, title: "Estado", value: tracker.status)
            CameraVRSection(menu: menu, app: app, tracker: tracker, theme: theme)
            SectionTitle(text: "Movimento", theme: theme, scale: s)
            ToggleRow(menu: menu, theme: theme, action: "b:tog:gyro", title: "Giroscópio",
                      subtitle: "Gira a vista junto com o aparelho", isOn: app.gyroEnabled)
            ActionRow(menu: menu, theme: theme, action: "b:reset", title: "Centralizar vista",
                      subtitle: "", icon: "scope")
            ToggleRow(menu: menu, theme: theme, action: "b:tog:passthrough", title: "Passthrough",
                      subtitle: "Mostra a câmera escolhida no lugar do ambiente", isOn: menu.passthrough)
        }
    }
}

struct TrackingPage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var tracker: HandTracker
    @ObservedObject var settings: SettingsModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        return VStack(spacing: 10) {
            SectionTitle(text: "Rastreamento das mãos", theme: theme, scale: s)
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "trkSens",
                             title: "Sensibilidade do rastreio", opts: [(0, "Estável"), (1, "Normal"), (2, "Sensível")])
            NoteText(text: "Sensível segura a mão em poses difíceis, mas pode detectar mãos falsas.", theme: theme, scale: s)
            SettingSliderRow(menu: menu, settings: settings, theme: theme, key: "smoothH",
                             title: "Suavização das mãos", format: { String(Int(($0 * 100).rounded())) + "%" })
            SettingSliderRow(menu: menu, settings: settings, theme: theme, key: "lead",
                             title: "Antecipação (compensa atraso)", format: { String(Int($0.rounded())) + " ms" })
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "rate",
                             title: "Taxa de rastreamento", opts: [(0, "Auto"), (20, "20 Hz"), (30, "30 Hz"), (60, "60 Hz")])
            SettingSliderRow(menu: menu, settings: settings, theme: theme, key: "reach",
                             title: "Alcance dos braços", format: { String(format: "%.2f×", $0) })
            SettingSliderRow(menu: menu, settings: settings, theme: theme, key: "pinchSens",
                             title: "Sensibilidade da pinça", format: { String(format: "%.2f", $0) })
            NoteText(text: "Pinça: valores maiores fecham com os dedos mais afastados. Alcance: 1× faz a mão desenhada coincidir com a mão real.", theme: theme, scale: s)
            SectionTitle(text: "Ao vivo", theme: theme, scale: s)
            InfoRow(theme: theme, scale: s, title: "Rastreamento",
                    value: tracker.hz > 0 ? "\(tracker.hz) Hz · \(tracker.inferMs) ms" : "sem mãos")
            InfoRow(theme: theme, scale: s, title: "Estado", value: tracker.status)
        }
    }
}

struct ControlsPage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var controllers: ControllersModel
    @ObservedObject var settings: SettingsModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        return VStack(spacing: 10) {
            SectionTitle(text: "Controle Bluetooth", theme: theme, scale: s)
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 34))
                    .foregroundColor(theme.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controllers.padName.isEmpty ? "Nenhum controle" : controllers.padName)
                        .font(.system(size: 15 * s, weight: .semibold))
                        .foregroundColor(theme.text)
                    Text("Analógico esquerdo = andar · direito = girar a vista")
                        .font(.system(size: 12 * s))
                        .foregroundColor(theme.sub)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
            InfoRow(theme: theme, scale: s, title: "Último botão apertado",
                    value: controllers.lastPressed.isEmpty ? "—" : controllers.lastPressed)

            SectionTitle(text: "Botões", theme: theme, scale: s)
            ForEach(SettingsModel.controlActions, id: \.id) { a in
                BindRow(menu: menu, settings: settings, controllers: controllers, theme: theme, action: a)
            }
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "ctlCrouchMode",
                             title: "Agachar", opts: [(0, "Segurar"), (1, "Alternar")])
            ActionRow(menu: menu, theme: theme, action: "b:ctl:reset", title: "Restaurar botões",
                      subtitle: "Volta ao padrão", icon: "arrow.counterclockwise")

            SectionTitle(text: "Analógicos", theme: theme, scale: s)
            SettingToggleRow(menu: menu, settings: settings, theme: theme, key: "walk",
                             title: "Andar com o analógico esquerdo", subtitle: "Move você pelo ambiente")
            SettingSliderRow(menu: menu, settings: settings, theme: theme, key: "walkSpeed",
                             title: "Velocidade de andar", format: { String(format: "%.1f m/s", $0) })
            SettingSliderRow(menu: menu, settings: settings, theme: theme, key: "lookSens",
                             title: "Velocidade de girar a vista", format: { String(format: "%.2f×", $0) })
            SettingSliderRow(menu: menu, settings: settings, theme: theme, key: "deadzone",
                             title: "Zona morta", format: { String(Int(($0 * 100).rounded())) + "%" })
            SettingToggleRow(menu: menu, settings: settings, theme: theme, key: "invertY",
                             title: "Inverter eixo vertical", subtitle: "Para cima olha para baixo")
            NoteText(text: "Toque na caixinha de um botão e aperte o botão do controle: ele fica salvo. Pareie o controle antes em Ajustes > Bluetooth do iPhone. Controles que mandam teclas também funcionam. Se nada aparecer em \"Último botão apertado\", troque o modo do controle (Android/iOS).",
                     theme: theme, scale: s)
        }
        .onAppear { controllers.refresh() }
    }
}

struct PerformancePage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var tracker: HandTracker
    @ObservedObject var settings: SettingsModel
    @ObservedObject var perf: PerfModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        return VStack(spacing: 10) {
            SectionTitle(text: "Imagem", theme: theme, scale: s)
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "res",
                             title: "Resolução", opts: [(0, "Auto"), (1, "Baixa"), (2, "Média"), (3, "Alta")])
            SettingChoiceRow(menu: menu, settings: settings, theme: theme, key: "fpsCap",
                             title: "Limite de quadros", opts: [(30, "30 fps"), (60, "60 fps")])
            SectionTitle(text: "Ao vivo", theme: theme, scale: s)
            InfoRow(theme: theme, scale: s, title: "Quadros por segundo", value: "\(perf.fps) fps")
            InfoRow(theme: theme, scale: s, title: "Resolução atual", value: perf.scaleText)
            InfoRow(theme: theme, scale: s, title: "Rastreamento de mãos",
                    value: tracker.hz > 0 ? "\(tracker.hz) Hz · \(tracker.inferMs) ms" : "desligado")
            SettingToggleRow(menu: menu, settings: settings, theme: theme, key: "debug",
                             title: "Mostrar dados na tela", subtitle: "FPS e rastreamento no canto da tela")
            NoteText(text: "Em \"Auto\" a resolução se ajusta sozinha para manter os quadros por segundo estáveis, e a taxa de rastreamento também. Se estiver pesado, use Resolução \"Baixa\", limite de 30 fps e rastreamento sensível desligado.",
                     theme: theme, scale: s)
        }
    }
}

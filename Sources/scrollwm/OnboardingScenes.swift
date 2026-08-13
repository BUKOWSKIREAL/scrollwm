import AppKit
import ScrollCore
import SwiftUI

// ============================================================
//  引导页的各幕内容。纸带舞台直接调 LayoutEngine，
//  演示里看到的滚动、停靠、列宽就是运行时的真实行为。
// ============================================================

// MARK: - 序幕

struct OvertureScene: View {
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 48) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(WelcomePalette.blue)
                        .frame(width: 5, height: 5)
                        .shadow(color: WelcomePalette.blue, radius: 6)
                    Text("WELCOME TO A DIFFERENT DESKTOP")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(2.1)
                        .foregroundStyle(.white.opacity(0.42))
                }
                .padding(.bottom, 18)

                Text("ScrollWM")
                    .font(.system(size: 54, weight: .ultraLight))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.96))

                Text("窗口管理，不必再像整理桌面。")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("把它们放进一条没有尽头的纸带。")
                    Text("焦点走到哪里，桌面就跟到哪里。")
                }
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.top, 10)

                HStack(spacing: 10) {
                    WelcomeKeycap(label: "Enter")
                    Text("按 Enter 开始导览")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                }
                .padding(.top, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .blur(radius: revealed ? 0 : 12)
            .opacity(revealed ? 1 : 0)
            .offset(x: revealed ? 0 : -18)

            OvertureStripVisual(revealed: revealed)
                .frame(width: 340, height: 330)
                .clipped()
        }
        .padding(.horizontal, 68)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.84).delay(0.08)) {
                revealed = true
            }
        }
    }
}

/// 五张窗口从同一点展开成纸带；中心列使用与实际焦点环一致的渐变。
private struct OvertureStripVisual: View {
    let revealed: Bool

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [WelcomePalette.indigo.opacity(0.34), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 175
            )
            .frame(width: 350, height: 350)

            ForEach(Array(Self.columns.enumerated()), id: \.offset) { index, column in
                HeroColumn(focused: index == 2, tint: column.tint)
                    .frame(width: column.width, height: column.height)
                    .rotationEffect(.degrees(revealed ? column.rotation : 0))
                    .offset(
                        x: revealed ? column.x : 0,
                        y: revealed ? column.y : 18
                    )
                    .opacity(revealed ? column.opacity : 0)
                    .zIndex(index == 2 ? 10 : Double(5 - abs(index - 2)))
                    .animation(
                        .spring(response: 0.78, dampingFraction: 0.78)
                            .delay(0.12 + Double(index) * 0.045),
                        value: revealed
                    )
            }
        }
    }

    private struct ColumnSpec {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let rotation: Double
        let opacity: Double
        let tint: Color
    }

    private static let columns: [ColumnSpec] = [
        .init(x: -126, y: 14, width: 68, height: 150, rotation: -7, opacity: 0.30, tint: WelcomePalette.blue),
        .init(x: -72, y: 2, width: 82, height: 190, rotation: -3, opacity: 0.62, tint: WelcomePalette.teal),
        .init(x: 0, y: -4, width: 106, height: 236, rotation: 0, opacity: 1, tint: WelcomePalette.violet),
        .init(x: 78, y: 5, width: 82, height: 186, rotation: 3, opacity: 0.58, tint: WelcomePalette.magenta),
        .init(x: 132, y: 16, width: 66, height: 146, rotation: 7, opacity: 0.28, tint: WelcomePalette.blue),
    ]
}

private struct HeroColumn: View {
    let focused: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == 0 ? tint.opacity(0.9) : .white.opacity(0.18))
                        .frame(width: 5, height: 5)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(.white.opacity(0.045))

            VStack(alignment: .leading, spacing: 8) {
                Capsule()
                    .fill(tint.opacity(0.76))
                    .frame(width: focused ? 42 : 28, height: 5)
                ForEach([0.82, 0.58, 0.72, 0.44], id: \.self) { fraction in
                    Capsule()
                        .fill(.white.opacity(focused ? 0.14 : 0.09))
                        .frame(maxWidth: 64 * fraction, minHeight: 4, maxHeight: 4)
                }
                Spacer()
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.075, green: 0.08, blue: 0.105).opacity(0.97))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? AnyShapeStyle(WelcomePalette.ring) : AnyShapeStyle(Color.white.opacity(0.1)),
                              lineWidth: focused ? 2.4 : 0.7)
        }
        .shadow(color: focused ? WelcomePalette.violet.opacity(0.62) : .black.opacity(0.35),
                radius: focused ? 20 : 9, y: 7)
    }
}

// MARK: - 纸带舞台

/// 一块微缩桌面：窗口位置由 LayoutEngine 算出，弹簧动画由 SwiftUI 跑。
struct StripStage: View {
    @EnvironmentObject var model: WelcomeModel

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let placements = model.placements(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    stageSurface
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    ForEach(placements, id: \.id) { placement in
                        DemoWindow(
                            id: placement.id,
                            focused: model.demo.focusedID == placement.id,
                            showRing: model.ringOn && model.demo.focusedID == placement.id,
                            parked: placement.park != .none
                        )
                        .frame(
                            width: placement.frame.width,
                            height: placement.frame.height,
                            alignment: .top
                        )
                        .offset(x: placement.frame.minX, y: placement.frame.minY)
                        .onTapGesture { model.focus(id: placement.id) }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .animation(.spring(response: 0.5, dampingFraction: 0.84), value: model.demo)
                .animation(.spring(response: 0.3, dampingFraction: 0.88), value: model.ringOn)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.7)
            )
            .padding(6)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.035)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
        .contentShape(Rectangle())
        .gesture(
            // 甩一下也能翻列：和真实的 Command 拖动语义方向一致
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width < -40 {
                        model.focusNeighbor(.right)
                    } else if value.translation.width > 40 {
                        model.focusNeighbor(.left)
                    }
                }
        )
    }

    private var stageSurface: some View {
        LinearGradient(
            colors: [.white.opacity(0.055), .white.opacity(0.015)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

private struct DemoWindow: View {
    let id: WindowID
    let focused: Bool
    let showRing: Bool
    let parked: Bool

    private var app: (id: WindowID, name: String, tint: Color) {
        WelcomeModel.demoApps.first { $0.id == id } ?? WelcomeModel.demoApps[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(ring)
        .shadow(color: .black.opacity(focused ? 0.5 : 0.3), radius: focused ? 18 : 9, y: 5)
        .opacity(parked ? 0.75 : 1)
    }

    @ViewBuilder
    private var ring: some View {
        if showRing {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WelcomePalette.ring, lineWidth: 3)
                .shadow(color: WelcomePalette.violet.opacity(0.75), radius: 9)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 5) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34),
                     Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.24, green: 0.8, blue: 0.31)], id: \.self) { color in
                Circle()
                    .fill(color.opacity(focused ? 0.95 : 0.35))
                    .frame(width: 7, height: 7)
            }
            Text(app.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(focused ? 0.7 : 0.4))
                .padding(.leading, 4)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(.white.opacity(0.05))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule()
                .fill(app.tint.opacity(focused ? 0.85 : 0.4))
                .frame(width: 46, height: 6)
            ForEach(0..<4, id: \.self) { row in
                Capsule()
                    .fill(.white.opacity(focused ? 0.16 : 0.09))
                    .frame(width: [0.9, 0.62, 0.78, 0.44][row] * 120, height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 键帽

struct KeyCapGrid: View {
    @EnvironmentObject var model: WelcomeModel

    private static let featured: [WMAction] = [
        .focusLeft, .focusRight, .cycleWidth,
        .moveLeft, .moveRight, .toggleFullWidth,
        .zoomIn, .zoomOut, .toggleFloat,
        .centerColumn, .closeWindow, .retile,
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(Self.featured.enumerated()), id: \.element) { index, action in
                KeyCapRow(action: action, index: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KeyCapRow: View {
    let action: WMAction
    let index: Int
    @EnvironmentObject var model: WelcomeModel
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {
            Text(action.showcaseCombo.map(KeyComboText.display) ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.82))
                .frame(minWidth: 46)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(hovering ? 0.2 : 0.12), .white.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.4 : 0.16), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.4), radius: hovering ? 8 : 3, y: 2)

            Text(action.title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.5))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .scaleEffect(hovering ? 1.04 : 1, anchor: .leading)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .onHover { inside in
            hovering = inside
            if inside { model.noteHover() }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .onAppear {
            // 逐格错峰浮现，整片键帽像被依次点亮
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.045)) {
                appeared = true
            }
        }
    }
}

// MARK: - 授权卡片

struct PermissionCard: View {
    @EnvironmentObject var model: WelcomeModel
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            statusBadge

            Text(model.trusted ? "辅助功能已授权" : "还差一个辅助功能权限")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))

            if !model.trusted {
                PrimaryButton(title: "打开系统设置授权", accent: WelcomePalette.teal) {
                    model.requestPermission()
                }
                Text("在「隐私与安全性 → 辅助功能」里勾选 ScrollWM，勾上就会自动继续")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                Label("ScrollWM 住在菜单栏，随时可以打开设置", systemImage: "menubar.arrow.up.rectangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    model.trusted ? AnyShapeStyle(WelcomePalette.ring) : AnyShapeStyle(Color.white.opacity(0.09)),
                    lineWidth: model.trusted ? 1.5 : 1
                )
        )
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: model.trusted)
    }

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: 62, height: 62)
                .scaleEffect(pulse && !model.trusted ? 1.18 : 1)
                .opacity(pulse && !model.trusted ? 0.35 : 1)
            Circle()
                .fill(accent.opacity(0.2))
                .frame(width: 48, height: 48)
            Image(systemName: model.trusted ? "checkmark" : "lock.open")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(accent)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var accent: Color {
        model.trusted ? WelcomePalette.teal : Color(red: 0.96, green: 0.72, blue: 0.35)
    }
}

// MARK: - 文案 + 本章控件

struct ChapterCopy: View {
    let chapter: WelcomeChapter
    @EnvironmentObject var model: WelcomeModel

    var body: some View {
        VStack(spacing: 12) {
            if !chapter.title.isEmpty {
                Text(chapter.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            if !chapter.body.isEmpty {
                Text(chapter.body)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.52))
                    .frame(maxWidth: 540)
            }
            controls
            if !chapter.hint.isEmpty {
                HintLine(text: chapter.hint, satisfied: model.hasExploredCurrent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var controls: some View {
        switch chapter {
        case .width:
            HStack(spacing: 8) {
                ForEach(WelcomeModel.spec.widthPresets, id: \.self) { preset in
                    PresetChip(
                        label: Self.presetLabel(preset),
                        active: isActive(preset),
                        accent: chapter.accent
                    ) {
                        model.setFocusedWidth(preset)
                    }
                }
                PresetChip(label: "全宽", active: isActive(1.0), accent: chapter.accent) {
                    model.toggleFullWidth()
                }
            }
            .padding(.top, 4)
        case .ring:
            HStack(spacing: 10) {
                Text("焦点环")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                GlowSwitch(isOn: model.ringOn) { model.toggleRing() }
            }
            .padding(.top, 4)
        default:
            EmptyView()
        }
    }

    private func isActive(_ preset: Double) -> Bool {
        guard let fraction = model.demo.focusedColumn?.fraction else { return false }
        return abs(fraction - preset) < 0.02
    }

    private static func presetLabel(_ value: Double) -> String {
        switch value {
        case 0.3..<0.4: return "1/3"
        case 0.45..<0.55: return "1/2"
        case 0.6..<0.7: return "2/3"
        default: return String(format: "%.2f", value)
        }
    }
}

private struct PresetChip: View {
    let label: String
    let active: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .medium, design: .rounded))
                .foregroundStyle(active ? .white : .white.opacity(hovering ? 0.85 : 0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        active
                            ? AnyShapeStyle(accent.opacity(0.55))
                            : AnyShapeStyle(Color.white.opacity(hovering ? 0.12 : 0.06))
                    )
                )
                .overlay(
                    Capsule().strokeBorder(.white.opacity(active ? 0.35 : 0.1), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: active)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct GlowSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(WelcomePalette.ring) : AnyShapeStyle(Color.white.opacity(0.14)))
                    .frame(width: 46, height: 26)
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .padding(.horizontal, 3)
            }
            .frame(width: 46, height: 26)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isOn)
    }
}

/// 没动手之前轻轻呼吸提示；试过之后安静下来，不再抢注意力
private struct HintLine: View {
    let text: String
    let satisfied: Bool
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 5) {
            if satisfied {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11.5))
        }
        .foregroundStyle(.white.opacity(satisfied ? 0.3 : (breathing ? 0.66 : 0.34)))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .animation(.easeOut(duration: 0.3), value: satisfied)
    }
}

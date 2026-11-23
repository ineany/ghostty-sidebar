import AppKit
import GhosttyBridge
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: SidebarStore
    @EnvironmentObject private var dock: DockController
    @EnvironmentObject private var sessions: SessionTracker
    @AppStorage(SettingKey.groupByProject) private var groupByProject = false
    let isMock: Bool

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(isMock: isMock)
            Rectangle().fill(Mocha.surface0).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Mocha.surface0).frame(height: 1)
            if dock.needsAccessibility { AccessibilityBanner() }
            FooterView()
        }
        .background(Mocha.mantle.opacity(Mocha.backgroundOpacity))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Mocha.surface0).frame(width: 1)
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .trailing) { ResizeHandle(axis: .horizontal) }
        .overlay(alignment: .bottom) { ResizeHandle(axis: .vertical) }
        .contextMenu { SettingsMenuItems() }
        .onAppear { dock.reloadScreens() }
    }

    @ViewBuilder
    private var content: some View {
        if !store.ghosttyRunning {
            EmptyStateView(symbol: "moon.zzz", message: "Ghostty가 실행 중이 아닙니다")
        } else if store.windows.isEmpty {
            if store.lastError != nil {
                EmptyStateView(symbol: "exclamationmark.circle", message: "Ghostty 상태를 읽지 못했습니다")
            } else if sessions.hasClosedSessions {
                ScrollView(showsIndicators: false) {
                    RestoreSection().padding(.horizontal, 8).padding(.vertical, 12)
                }
            } else if store.hasLoaded {
                EmptyStateView(symbol: "rectangle.dashed", message: "열린 창이 없습니다")
            } else {
                ProgressView().controlSize(.small).tint(Mocha.overlay1)
            }
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if groupByProject {
                        ProjectList()
                    } else {
                        ForEach(store.windows) { window in
                            WindowSection(window: window)
                        }
                    }
                    if sessions.hasClosedSessions {
                        RestoreSection()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Settings menu (header button and right-click)

/// Shared by the header's settings button and the sidebar's right-click menu.
private struct SettingsMenuItems: View {
    @EnvironmentObject private var store: SidebarStore
    @EnvironmentObject private var dock: DockController
    @EnvironmentObject private var sessions: SessionTracker
    @AppStorage(SettingKey.animateBusy) private var animateBusy = true
    @AppStorage(SettingKey.groupByProject) private var groupByProject = false

    var body: some View {
        Button("새로 고침") { store.refresh(force: true) }
        Divider()
        Section("모니터") {
            ForEach(dock.screens) { screen in
                Toggle(isOn: Binding(
                    get: { dock.effectiveScreenName == screen.id },
                    set: { if $0 { dock.moveTo(screenName: screen.id) } }
                )) {
                    Text(screen.isPrimary ? "\(screen.id) (주 모니터)" : screen.id)
                }
            }
        }
        Divider()
        Toggle("탭 클릭 시 Ghostty 창 붙이기", isOn: $dock.snapOnSelect)
        Toggle("붙일 때 남은 너비 채우기", isOn: $dock.snapFillWidth)
            .disabled(!dock.snapOnSelect)
        Toggle("자동 숨기기", isOn: $dock.autoHide)
        Button("사이드바 위치와 크기 초기화") { dock.resetSize() }
        Divider()
        Toggle("Ghostty 창 자동 정렬", isOn: $dock.autoArrange)
            .disabled(dock.autoHide)
        Button("지금 Ghostty 창 정렬") { dock.arrangeNow() }
            .disabled(dock.autoHide)
        Divider()
        Toggle("작업 중 회전 애니메이션", isOn: $animateBusy)
        Toggle("세션 비용 표시", isOn: $sessions.showCost)
        Toggle("프로젝트별로 묶기", isOn: $groupByProject)
        Divider()
        Toggle("세션 자동 저장", isOn: $sessions.autoSave)
        Button("지금 세션 저장") { sessions.saveNow() }
        Divider()
        Button("사이드바 종료") { NSApp.terminate(nil) }
    }
}

/// Thin grab area on the right edge (width) or bottom edge (height).
/// Uses the global mouse position, so the panel resizing under the cursor
/// does not disturb the drag.
private struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }

    @EnvironmentObject private var dock: DockController
    let axis: Axis
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let active = hovering || dragging
        Rectangle()
            .fill(active ? Mocha.mauve.opacity(0.55) : Color.clear)
            .frame(width: axis == .horizontal ? 3 : nil, height: axis == .vertical ? 3 : nil)
            .padding(axis == .horizontal ? .horizontal : .vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        dragging = true
                        let mouse = NSEvent.mouseLocation
                        if axis == .horizontal { dock.resizeWidth(toMouseX: mouse.x) }
                        else { dock.resizeHeight(toMouseY: mouse.y) }
                    }
                    .onEnded { _ in
                        dragging = false
                        dock.endResize()
                    }
            )
            .help(axis == .horizontal ? "끌어서 너비 조절" : "끌어서 높이 조절, 맨 아래로 끌면 전체 높이")
    }
}

private struct SettingsButton: View {
    @EnvironmentObject private var dock: DockController

    var body: some View {
        Menu {
            SettingsMenuItems()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Mocha.overlay1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .simultaneousGesture(TapGesture().onEnded { dock.reloadScreens() })
        .help("설정: 모니터 이동, 창 정렬")
    }
}

// MARK: - Header / footer

private struct HeaderView: View {
    @EnvironmentObject private var store: SidebarStore
    let isMock: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("❯")
                .font(Typo.mono(13, weight: .bold))
                .foregroundStyle(Mocha.mauve)
            Text("ghostty")
                .font(Typo.mono(13, weight: .bold))
                .foregroundStyle(Mocha.text)
            if isMock {
                Text("mock")
                    .font(Typo.mono(9.5, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Mocha.surface0))
                    .foregroundStyle(Mocha.overlay1)
            }
            Spacer(minLength: 4)
            CountBadge(label: "대기", count: store.idleCount, color: Mocha.green)
            CountBadge(label: "작업", count: store.busyCount, color: Mocha.peach)
            NewTabButton()
            SettingsButton()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .modifier(MoveByDrag())
    }
}

/// Dragging the header moves the panel. Like `ResizeHandle`, it reads the global
/// mouse position, because the view moves together with the panel.
private struct MoveByDrag: ViewModifier {
    @EnvironmentObject private var dock: DockController
    @State private var dragging = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            dock.beginMove(translation: value.translation)
                        }
                        dock.move(toMouse: NSEvent.mouseLocation)
                    }
                    .onEnded { _ in
                        dragging = false
                        dock.endMove()
                    }
            )
            .help("머리글을 끌어서 사이드바 옮기기")
    }
}

private struct CountBadge: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        let active = count > 0
        HStack(spacing: 4) {
            Text(label).font(Typo.ui(10, weight: .medium))
            Text("\(count)").font(Typo.mono(11, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(active ? color.opacity(0.16) : Mocha.surface0.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(active ? color.opacity(0.35) : .clear, lineWidth: 1)
        )
        .foregroundStyle(active ? color : Mocha.overlay0)
        .help("\(label) \(count)개")
    }
}

/// Shown while Accessibility is missing: without it no Ghostty window can move.
private struct AccessibilityBanner: View {
    @EnvironmentObject private var dock: DockController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Mocha.peach)
                Text("손쉬운 사용 권한 필요")
                    .font(Typo.ui(11.5, weight: .semibold))
                    .foregroundStyle(Mocha.text)
            }
            Text("권한이 없으면 Ghostty 창을 옮기거나 붙일 수 없습니다. 설정에서 Ghostty Sidebar를 켜 주세요.")
                .font(Typo.ui(10.5))
                .foregroundStyle(Mocha.subtext0)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                dock.openAccessibilitySettings()
            } label: {
                Text("설정 열기")
                    .font(Typo.ui(11, weight: .semibold))
                    .foregroundStyle(Mocha.crust)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Mocha.peach))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Mocha.peach.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Mocha.peach.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

private struct FooterView: View {
    @EnvironmentObject private var store: SidebarStore
    @EnvironmentObject private var dock: DockController
    @EnvironmentObject private var sessions: SessionTracker

    /// 24-hour clock, independent of the system's 12/24-hour setting.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            if let message = dock.lastArrangeMessage {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Mocha.teal)
                line(message, color: Mocha.teal)
            } else if let error = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Mocha.yellow)
                line(error, color: Mocha.yellow)
            } else if let time = store.lastRefresh {
                Circle().fill(Mocha.green.opacity(0.8)).frame(width: 5, height: 5)
                Text(Self.clock.string(from: time))
                    .font(Typo.mono(10.5))
                    .foregroundStyle(Mocha.overlay1)
                    .help(sessions.lastSaved.map { "세션 저장: \(Self.clock.string(from: $0))" } ?? "")
                if sessions.showCost, let today = sessions.todayCost {
                    Text("오늘 \(CostText.format(today))")
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Mocha.yellow.opacity(0.9))
                        .help("오늘 쓴 모든 Claude 세션의 API 환산 비용입니다. 닫힌 세션과 서브에이전트를 포함합니다.")
                }
            } else {
                Text("불러오는 중").font(Typo.ui(10.5)).foregroundStyle(Mocha.overlay1)
            }
            Spacer(minLength: 4)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Mocha.overlay1)
            }
            .buttonStyle(.borderless)
            .help("사이드바 종료")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typo.ui(10.5))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }
}

private struct EmptyStateView: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Mocha.surface2)
            Text(message)
                .font(Typo.ui(12))
                .foregroundStyle(Mocha.overlay1)
        }
        .padding()
    }
}

// MARK: - Window section and rows

private struct WindowSection: View {
    let window: GhosttyWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A window with one tab needs no heading: the row says it all.
            if window.tabs.count > 1 { header }
            ForEach(window.tabs) { tab in
                TabRow(tab: tab, isFrontWindow: window.index == 1)
            }
        }
        .padding(.vertical, window.tabs.count > 1 ? 6 : 0)
    }

    private var header: some View {
            HStack(spacing: 6) {
                Text("창 \(window.index)")
                    .font(Typo.ui(10.5, weight: .semibold))
                    .foregroundStyle(window.index == 1 ? Mocha.lavender : Mocha.overlay1)
                if window.index == 1 {
                    Text("맨 앞")
                        .font(Typo.ui(9.5, weight: .medium))
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Mocha.lavender.opacity(0.14)))
                        .foregroundStyle(Mocha.lavender)
                }
                Rectangle().fill(Mocha.surface0).frame(height: 1)
                Text("\(window.tabs.count)")
                    .font(Typo.mono(10.5))
                    .foregroundStyle(Mocha.overlay0)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
    }
}

// MARK: - Project view

/// Tabs from every window, grouped by project folder. Projects appear in the
/// order of their first tab, with windows in the order they opened, so the list
/// does not jump when another window comes to the front.
private struct ProjectList: View {
    @EnvironmentObject private var store: SidebarStore

    var body: some View {
        let frontId = store.windows.first { $0.index == 1 }?.id
        let groups = ProjectGrouping.group(store.windowsInOpenOrder.flatMap(\.tabs)) {
            store.projects.root(for: $0.workingDirectory)
        }
        ForEach(groups) { group in
            ProjectSection(group: group, frontWindowId: frontId)
        }
    }
}

private struct ProjectSection: View {
    let group: ProjectGroup<GhosttyTab>
    let frontWindowId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProjectHeader(group: group)
            ForEach(group.items) { tab in
                TabRow(tab: tab, isFrontWindow: tab.windowId == frontWindowId)
            }
        }
        .padding(.vertical, 6)
    }
}

/// "wallet  ● 1  ◐ 2  $3.20 ──── 3 +"
private struct ProjectHeader: View {
    @EnvironmentObject private var sessions: SessionTracker
    let group: ProjectGroup<GhosttyTab>
    @State private var hovering = false

    private var idle: Int { group.items.filter { $0.status == .idle }.count }
    private var busy: Int { group.items.filter { $0.status == .busy }.count }
    private var cost: Double? {
        let costs = group.items.compactMap { sessions.costByTab[$0.id] }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.root == nil ? "questionmark.folder" : "folder")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Mocha.lavender.opacity(0.8))
            Text(group.name ?? "기타")
                .font(Typo.ui(10.5, weight: .semibold))
                .foregroundStyle(Mocha.lavender)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if idle > 0 { MiniCount(count: idle, color: Mocha.green, help: "대기 \(idle)개") }
            if busy > 0 { MiniCount(count: busy, color: Mocha.peach, help: "작업 중 \(busy)개") }
            if sessions.showCost, let cost {
                Text(CostText.format(cost))
                    .font(Typo.mono(10))
                    .foregroundStyle(Mocha.yellow.opacity(0.85))
                    .help("이 프로젝트에서 열린 세션의 API 환산 비용 합계입니다")
            }
            Rectangle().fill(Mocha.surface0).frame(height: 1)
            Text("\(group.items.count)")
                .font(Typo.mono(10.5))
                .foregroundStyle(Mocha.overlay0)
            if let root = group.root {
                Button {
                    sessions.newClaudeSession(in: root)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(hovering ? Mocha.text : Mocha.overlay1)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("이 프로젝트에서 새 Claude 세션 열기\n\(root)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .help(group.root ?? "작업 폴더를 알 수 없는 탭")
        .contextMenu {
            if let root = group.root {
                Button("새 Claude 세션") { sessions.newClaudeSession(in: root) }
                Button("새 셸 탭") { sessions.newShell(in: root) }
                Divider()
                Button("Finder에서 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: root)) }
            }
        }
    }
}

private struct MiniCount: View {
    let count: Int
    let color: Color
    let help: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)").font(Typo.mono(10, weight: .semibold))
        }
        .foregroundStyle(color)
        .help(help)
    }
}

private struct TabRow: View {
    @EnvironmentObject private var store: SidebarStore
    @EnvironmentObject private var sessions: SessionTracker
    let tab: GhosttyTab
    let isFrontWindow: Bool
    @State private var hovering = false

    private var isCurrent: Bool { tab.isSelected && isFrontWindow }

    private var directoryName: String? {
        guard let dir = tab.workingDirectory, !dir.isEmpty else { return nil }
        let name = (dir as NSString).lastPathComponent
        return name.isEmpty ? dir : name
    }

    var body: some View {
        Button {
            store.select(tab)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                StatusIndicator(status: tab.status)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title.isEmpty ? tab.rawTitle : tab.title)
                        .font(Typo.ui(12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let directoryName {
                        Text("~/\(directoryName)")
                            .font(Typo.mono(10.5))
                            .foregroundStyle(isCurrent ? Mocha.subtext0 : Mocha.overlay0)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if sessions.showCost, let cost = sessions.costByTab[tab.id] {
                    Text(CostText.format(cost))
                        .font(Typo.mono(10.5))
                        .foregroundStyle(isCurrent ? Mocha.subtext0 : Mocha.overlay1)
                        .help("이 세션의 API 환산 비용입니다. 서브에이전트를 포함합니다.")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.rawTitle + (tab.workingDirectory.map { "\n\($0)" } ?? ""))
    }

    private var titleColor: Color {
        if isCurrent { return Mocha.text }
        switch tab.status {
        case .idle: return Mocha.text
        case .busy: return Mocha.subtext1
        case .unknown: return Mocha.subtext0
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if isCurrent {
            shape
                .fill(Mocha.surface0)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Mocha.mauve)
                        .frame(width: 3)
                        .padding(.vertical, 6)
                }
        } else if tab.isSelected {
            shape.fill(Mocha.surface0.opacity(hovering ? 0.75 : 0.45))
        } else if hovering {
            shape.fill(Mocha.surface0.opacity(0.6))
        } else {
            shape.fill(Color.clear)
        }
    }
}

// MARK: - Status indicator

struct StatusIndicator: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .idle:
            // Waiting for the user: the state that needs attention, so it glows.
            Circle()
                .fill(Mocha.green)
                .frame(width: 7, height: 7)
                .shadow(color: Mocha.green.opacity(0.8), radius: 3)
                .help("대기 중: 입력을 기다립니다")
        case .busy:
            Spinner(color: Mocha.peach)
                .help("작업 중")
        case .unknown:
            Text("❯")
                .font(Typo.mono(11, weight: .bold))
                .foregroundStyle(Mocha.overlay0)
                .help("Claude 세션이 아닙니다")
        }
    }
}

/// The quarter-circle spinner Claude Code puts in the tab title (◐ ◓ ◑ ◒).
/// One glyph is rotated in 90° steps instead of swapping text: rotation is a
/// render-only effect, so a tick never triggers a layout pass.
private struct Spinner: View {
    let color: Color
    @AppStorage(SettingKey.animateBusy) private var animate = true

    var body: some View {
        if animate { animated } else { glyph(step: 0) }
    }

    private func glyph(step: Int) -> some View {
        Text("◐")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(Double(step) * 90))
    }

    private var animated: some View {
        CASpinner(color: NSColor(color))
            .frame(width: 14, height: 14)
    }
}

/// Rotates the glyph with a Core Animation keyframe animation. The render server
/// runs it, so the app does no per-frame work (SwiftUI's TimelineView cost ~7% CPU).
private struct CASpinner: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(color: color) }
    func updateNSView(_ view: SpinnerView, context: Context) {}

    final class SpinnerView: NSView {
        private let glyph = CATextLayer()

        init(color: NSColor) {
            super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
            wantsLayer = true
            glyph.string = NSAttributedString(string: "◐", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: color,
            ])
            glyph.alignmentMode = .center
            glyph.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(glyph)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            // Centre a glyph-sized box; rotation is around the layer's centre.
            let h: CGFloat = 14
            glyph.frame = CGRect(x: (bounds.width - h) / 2, y: (bounds.height - h) / 2 - 0.5, width: h, height: h)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, glyph.animation(forKey: "spin") == nil else { return }
            let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            spin.values = [0, -Double.pi / 2, -Double.pi, -3 * Double.pi / 2]
            spin.calculationMode = .discrete
            spin.duration = 0.6
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            glyph.add(spin, forKey: "spin")
        }
    }
}

enum SettingKey {
    static let animateBusy = "animateBusySpinner"
    static let groupByProject = "groupByProject"
}

// MARK: - Sessions: cost, new tab, restore

enum CostText {
    static func format(_ dollars: Double) -> String {
        if dollars >= 100 { return String(format: "$%.0f", dollars) }
        if dollars >= 0.005 { return String(format: "$%.2f", dollars) }
        return "$0"
    }
}

/// "+" in the header: a new Claude session in a recent folder, any folder, or a plain shell.
private struct NewTabButton: View {
    @EnvironmentObject private var sessions: SessionTracker

    var body: some View {
        Menu {
            Section("새 Claude 세션") {
                ForEach(sessions.recentDirectories, id: \.self) { dir in
                    Button(Self.short(dir)) { sessions.newClaudeSession(in: dir) }
                }
                Button("폴더 선택…") { sessions.chooseDirectoryForClaude() }
            }
            Divider()
            Button("새 셸 탭") { sessions.newShell(in: nil) }
            if let first = sessions.recentDirectories.first {
                Button("새 셸 탭: \(Self.short(first))") { sessions.newShell(in: first) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Mocha.overlay1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("새 탭: Claude 세션 또는 셸")
    }

    static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Sessions that were open before (from the saved snapshot) and are not running now.
/// Sessions that were open before and are not running now, in two groups:
/// ended abnormally (to bring back) and closed on purpose (to look back into).
/// Folded by default: the count says what can be reopened without taking space.
private struct RestoreSection: View {
    @EnvironmentObject private var sessions: SessionTracker
    @EnvironmentObject private var store: SidebarStore
    @AppStorage("closedSessionsExpanded") private var expanded = false
    @AppStorage(SettingKey.groupByProject) private var groupByProject = false
    @State private var hovering = false

    private var total: Int { sessions.restorable.count + sessions.recentlyClosed.count }

    /// Most recently used first.
    private var crashed: [SessionTracker.Restorable] {
        sessions.restorable.sorted { $0.recency > $1.recency }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if expanded && groupByProject {
                byProject.transition(.opacity)
            } else if expanded {
                Group {
                    if !crashed.isEmpty {
                        SubHeader(title: "비정상 종료", count: crashed.count, color: Mocha.peach,
                                  action: ("모두 열기", "재부팅이나 Ghostty 종료로 한꺼번에 끝난 세션을 모두 다시 엽니다"),
                                  perform: sessions.restoreAll)
                        ForEach(crashed) { RestoreRow(item: $0) }
                    }
                    if !sessions.recentlyClosed.isEmpty {
                        SubHeader(title: "최근에 닫음", count: sessions.recentlyClosed.count, color: Mocha.overlay1,
                                  action: ("비우기", "직접 닫은 세션 목록을 비웁니다. 대화 기록은 지우지 않습니다"),
                                  perform: sessions.clearRecentlyClosed)
                        ForEach(sessions.recentlyClosed) { RestoreRow(item: $0) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 10)
    }

    /// Both lists merged and grouped by project, most recent first. Abnormal
    /// ends carry a tag on the row; the bulk actions sit on one line above.
    @ViewBuilder
    private var byProject: some View {
        let crashedIds = Set(sessions.restorable.map(\.id))
        let all = (sessions.restorable + sessions.recentlyClosed).sorted { $0.recency > $1.recency }
        let groups = ProjectGrouping.group(all) { store.projects.root(for: $0.entry.cwd) }
        HStack(spacing: 10) {
            if !crashedIds.isEmpty {
                Button("비정상 종료 \(crashedIds.count)개 모두 열기", action: sessions.restoreAll)
                    .foregroundStyle(Mocha.peach)
                    .help("재부팅이나 Ghostty 종료로 한꺼번에 끝난 세션을 모두 다시 엽니다")
            }
            Spacer(minLength: 4)
            if !sessions.recentlyClosed.isEmpty {
                Button("비우기", action: sessions.clearRecentlyClosed)
                    .foregroundStyle(Mocha.overlay1)
                    .help("직접 닫은 세션 목록을 비웁니다. 대화 기록은 지우지 않습니다")
            }
        }
        .buttonStyle(.plain)
        .font(Typo.ui(10, weight: .semibold))
        .padding(.leading, 22)
        .padding(.trailing, 6)
        .padding(.top, 6)
        ForEach(groups) { group in
            HStack(spacing: 6) {
                Image(systemName: group.root == nil ? "questionmark.folder" : "folder")
                    .font(.system(size: 9, weight: .semibold))
                Text(group.name ?? "기타")
                    .font(Typo.ui(10, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.items.count)")
                    .font(Typo.mono(10))
                    .foregroundStyle(Mocha.overlay0)
            }
            .foregroundStyle(Mocha.subtext0)
            .padding(.leading, 22)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .help(group.root ?? "")
            ForEach(group.items) { RestoreRow(item: $0, crashed: crashedIds.contains($0.id)) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Mocha.overlay1)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Text("닫힌 세션")
                .font(Typo.ui(10.5, weight: .semibold))
                .foregroundStyle(hovering ? Mocha.text : Mocha.subtext0)
            Text("\(total)")
                .font(Typo.mono(10, weight: .semibold))
                .padding(.horizontal, 5)
                .background(Capsule().fill((sessions.restorable.isEmpty ? Mocha.overlay1 : Mocha.peach).opacity(0.16)))
                .foregroundStyle(sessions.restorable.isEmpty ? Mocha.overlay1 : Mocha.peach)
            Rectangle().fill(Mocha.surface0).frame(height: 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        }
        .onHover { hovering = $0 }
        .help(expanded ? "접기" : "다시 열 수 있는 세션 보기")
    }

    /// "비정상 종료 2 ........ 모두 열기"
    private struct SubHeader: View {
        let title: String
        let count: Int
        let color: Color
        let action: (label: String, help: String)
        let perform: () -> Void

        var body: some View {
            HStack(spacing: 6) {
                Text(title)
                    .font(Typo.ui(10, weight: .semibold))
                    .foregroundStyle(color)
                Text("\(count)")
                    .font(Typo.mono(10))
                    .foregroundStyle(Mocha.overlay0)
                Spacer(minLength: 4)
                Button(action.label, action: perform)
                    .buttonStyle(.plain)
                    .font(Typo.ui(10, weight: .semibold))
                    .foregroundStyle(color)
                    .help(action.help)
            }
            .padding(.leading, 22)
            .padding(.trailing, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }
}

private struct RestoreRow: View {
    @EnvironmentObject private var sessions: SessionTracker
    let item: SessionTracker.Restorable
    /// Marks an abnormal end in the project view, where both lists are merged.
    var crashed = false
    @State private var hovering = false

    static let closedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    /// When it was closed, or for sessions from the saved list, when it was last used.
    private var timeText: String? {
        if let closedAt = item.closedAt { return Self.closedFormatter.string(from: closedAt) }
        return item.entry.lastActivity.map { String($0.dropFirst(5)) }   // "2026-11-10 17:09" -> "11-10 17:09"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Mocha.overlay1)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if crashed {
                        Text("비정상")
                            .font(Typo.ui(9.5, weight: .bold))
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Mocha.peach.opacity(0.16)))
                            .foregroundStyle(Mocha.peach)
                    }
                    if item.kind == .codex {
                        Text("codex")
                            .font(Typo.mono(9.5, weight: .bold))
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Mocha.sky.opacity(0.16)))
                            .foregroundStyle(Mocha.sky)
                    }
                    Text(item.entry.displayTitle)
                        .font(Typo.ui(12))
                        .foregroundStyle(Mocha.subtext1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(NewTabButton.short(item.entry.cwd) + (timeText.map { "  \($0)" } ?? ""))
                    .font(Typo.mono(10.5))
                    .foregroundStyle(Mocha.overlay0)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    sessions.dismiss(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Mocha.overlay1)
                }
                .buttonStyle(.plain)
                .help("목록에서 지우기")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Mocha.surface0.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { sessions.restore(item) }
        .onHover { hovering = $0 }
        .help("클릭하면 새 탭에서 이 세션을 다시 엽니다\n\(item.kind.resumeCommand(item.id).trimmingCharacters(in: .newlines))\n\(item.entry.cwd)")
    }
}

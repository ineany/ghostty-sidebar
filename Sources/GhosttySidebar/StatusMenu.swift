import AppKit

/// Menu bar icon. The app has no Dock icon and no app menu (LSUIElement), so this
/// is where the settings live besides the sidebar's right-click menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let dock: DockController
    private let sessions: SessionTracker
    private weak var panel: NSPanel?
    private let onRefresh: () -> Void

    init(dock: DockController, sessions: SessionTracker, panel: NSPanel, onRefresh: @escaping () -> Void) {
        self.dock = dock
        self.sessions = sessions
        self.panel = panel
        self.onRefresh = onRefresh
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Ghostty Sidebar")
            button.image?.isTemplate = true
            button.toolTip = "Ghostty Sidebar"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false   // honour isEnabled set below
        menu.delegate = self
        item.menu = menu
    }

    // Rebuilt on every open so the monitor list and check marks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        dock.reloadScreens()

        let visible = panel?.isVisible ?? false
        menu.addItem(action(visible ? "사이드바 숨기기" : "사이드바 보이기", #selector(toggleVisible)))
        menu.addItem(action("새로 고침", #selector(refresh)))
        menu.addItem(.separator())

        let header = NSMenuItem(title: "모니터", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for screen in dock.screens {
            let title = screen.isPrimary ? "\(screen.id) (주 모니터)" : screen.id
            let entry = action(title, #selector(moveToScreen(_:)))
            entry.representedObject = screen.id
            entry.state = dock.effectiveScreenName == screen.id ? .on : .off
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let snap = action("탭 클릭 시 Ghostty 창 붙이기", #selector(toggleSnap))
        snap.state = dock.snapOnSelect ? .on : .off
        menu.addItem(snap)
        let fill = action("붙일 때 남은 너비 채우기", #selector(toggleFill))
        fill.state = dock.snapFillWidth ? .on : .off
        fill.isEnabled = dock.snapOnSelect
        menu.addItem(fill)
        let hide = action("자동 숨기기", #selector(toggleAutoHide))
        hide.state = dock.autoHide ? .on : .off
        menu.addItem(hide)
        menu.addItem(action("사이드바 위치와 크기 초기화", #selector(resetSize)))
        menu.addItem(.separator())

        let arrange = action("Ghostty 창 자동 정렬", #selector(toggleAutoArrange))
        arrange.state = dock.autoArrange ? .on : .off
        arrange.isEnabled = !dock.autoHide
        menu.addItem(arrange)
        let arrangeNowItem = action("지금 Ghostty 창 정렬", #selector(arrangeNow))
        arrangeNowItem.isEnabled = !dock.autoHide
        menu.addItem(arrangeNowItem)
        menu.addItem(.separator())

        let animate = action("작업 중 회전 애니메이션", #selector(toggleAnimation))
        animate.state = UserDefaults.standard.object(forKey: SettingKey.animateBusy) as? Bool ?? true ? .on : .off
        menu.addItem(animate)
        let cost = action("세션 비용 표시", #selector(toggleCost))
        cost.state = sessions.showCost ? .on : .off
        menu.addItem(cost)
        menu.addItem(.separator())

        let save = action("세션 자동 저장", #selector(toggleAutoSave))
        save.state = sessions.autoSave ? .on : .off
        menu.addItem(save)
        menu.addItem(action("지금 세션 저장", #selector(saveNow)))
        let restore = action("비정상 종료 세션 모두 열기 (\(sessions.restorable.count))", #selector(restoreAll))
        restore.isEnabled = !sessions.restorable.isEmpty
        menu.addItem(restore)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Ghostty Sidebar 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func toggleVisible() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func refresh() { onRefresh() }

    @objc private func moveToScreen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        dock.moveTo(screenName: name)
        panel?.orderFrontRegardless()
    }

    @objc private func toggleAutoArrange() { dock.autoArrange.toggle() }

    @objc private func toggleAutoHide() { dock.autoHide.toggle() }

    @objc private func toggleSnap() { dock.snapOnSelect.toggle() }

    @objc private func toggleFill() { dock.snapFillWidth.toggle() }

    @objc private func resetSize() { dock.resetSize() }

    @objc private func arrangeNow() { dock.arrangeNow() }

    @objc private func toggleCost() { sessions.showCost.toggle() }
    @objc private func toggleAutoSave() { sessions.autoSave.toggle() }
    @objc private func saveNow() { sessions.saveNow() }
    @objc private func restoreAll() { sessions.restoreAll() }

    @objc private func toggleAnimation() {
        let current = UserDefaults.standard.object(forKey: SettingKey.animateBusy) as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: SettingKey.animateBusy)
    }
}

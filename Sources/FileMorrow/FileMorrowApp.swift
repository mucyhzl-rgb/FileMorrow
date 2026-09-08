import AppKit
import SwiftUI

@MainActor
enum DockVisibility {
    static func policy(keepInDock: Bool) -> NSApplication.ActivationPolicy {
        keepInDock ? .regular : .accessory
    }

    static func apply(keepInDock: Bool) -> Bool {
        NSApplication.shared.setActivationPolicy(policy(keepInDock: keepInDock))
    }
}

@MainActor
final class WindowDirector {
    static let shared = WindowDirector()
    var openMainWindow: (() -> Void)?

    func reopenMainWindow() {
        if let window = NSApplication.shared.windows.first(where: Self.isMainWindow) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && window.level == .normal && !(window is NSPanel)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let keepInDock = UserDefaults.standard.object(forKey: "keepInDock") as? Bool ?? true
        _ = DockVisibility.apply(keepInDock: keepInDock)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowDirector.shared.reopenMainWindow()
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct FileMorrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        Window("FileMorrow", id: "main") {
            RootView(state: state)
        }
        .defaultSize(width: 1_280, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 FileMorrow") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "由 Nabeegh 制作",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]
                        )
                    ])
                }
            }

            CommandGroup(after: .newItem) {
                Button("扫描下载文件夹") {
                    Task { await state.scan() }
                }
                .keyboardShortcut("r")
                .disabled(state.isWorking)

                Button("分析待处理文件") {
                    state.startAnalysis()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(state.isWorking || state.classificationMode == .formatOnly)

                Button("撤销上次整理") {
                    Task { await state.undoLastMove() }
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(state.isWorking)

                Button("显示欢迎指南") {
                    state.requestOnboarding()
                }
            }
        }

        MenuBarExtra(isInserted: .constant(true)) {
            FileMorrowMenu(state: state)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(state: state)
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("FileMorrow", systemImage: "tray.full.fill")
            .onAppear {
                WindowDirector.shared.openMainWindow = {
                    openWindow(id: "main")
                }
            }
    }
}

private struct FileMorrowMenu: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 FileMorrow") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }

        Divider()

        Text(state.status)
        Text("\(state.files.count.formatted()) 个文件 • \(state.readyFiles.count.formatted()) 个可以归档")
        if state.totalReclaimableSize > 0 {
            Text("清理可回收 \(ByteCountFormatter.string(fromByteCount: state.totalReclaimableSize, countStyle: .file))")
        }
        Text(state.automaticOrganization ? "自动整理：开" : "自动整理：关")

        Divider()

        Button(state.isWorking ? "正在扫描…" : "扫描下载文件夹") {
            Task { await state.scan() }
        }
        .disabled(state.isWorking)

        Button(state.organizationProposal == nil ? "立即检查并整理" : "查看整理计划") {
            if state.organizationProposal == nil {
                Task { await state.checkAndPrepareOrganization() }
            } else {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
        }
        .disabled(state.isWorking)

        Button("扫描重复文件") {
            state.startDuplicateScan()
        }
        .disabled(state.isWorking)

        Button("检查已解压压缩包") {
            state.startExtractedArchiveScan()
        }
        .disabled(state.isWorking)

        Button("检查已用安装包") {
            state.startInstallerScan()
        }
        .disabled(state.isWorking)

        Divider()

        Button("显示欢迎指南") {
            openWindow(id: "main")
            NSApplication.shared.activate()
            state.requestOnboarding()
        }

        SettingsLink {
            Text("设置…")
        }

        Button("退出 FileMorrow") {
            NSApplication.shared.terminate(nil)
        }
    }
}

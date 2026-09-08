import SwiftUI

struct OnboardingView: View {
    let availability: IntelligenceAvailabilityState
    let onComplete: (ClassificationMode, Bool, Bool) -> Void

    @State private var mode: ClassificationMode
    @State private var automaticOrganization: Bool
    @State private var launchAtLogin: Bool

    init(
        availability: IntelligenceAvailabilityState,
        initialMode: ClassificationMode,
        initialAutomaticOrganization: Bool,
        initialLaunchAtLogin: Bool,
        onComplete: @escaping (ClassificationMode, Bool, Bool) -> Void
    ) {
        self.availability = availability
        self.onComplete = onComplete
        _mode = State(initialValue: initialMode)
        _automaticOrganization = State(initialValue: initialAutomaticOrganization)
        _launchAtLogin = State(initialValue: initialLaunchAtLogin)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    rules
                    modePicker
                    safety
                    compatibility
                }
                .padding(32)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("七天后自动整理", isOn: $automaticOrganization)
                    Toggle("登录时打开 FileMorrow", isOn: $launchAtLogin)
                }
                Spacer()
                Button("开始使用 FileMorrow") {
                    onComplete(mode, automaticOrganization, launchAtLogin)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
        }
        .frame(width: 720, height: 690)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 82, height: 82)
                .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 5) {
                Text("欢迎使用 FileMorrow")
                    .font(.largeTitle.bold())
                Text("安静、私密的下载文件夹整理工具。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rules: some View {
        OnboardingSection(
            title: "文件先有七天缓冲期",
            icon: "calendar.badge.clock",
            tint: .indigo
        ) {
            Text("今天、昨天和最近 7 天的文件不会被移动，方便查找。只有更早的零散文件才会进入整理。")
            Text("文件夹是硬边界：FileMorrow 绝不会移动下载来的文件夹，也不会动里面的任何内容。")
                .fontWeight(.medium)
        }
    }

    private var modePicker: some View {
        OnboardingSection(
            title: "选择文件分类方式",
            icon: "switch.2",
            tint: .cyan
        ) {
            Picker("分类模式", selection: $mode) {
                ForEach(ClassificationMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(mode.detail)
                .foregroundStyle(.secondary)

            if mode == .smartContent {
                Text("智能内容是可选的，也可能分错。会先使用高置信度的本地证据；不确定的文件会留下来供你审核。")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var safety: some View {
        OnboardingSection(
            title: "每次清理都有安全网",
            icon: "arrow.uturn.backward.circle.fill",
            tint: .green
        ) {
            Text("手动整理会先显示计划再移动。如果在这里开启自动整理，FileMorrow 可以在每小时检查时移动符合条件的文件，而不再询问。")
                .fontWeight(.medium)
            Text("每一批整理都有可见的“撤销上次整理”操作。")
            Text("重复文件检测比较 SHA-256 哈希，保留一份副本，只把你选中的多余文件移到废纸篓，因此可以恢复。")
        }
    }

    private var compatibility: some View {
        OnboardingSection(
            title: availability.title,
            icon: availability.isReady ? "checkmark.circle.fill" : "info.circle.fill",
            tint: availability.isReady ? .green : .orange
        ) {
            Text(availability.detail)
            Text("格式模式从不需要 Apple Intelligence。")
                .fontWeight(.medium)
        }
    }
}

private struct OnboardingSection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                content
            }
        }
    }
}

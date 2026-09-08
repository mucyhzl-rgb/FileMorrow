import SwiftUI
import QuickLookUI
import UniformTypeIdentifiers

struct RootView: View {
    @State var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var hasPerformedInitialScan = false

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } content: {
            FileListView(state: state)
                .navigationSplitViewColumnWidth(min: 500, ideal: 680)
        } detail: {
            InspectorView(state: state)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $state.query, placement: .toolbar, prompt: "搜索下载文件夹")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await state.scan() }
                } label: {
                    Label("扫描", systemImage: "arrow.clockwise")
                }
                .disabled(state.isWorking)

                if state.isAnalyzing {
                    Button {
                        state.cancelAnalysis()
                    } label: {
                        Label("停止分析", systemImage: "stop.fill")
                    }
                } else {
                    Menu {
                        Button("分析接下来 25 个") {
                            state.startAnalysis(limit: 25)
                        }
                        Button("分析全部剩余") {
                            state.startAnalysis()
                        }
                    } label: {
                        Label("分析", systemImage: "sparkles")
                    }
                    .disabled(state.isWorking || state.classificationMode == .formatOnly)
                }

                Button {
                    state.prepareOrganizationProposal()
                } label: {
                    Label("整理", systemImage: "folder.badge.plus")
                }
                .disabled(state.isWorking || state.approvedReadyFiles.isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Button {
                    Task { await state.undoLastMove() }
                } label: {
                    Label(
                        state.lastOrganizedCount > 0
                            ? "撤销上次整理（\(state.lastOrganizedCount)）"
                            : "撤销上次整理",
                        systemImage: "arrow.uturn.backward"
                    )
                }
                .disabled(state.isWorking)
                .keyboardShortcut("z", modifiers: .command)
            }
        }
        .sheet(item: $state.organizationProposal) { proposal in
            OrganizationPlanView(state: state, proposal: proposal)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(
                availability: state.intelligenceAvailability,
                initialMode: state.classificationMode,
                initialAutomaticOrganization: state.automaticOrganization,
                initialLaunchAtLogin: state.launchAtLogin
            ) { mode, automatic, launchAtLogin in
                Task {
                    await state.completeOnboarding(
                        mode: mode,
                        automaticOrganization: automatic,
                        launchAtLogin: launchAtLogin
                    )
                    hasCompletedOnboarding = true
                    showOnboarding = false
                }
            }
        }
        .task {
            await state.scan()
            hasPerformedInitialScan = true
            showOnboarding = !hasCompletedOnboarding
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasPerformedInitialScan else { return }
            Task { await state.refreshAfterActivation() }
        }
        .onChange(of: state.onboardingRequestID) { _, requestID in
            guard requestID != nil else { return }
            showOnboarding = true
        }
    }
}

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        List(selection: Binding(
            get: {
                if let category = state.categoryFilter {
                    return SidebarSelection(age: .all, category: category, showsCategories: true)
                }
                if state.isBrowsingCategories {
                    return .allCategories
                }
                return SidebarSelection(age: state.ageSelection)
            },
            set: { selection in
                state.ageSelection = selection.age
                state.categoryFilter = selection.category
                state.isBrowsingCategories = selection.showsCategories
            }
        )) {
            Section("最近") {
                ForEach([AgeView.today, .yesterday, .lastWeek]) { item in
                    SidebarRow(title: item.rawValue, icon: item.icon, count: state.count(for: item))
                        .tag(SidebarSelection(age: item))
                }
            }

            Section("资料库") {
                ForEach([AgeView.ready, .all]) { item in
                    SidebarRow(title: item.rawValue, icon: item.icon, count: state.count(for: item))
                        .tag(SidebarSelection(age: item))
                }
            }

            Section("释放空间") {
                SidebarRow(
                    title: AgeView.duplicates.rawValue,
                    icon: AgeView.duplicates.icon,
                    count: state.duplicateExtraCount
                )
                .tag(SidebarSelection(age: .duplicates))

                SidebarRow(
                    title: AgeView.extracted.rawValue,
                    icon: AgeView.extracted.icon,
                    count: state.extractedArchiveCount
                )
                .tag(SidebarSelection(age: .extracted))

                SidebarRow(
                    title: AgeView.installers.rawValue,
                    icon: AgeView.installers.icon,
                    count: state.redundantInstallerCount
                )
                .tag(SidebarSelection(age: .installers))
            }

            Section("分类") {
                SidebarCategoryRow(
                    title: "全部分类",
                    icon: "square.grid.2x2.fill",
                    color: .indigo,
                    selected: state.isBrowsingCategories && state.categoryFilter == nil
                )
                .tag(SidebarSelection.allCategories)

                ForEach(state.visibleCategories) { definition in
                    SidebarCategoryRow(
                        title: definition.name,
                        icon: definition.displayIcon,
                        color: definition.swiftUIColor,
                        selected: state.categoryFilter == definition.category
                    )
                    .tag(SidebarSelection(age: .all, category: definition.category, showsCategories: true))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .tint(.indigo)
                }
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if state.totalReclaimableSize > 0 {
                    Label(
                        "可回收 \(ByteCountFormatter.string(fromByteCount: state.totalReclaimableSize, countStyle: .file))",
                        systemImage: "internaldrive"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.indigo)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("管家")
    }
}

private struct SidebarSelection: Hashable {
    var age: AgeView
    var category: ArchiveCategory? = nil
    var showsCategories = false

    static var allCategories: Self { .init(age: .all, showsCategories: true) }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let count: Int

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(count.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

private struct SidebarCategoryRow: View {
    let title: String
    let icon: String
    let color: Color
    let selected: Bool

    var body: some View {
        Label {
            Text(title)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct FileListView: View {
    @Bindable var state: AppState

    var body: some View {
        Group {
            if state.ageSelection == .duplicates {
                DuplicateCenterView(state: state)
            } else if state.ageSelection == .extracted {
                ExtractedArchiveCenterView(state: state)
            } else if state.ageSelection == .installers {
                InstallerCenterView(state: state)
            } else {
                VStack(spacing: 0) {
                    DashboardHeader(state: state)
                    Divider()
                    if state.visibleFiles.isEmpty {
                ContentUnavailableView(
                    "这里没有文件",
                    systemImage: "tray",
                    description: Text("换一个日期视图，或清除搜索。")
                )
                    } else {
                        Table(state.visibleFiles, selection: $state.selectedFileID) {
                    TableColumn("文件") { file in
                        let definition = state.definition(for: file.category)
                        HStack(spacing: 10) {
                            CategoryGlyph(definition: definition)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).lineLimit(1)
                                Text(file.isOrganized ? "已整理 • \(file.source.title)" : file.source.title)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .width(min: 260, ideal: 360)

                    TableColumn("文件夹") { file in
                        if file.source == .rule && file.category == .needsReview {
                            Label("等待分析", systemImage: "sparkles")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.indigo.opacity(0.10), in: Capsule())
                        } else {
                            CategoryBadge(definition: state.definition(for: file.category))
                        }
                    }
                    .width(min: 140, ideal: 170)

                    TableColumn("置信度") { file in
                        ConfidenceView(value: file.confidence)
                    }
                    .width(100)
                        }
                    }
                }
            }
        }
        .navigationTitle(
            state.categoryFilter.map { state.definition(for: $0).name }
                ?? (state.isBrowsingCategories ? "全部分类" : state.ageSelection.rawValue)
        )
    }
}

private struct DuplicateCenterView: View {
    @Bindable var state: AppState
    @State private var pendingGroup: DuplicateGroup?

    var body: some View {
        VStack(spacing: 0) {
            CleanupHeader(
                title: "完全相同的重复文件",
                subtitle: "只读检查下载文件夹里每一个能访问的目录。SHA-256 核验字节是否完全相同；只有你确认的副本才会移到可恢复的废纸篓。",
                caution: "项目和应用程序里的嵌套文件可能本来就相同。移到废纸篓前请核对每一条完整路径。",
                summary: state.duplicateGroups.isEmpty
                    ? nil
                    : "\(state.duplicateExtraCount) extra copies • \(ByteCountFormatter.string(fromByteCount: state.duplicateWastedSize, countStyle: .file)) reclaimable",
                isScanning: state.isScanningDuplicates,
                actionTitle: "查找重复文件",
                cancelTitle: "停止扫描",
                isDisabled: state.isWorking,
                onScan: { state.startDuplicateScan() },
                onCancel: { state.cancelDuplicateScan() }
            )

            Divider()

            if state.isScanningDuplicates, let scan = state.duplicateScanProgress {
                CleanupProgressView(
                    fraction: scan.fraction,
                    headline: scan.stage.rawValue,
                    detail: "已检查 \(scan.completedFiles.formatted()) / \(scan.totalFiles.formatted()) 项 • 已读取 \(ByteCountFormatter.string(fromByteCount: scan.processedBytes, countStyle: .file))",
                    currentItem: scan.currentFile
                )
            } else if state.duplicateGroups.isEmpty {
                ContentUnavailableView(
                    "还没有重复文件扫描结果",
                    systemImage: "doc.on.doc",
                    description: Text("运行扫描，查找下载文件夹里字节完全相同的副本。")
                )
            } else {
                List(state.duplicateGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(
                                "\(group.files.count) 个相同副本",
                                systemImage: "doc.on.doc.fill"
                            )
                            .font(.headline)
                            Spacer()
                            Text("可回收 " + ByteCountFormatter.string(fromByteCount: group.wastedSize, countStyle: .file))
                                .foregroundStyle(.secondary)
                            Button("把 \(group.extras.count) 个多余副本移到废纸篓", role: .destructive) {
                                pendingGroup = group
                            }
                        }
                        ForEach(group.files, id: \.path) { url in
                            let isKeeper = url == group.keeper
                            HStack(spacing: 8) {
                                Label(
                                    url.path,
                                    systemImage: isKeeper ? "checkmark.circle.fill" : "trash"
                                )
                                .foregroundStyle(isKeeper ? .green : .secondary)
                                .textSelection(.enabled)
                                Spacer()
                                if !isKeeper {
                                    Button("保留这个") {
                                        state.setDuplicateKeeper(url, in: group)
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "把完全相同的副本移到废纸篓？",
            isPresented: Binding(
                get: { pendingGroup != nil },
                set: { if !$0 { pendingGroup = nil } }
            ),
            presenting: pendingGroup
        ) { group in
            Button("把 \(group.extras.count) 个多余副本移到废纸篓", role: .destructive) {
                Task {
                    await state.trashDuplicateExtras(in: group)
                    pendingGroup = nil
                }
            }
            Button("取消", role: .cancel) { pendingGroup = nil }
        } message: { group in
            Text("FileMorrow 会保留 \(group.keeper.path)。请核对每一条路径：项目和应用程序里的嵌套文件可能本来就相同。已确认字节完全相同的多余副本会移到可恢复的 macOS 废纸篓。")
        }
    }
}

/// Shared chrome for the Reclaim Space workflows, so the duplicate, archive,
/// and installer screens read as one feature rather than three.
private struct CleanupHeader: View {
    let title: String
    let subtitle: String
    var caution: String? = nil
    let summary: String?
    let isScanning: Bool
    let actionTitle: String
    var cancelTitle: String = "停止检查"
    let isDisabled: Bool
    let onScan: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
                if let caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let summary {
                    Label(summary, systemImage: "internaldrive")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.indigo)
                }
            }
            Spacer()
            if isScanning {
                Button(cancelTitle, role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            } else {
                Button(actionTitle, action: onScan)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled)
            }
        }
        .padding(20)
    }
}

private struct CleanupProgressView: View {
    let fraction: Double?
    let headline: String
    let detail: String
    let currentItem: String?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: fraction)
                .frame(maxWidth: 420)
            Text(headline).font(.headline)
            Text(detail).foregroundStyle(.secondary)
            if let currentItem {
                Text(currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct CleanupSelectionFooter: View {
    let selectedCount: Int
    let totalCount: Int
    let selectedSize: Int64
    let actionTitle: String
    let isDisabled: Bool
    let onToggleAll: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack {
            Button(selectedCount == totalCount ? "取消全选" : "全选", action: onToggleAll)
                .buttonStyle(.link)

            Spacer()

            if selectedCount > 0 {
                Text("已选 \(selectedCount) 个 • \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(actionTitle, role: .destructive, action: onAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDisabled)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }
}

private struct InstallerCenterView: View {
    @Bindable var state: AppState
    @State private var selection: Set<String> = []
    @State private var showConfirmation = false

    private var selected: [RedundantInstaller] {
        state.redundantInstallers.filter { selection.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selected.reduce(0) { $0 + $1.installerSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            CleanupHeader(
                title: "安装包",
                subtitle: "查找软件已经装在这台 Mac 上的 .dmg 和 .pkg。安装包会对照 macOS 保存的安装回执；磁盘映像会匹配“应用程序”里的软件。不会挂载、打开或运行任何安装包。",
                summary: state.redundantInstallers.isEmpty
                    ? nil
                    : "\(state.redundantInstallerCount) already used • \(ByteCountFormatter.string(fromByteCount: state.redundantInstallerReclaimableSize, countStyle: .file)) reclaimable",
                isScanning: state.isScanningInstallers,
                actionTitle: "检查安装包",
                isDisabled: state.isWorking,
                onScan: { state.startInstallerScan() },
                onCancel: { state.cancelInstallerScan() }
            )
            Divider()
            content
        }
        .confirmationDialog(
            "把 \(selected.count) 个已用安装包移到废纸篓？",
            isPresented: $showConfirmation
        ) {
            Button("移到废纸篓", role: .destructive) {
                let installers = selected
                Task {
                    await state.trashInstallers(installers)
                    selection.removeAll()
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("已安装的软件不会被改动。只有安装包文件会移到可恢复的 macOS 废纸篓，而且随时可以重新下载。比本机版本更新的安装包不会出现在这里。")
        }
        .onChange(of: state.redundantInstallers) { _, installers in
            selection.formIntersection(Set(installers.map(\.id)))
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isScanningInstallers, let scan = state.installerScanProgress {
            CleanupProgressView(
                fraction: scan.fraction,
                headline: "正在检查安装包",
                detail: "\(scan.completedInstallers.formatted()) / \(scan.totalInstallers.formatted()) 个安装包",
                currentItem: scan.currentInstaller
            )
        } else if state.redundantInstallers.isEmpty {
            ContentUnavailableView(
                state.hasScannedInstallers ? "没有已用安装包" : "还没有检查安装包",
                systemImage: "shippingbox",
                description: Text(
                    state.hasScannedInstallers
                        ? "下载文件夹里的安装包，要么对应尚未安装的软件，要么比本机版本更新。"
                        : "运行检查，查找你已经安装过的软件对应的 .dmg 和 .pkg。"
                )
            )
        } else {
            VStack(spacing: 0) {
                List(state.redundantInstallers, selection: $selection) { installer in
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(.indigo)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(installer.name).fontWeight(.medium)
                            HStack(spacing: 6) {
                                Text(installer.evidence.rawValue)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        (installer.evidence == .packageReceipt ? Color.green : Color.indigo)
                                            .opacity(0.12),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(installer.evidence == .packageReceipt ? .green : .indigo)
                                Text(installer.comparison.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(installer.installedLocation) • \(installer.versionSummary)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: installer.installerSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                    .tag(installer.id)
                }
                .listStyle(.inset)

                Divider()

                CleanupSelectionFooter(
                    selectedCount: selection.count,
                    totalCount: state.redundantInstallers.count,
                    selectedSize: selectedSize,
                    actionTitle: "把 \(selection.count) 个移到废纸篓",
                    isDisabled: selection.isEmpty || state.isWorking,
                    onToggleAll: {
                        selection = selection.count == state.redundantInstallers.count
                            ? []
                            : Set(state.redundantInstallers.map(\.id))
                    },
                    onAction: { showConfirmation = true }
                )
            }
        }
    }
}

private struct ExtractedArchiveCenterView: View {
    @Bindable var state: AppState
    @State private var selection: Set<String> = []
    @State private var showConfirmation = false

    private var selected: [ExtractedArchive] {
        state.extractedArchives.filter { selection.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selected.reduce(0) { $0 + $1.archiveSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            CleanupHeader(
                title: "已解压压缩包",
                subtitle: "查找内容已经解压在旁边的 ZIP。只有每个条目的大小都与解压文件完全一致时，才会出现在这里。",
                summary: state.extractedArchives.isEmpty
                    ? nil
                    : "\(state.extractedArchiveCount) unpacked • \(ByteCountFormatter.string(fromByteCount: state.extractedArchiveReclaimableSize, countStyle: .file)) reclaimable",
                isScanning: state.isScanningExtractedArchives,
                actionTitle: "检查压缩包",
                isDisabled: state.isWorking,
                onScan: { state.startExtractedArchiveScan() },
                onCancel: { state.cancelExtractedArchiveScan() }
            )
            Divider()
            content
        }
        .confirmationDialog(
            "把 \(selected.count) 个已解压压缩包移到废纸篓？",
            isPresented: $showConfirmation
        ) {
            Button("移到废纸篓", role: .destructive) {
                let archives = selected
                Task {
                    await state.trashExtractedArchives(archives)
                    selection.removeAll()
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只有 .zip 文件会移到可恢复的 macOS 废纸篓。解压后的文件夹原样保留，每个压缩包在移动前都会再核验一次。")
        }
        .onChange(of: state.extractedArchives) { _, archives in
            let ids = Set(archives.map(\.id))
            selection.formIntersection(ids)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isScanningExtractedArchives, let scan = state.extractedArchiveScanProgress {
            CleanupProgressView(
                fraction: scan.fraction,
                headline: "正在核验压缩包内容",
                detail: "\(scan.completedArchives.formatted()) / \(scan.totalArchives.formatted()) 个压缩包",
                currentItem: scan.currentArchive
            )
        } else if state.extractedArchives.isEmpty {
            ContentUnavailableView(
                state.hasScannedExtractedArchives ? "没有已解压的压缩包" : "还没有检查压缩包",
                systemImage: "archivebox",
                description: Text(
                    state.hasScannedExtractedArchives
                        ? "下载文件夹里的 ZIP 要么尚未解压，要么和旁边的文件夹不完全一致。"
                        : "运行检查，查找你已经解压、不再需要的 ZIP。"
                )
            )
        } else {
            VStack(spacing: 0) {
                List(state.extractedArchives, selection: $selection) { archive in
                    HStack(spacing: 12) {
                        Image(systemName: "archivebox.fill")
                            .foregroundStyle(.indigo)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(archive.name)
                                .fontWeight(.medium)
                            Label(
                                "已解压到 \(archive.destinationName)",
                                systemImage: "arrow.turn.down.right"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text("已核验 \(archive.entryCount.formatted()) 个文件 • 磁盘占用 \(ByteCountFormatter.string(fromByteCount: archive.extractedSize, countStyle: .file))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: archive.archiveSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                    .tag(archive.id)
                }
                .listStyle(.inset)

                Divider()

                CleanupSelectionFooter(
                    selectedCount: selection.count,
                    totalCount: state.extractedArchives.count,
                    selectedSize: selectedSize,
                    actionTitle: "把 \(selection.count) 个移到废纸篓",
                    isDisabled: selection.isEmpty || state.isWorking,
                    onToggleAll: {
                        selection = selection.count == state.extractedArchives.count
                            ? []
                            : Set(state.extractedArchives.map(\.id))
                    },
                    onAction: { showConfirmation = true }
                )
            }
        }
    }
}

private struct OrganizationPlanView: View {
    @Bindable var state: AppState
    let proposal: OrganizationProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("整理前请先确认", systemImage: "checklist")
                .font(.title2.bold())
                .foregroundStyle(.indigo)

            Text(proposal.automaticCheck
                 ? "FileMorrow 的自动检查发现有文件可以整理。现在整理下载文件夹吗？"
                 : "现在整理这些下载文件吗？")
                .font(.title3.weight(.semibold))

            HStack {
                Label("\(proposal.fileCount) 个文件", systemImage: "doc.on.doc")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: proposal.totalSize, countStyle: .file))
                    .foregroundStyle(.secondary)
            }

            List(proposal.categoryCounts, id: \.name) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.count.formatted())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(minHeight: 150)

            Label(
                "不会删除任何文件。只有符合条件的零散文件会被移动，撤销上次整理可以还原这一整批。",
                systemImage: "arrow.uturn.backward.circle.fill"
            )
            .foregroundStyle(.green)
            .fontWeight(.medium)

            HStack {
                Button("稍后再说", role: .cancel) {
                    state.organizationProposal = nil
                    state.status = "整理已推迟 • 没有移动文件"
                }
                Spacer()
                Button("整理 \(proposal.fileCount) 个文件") {
                    Task { await state.organizeApproved() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 460)
        .interactiveDismissDisabled(state.isWorking)
    }
}

private struct DashboardHeader: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("更清爽的下载文件夹。")
                        .font(.title2.bold())
                    Text("新文件保持可见。较旧的文件会等到有把握、可撤销的决定后再整理。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 16))
            }

            HStack(spacing: 12) {
                MetricCard(title: "可以归档", value: state.readyFiles.count.formatted(), icon: "archivebox")
                MetricCard(title: "已确认", value: state.approvedReadyFiles.count.formatted(), icon: "checkmark.seal", tint: .green)
                MetricCard(title: "等待分析", value: state.awaitingAnalysisCount.formatted(), icon: "sparkles", tint: .indigo)
                MetricCard(title: "待审核", value: state.reviewCount.formatted(), icon: "exclamationmark.bubble", tint: .orange)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.10), Color.purple.opacity(0.03), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .indigo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.06))
        }
    }
}

struct InspectorView: View {
    @Bindable var state: AppState
    @State private var teachingFile: FileRecord?

    var body: some View {
        Group {
            if let file = state.selectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        FilePreview(url: file.url)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name)
                                .font(.title3.bold())
                                .textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("建议文件夹").font(.headline)
                            Picker("分类", selection: Binding(
                                get: { file.category },
                                set: { category in Task { await state.correctSelected(to: category) } }
                            )) {
                                ForEach(state.enabledCategories) { definition in
                                    Label(definition.name, systemImage: definition.displayIcon)
                                        .tag(definition.category)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)

                            ConfidenceView(value: file.confidence)
                            Text(file.reason)
                                .foregroundStyle(.secondary)
                            Label(file.source.title, systemImage: file.source == .user ? "person.fill.checkmark" : "cpu")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if file.isOrganized {
                                Label("已经整理", systemImage: "folder.fill.badge.checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }

                        HStack {
                            Button("打开文件") {
                                NSWorkspace.shared.open(file.url)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("教整理器…") {
                                teachingFile = file
                            }
                            .buttonStyle(.bordered)
                        }

                        if let excerpt = file.excerpt, !excerpt.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text("使用的证据").font(.headline)
                                Text(excerpt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(12)
                                    .textSelection(.enabled)
                            }
                        }

                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "选择一个文件",
                    systemImage: "sidebar.right",
                    description: Text("查看证据、更改文件夹，或在访达中显示。")
                )
            }
        }
        .navigationTitle("详情")
        .sheet(item: $teachingFile) { file in
            TeachOrganizerSheet(state: state, file: file)
        }
    }
}

private struct FilePreview: View {
    let url: URL

    var body: some View {
        QuickLookPreview(url: url)
            .frame(minHeight: 220, idealHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.primary.opacity(0.08))
            }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSView()
        }
        view.autostarts = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? QLPreviewView else { return }
        view.previewItem = url as NSURL
    }
}

private struct TeachOrganizerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState
    let file: FileRecord

    @State private var category: ArchiveCategory
    @State private var filenameKeyword = ""
    @State private var rememberExtension = false

    init(state: AppState, file: FileRecord) {
        self.state = state
        self.file = file
        _category = State(initialValue: file.category == .needsReview ? .documents : file.category)
    }

    private var availableCategories: [CategoryDefinition] {
        state.enabledCategories.filter { $0.category != .needsReview }
    }

    private var fileExtension: String {
        RuleClassifier.normalizedExtension(file.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("教整理器").font(.title2.bold())
                Text(file.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Form {
                Picker("正确分类", selection: $category) {
                    ForEach(availableCategories) { definition in
                        Label(definition.name, systemImage: definition.displayIcon)
                            .tag(definition.category)
                    }
                }

                TextField("可复用的文件名词语", text: $filenameKeyword)
                Text("可选。例如：“操作系统”、“发票”或课程代码。以后匹配的文件名会使用这个分类。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !fileExtension.isEmpty {
                    Toggle("以后都把 .\(fileExtension) 文件归到这里", isOn: $rememberExtension)
                    Text("只有这种格式始终属于这里时再勾选。这会替换之前对 .\(fileExtension) 的分类规则。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Text("当前文件会立刻更正，并作为端侧模型的示例。可选规则也会帮助以后的文件。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存并教学") {
                    Task {
                        await state.teach(
                            fileID: file.id,
                            category: category,
                            filenameKeyword: filenameKeyword,
                            rememberExtension: rememberExtension
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(category == .needsReview)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct CategoryGlyph: View {
    let definition: CategoryDefinition
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: definition.displayIcon)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(definition.swiftUIColor.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

private struct CategoryBadge: View {
    let definition: CategoryDefinition

    var body: some View {
        Label {
            Text(definition.name)
        } icon: {
            CategoryGlyph(definition: definition, size: 16)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(definition.swiftUIColor.opacity(0.12), in: Capsule())
    }
}

private struct ConfidenceView: View {
    let value: Int

    private var color: Color {
        if value >= 85 { return .green }
        if value >= 60 { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: 42 * Double(value) / 100)
            }
            .frame(width: 42, height: 6)

            Text("\(value)%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(value >= 85 ? .primary : color)
        }
        .accessibilityLabel("置信度 \(value)%")
    }
}

struct SettingsView: View {
    @Bindable var state: AppState
    @AppStorage("archiveDays") private var archiveDays = 7
    @AppStorage("minimumConfidence") private var minimumConfidence = 85

    var body: some View {
        TabView {
            Form {
                Section("分类方式") {
                    Picker("模式", selection: Binding(
                        get: { state.classificationMode },
                        set: { mode in Task { await state.setClassificationMode(mode) } }
                    )) {
                        ForEach(ClassificationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(state.isWorking)

                    Text(state.classificationMode.detail)
                        .foregroundStyle(.secondary)

                    if state.classificationMode == .smartContent {
                        Label(
                            "Apple Intelligence 的分类只是建议，可能不准确。移动重要文件前请先核对。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Label(
                            "适合可预期的整理。不需要内容分析队列。",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }

                Section("归档") {
                    Toggle("每小时自动整理符合条件的文件", isOn: Binding(
                        get: { state.automaticOrganization },
                        set: { state.setAutomaticOrganization($0) }
                    ))
                    Toggle("登录时打开 FileMorrow", isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                    Stepper("\(archiveDays) 天后归档文件", value: $archiveDays, in: 1...30)
                    Slider(value: Binding(
                        get: { Double(minimumConfidence) },
                        set: { minimumConfidence = Int($0) }
                    ), in: 60...100, step: 5) {
                        Text("最低置信度")
                    }
                    Text("菜单栏助手运行时每小时检查一次。只有超过所选天数的文件会被移动；不确定的文件会留下来供你审核。")
                        .foregroundStyle(.secondary)
                    Text("当前置信度阈值：\(minimumConfidence)%")
                        .foregroundStyle(.secondary)
                }

                Section("应用") {
                    Toggle("在程序坞中保留 FileMorrow", isOn: Binding(
                        get: { state.keepInDock },
                        set: { state.setKeepInDock($0) }
                    ))
                    Text("关闭后只保留菜单栏。窗口关闭后 FileMorrow 仍会继续运行。")
                        .foregroundStyle(.secondary)
                }

                Section("帮助") {
                    Button("显示欢迎指南") {
                        state.requestOnboarding()
                    }
                    Text("重新打开首次启动说明，不会更改你当前的设置。")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("整理", systemImage: "folder") }

            CategorySettingsView(state: state)
                .tabItem { Label("分类", systemImage: "slider.horizontal.3") }

            Form {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.intelligenceStatusTitle).font(.headline)
                        Text(state.intelligenceStatusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: state.intelligenceReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.intelligenceReady ? .green : .orange)
                }
                LabeledContent("隐私", value: "内容只会留在这台 Mac 上")
                Text("FileMorrow 只提取简短的本地证据，并仅发送给这台设备上运行的 Apple Intelligence。")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("兼容性", systemImage: "checkmark.shield.fill") }
        }
        .scenePadding()
        .frame(width: 680, height: 480)
    }
}

private struct CategorySettingsView: View {
    @Bindable var state: AppState
    @State private var editingCategory: CategoryDefinition?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.profile.name).font(.headline)
                    Text("这些定义会指导规则、本地内容评分和 Apple Intelligence。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入…") { importProfile() }
                Button("导出…") { exportProfile() }
                Button {
                    editingCategory = newCategory()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            List {
                ForEach(state.profile.categories) { definition in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { definition.enabled },
                            set: { enabled in
                                Task { await state.setCategoryEnabled(definition.id, enabled: enabled) }
                            }
                        ))
                        .labelsHidden()
                        .disabled(definition.category == .needsReview)

                        CategoryGlyph(definition: definition)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(definition.name).font(.headline)
                            Text(definition.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(definition.extensions.prefix(5).map { ".\($0)" }.joined(separator: " "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Button("编辑") {
                            editingCategory = definition
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .sheet(item: $editingCategory) { definition in
            CategoryEditorView(
                definition: definition,
                canDelete: state.profile.categories.contains(where: { $0.id == definition.id })
                    && definition.category != .needsReview,
                onSave: { updated in
                    Task { await state.upsertCategory(updated) }
                },
                onDelete: {
                    Task { await state.removeCategory(definition.id) }
                }
            )
        }
    }

    private func newCategory() -> CategoryDefinition {
        .init(
            id: UUID().uuidString,
            name: "新分类",
            folderName: "新分类",
            icon: "folder.fill",
            color: "blue",
            description: "说明哪些文件属于这里。",
            enabled: true,
            extensions: [],
            filenameKeywords: [],
            contentKeywords: [],
            examples: [],
            contentAware: true,
            extensionConfidence: 80
        )
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.importProfile(from: url) }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "filemorrow-profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.exportProfile(to: url) }
    }
}

private struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let canDelete: Bool
    let onSave: (CategoryDefinition) -> Void
    let onDelete: () -> Void

    @State private var draft: CategoryDefinition
    @State private var extensionsText: String
    @State private var filenameKeywordsText: String
    @State private var contentKeywordsText: String
    @State private var examplesText: String

    init(
        definition: CategoryDefinition,
        canDelete: Bool,
        onSave: @escaping (CategoryDefinition) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: definition)
        _extensionsText = State(initialValue: definition.extensions.joined(separator: ", "))
        _filenameKeywordsText = State(initialValue: definition.filenameKeywords.joined(separator: ", "))
        _contentKeywordsText = State(initialValue: definition.contentKeywords.joined(separator: ", "))
        _examplesText = State(initialValue: definition.examples.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("标识") {
                    TextField("名称", text: $draft.name)
                    TextField("目标文件夹", text: $draft.folderName)
                    TextField("说明", text: $draft.description, axis: .vertical)
                    TextField("SF 符号", text: $draft.icon)
                    Picker("颜色", selection: $draft.color) {
                        ForEach(["indigo", "blue", "cyan", "teal", "mint", "green", "yellow", "orange", "red", "pink", "purple", "brown", "gray"], id: \.self) {
                            Text(colorLabel($0)).tag($0)
                        }
                    }
                }

                Section("分类指南") {
                    TextField("扩展名", text: $extensionsText, prompt: Text("pdf, docx, epub"))
                    TextField("文件名关键词", text: $filenameKeywordsText, axis: .vertical)
                    TextField("内容关键词", text: $contentKeywordsText, axis: .vertical)
                    TextField("示例", text: $examplesText, axis: .vertical)
                    Toggle("最终分类前先查看内容", isOn: $draft.contentAware)
                    Stepper(
                        "格式置信度：\(draft.extensionConfidence)%",
                        value: $draft.extensionConfidence,
                        in: 0...100,
                        step: 5
                    )
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if canDelete {
                    Button("删除分类", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.folderName = draft.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.extensions = parse(extensionsText).map {
                        $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    }
                    draft.filenameKeywords = parse(filenameKeywordsText)
                    draft.contentKeywords = parse(contentKeywordsText)
                    draft.examples = parse(examplesText)
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 620, height: 620)
    }

    private func parse(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func colorLabel(_ value: String) -> String {
        switch value {
        case "indigo": "靛蓝"
        case "blue": "蓝色"
        case "cyan": "青色"
        case "teal": "青绿"
        case "mint": "薄荷"
        case "green": "绿色"
        case "yellow": "黄色"
        case "orange": "橙色"
        case "red": "红色"
        case "pink": "粉色"
        case "purple": "紫色"
        case "brown": "棕色"
        case "gray": "灰色"
        default: value
        }
    }
}

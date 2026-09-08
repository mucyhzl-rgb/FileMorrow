import AppKit
import Foundation
import Observation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    var files: [FileRecord] = []
    var ageSelection: AgeView = .today
    var categoryFilter: ArchiveCategory?
    var selectedFileID: String?
    var query = ""
    var status = "就绪"
    var progress: Double?
    var isWorking = false
    var lastError: String?
    var isAnalyzing = false
    var intelligenceAvailability = IntelligenceAvailabilityState.checking
    var classificationMode = ClassificationMode(
        rawValue: UserDefaults.standard.string(forKey: "classificationMode") ?? ""
    ) ?? .formatOnly
    var automaticOrganization = UserDefaults.standard.object(forKey: "automaticOrganization") as? Bool ?? true
    var launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? true
    var keepInDock = UserDefaults.standard.object(forKey: "keepInDock") as? Bool ?? true
    var duplicateGroups: [DuplicateGroup] = []
    var isScanningDuplicates = false
    var duplicateScanProgress: DuplicateScanProgress?
    var extractedArchives: [ExtractedArchive] = []
    var isScanningExtractedArchives = false
    var extractedArchiveScanProgress: ExtractedArchiveScanProgress?
    var hasScannedExtractedArchives = false
    var redundantInstallers: [RedundantInstaller] = []
    var isScanningInstallers = false
    var installerScanProgress: InstallerScanProgress?
    var hasScannedInstallers = false
    var organizationProposal: OrganizationProposal?
    var lastOrganizedCount = 0
    var onboardingRequestID: UUID?
    var profile = ProfileStore.fallback
    private var shouldCancelAnalysis = false

    @ObservationIgnored private let store = PersistenceStore()
    @ObservationIgnored private let profileStore = ProfileStore()
    @ObservationIgnored private let scanner = FileScanner()
    @ObservationIgnored private let extractor = ContentExtractor()
    @ObservationIgnored private let ai = AIClassifier()
    @ObservationIgnored private let duplicateScanner = DuplicateScanner()
    @ObservationIgnored private let archiveScanner = ExtractedArchiveScanner()
    @ObservationIgnored private let installerScanner = InstallerScanner()
    @ObservationIgnored private let folderBranding = FolderBrandingService()
    @ObservationIgnored private lazy var organizer = OrganizerService(store: store)
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var duplicateScanTask: Task<Void, Never>?
    @ObservationIgnored private var archiveScanTask: Task<Void, Never>?
    @ObservationIgnored private var installerScanTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored let downloadsURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")

    private var archiveDays: Int { max(1, UserDefaults.standard.integer(forKey: "archiveDays").nonZero(or: 7)) }
    var minimumConfidence: Int { max(60, UserDefaults.standard.integer(forKey: "minimumConfidence").nonZero(or: 85)) }
    var cutoffDate: Date { Date().addingTimeInterval(TimeInterval(-archiveDays * 24 * 60 * 60)) }

    var visibleFiles: [FileRecord] {
        files.filter { record in
            ageMatches(record)
                && (categoryFilter == nil || record.category == categoryFilter)
                && (query.isEmpty || record.name.localizedCaseInsensitiveContains(query))
        }
        .sorted { $0.dateAdded > $1.dateAdded }
    }

    var selectedFile: FileRecord? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID }
    }

    var readyFiles: [FileRecord] {
        files.filter { ArchiveEligibility.isEligible($0, cutoffDate: cutoffDate) }
    }
    var approvedReadyFiles: [FileRecord] {
        readyFiles.filter { $0.confidence >= minimumConfidence && $0.category != .needsReview }
    }
    var awaitingAnalysisFiles: [FileRecord] {
        guard classificationMode == .smartContent else { return [] }
        return files.filter(needsAnalysis)
    }
    var needsHumanReviewFiles: [FileRecord] {
        readyFiles.filter {
            (classificationMode == .formatOnly && $0.category == .needsReview)
                || ($0.source != .rule && ($0.confidence < minimumConfidence || $0.category == .needsReview))
        }
    }
    var awaitingAnalysisCount: Int { awaitingAnalysisFiles.count }
    var reviewCount: Int { needsHumanReviewFiles.count }
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var enabledCategories: [CategoryDefinition] { profile.enabledCategories }
    var visibleCategories: [CategoryDefinition] {
        enabledCategories.filter { definition in
            definition.category != .needsReview
                && files.contains { $0.category == definition.category }
        }
    }
    var duplicateExtraCount: Int { duplicateGroups.reduce(0) { $0 + $1.extras.count } }
    var duplicateWastedSize: Int64 { duplicateGroups.reduce(0) { $0 + $1.wastedSize } }
    var extractedArchiveCount: Int { extractedArchives.count }
    var extractedArchiveReclaimableSize: Int64 {
        extractedArchives.reduce(0) { $0 + $1.archiveSize }
    }
    var redundantInstallerCount: Int { redundantInstallers.count }
    var redundantInstallerReclaimableSize: Int64 {
        redundantInstallers.reduce(0) { $0 + $1.installerSize }
    }
    var totalReclaimableSize: Int64 {
        duplicateWastedSize + extractedArchiveReclaimableSize + redundantInstallerReclaimableSize
    }
    var intelligenceReady: Bool { intelligenceAvailability.isReady }
    var intelligenceStatusTitle: String { intelligenceAvailability.title }
    var intelligenceStatusDetail: String { intelligenceAvailability.detail }

    init() {
        startAutomaticScheduler()
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"), launchAtLogin {
            try? SMAppService.mainApp.register()
        }
    }

    deinit {
        automaticTask?.cancel()
        duplicateScanTask?.cancel()
        archiveScanTask?.cancel()
        installerScanTask?.cancel()
    }

    func definition(for category: ArchiveCategory) -> CategoryDefinition {
        profile.definition(for: category)
            ?? profile.definition(for: .needsReview)
            ?? ProfileStore.fallback.categories.last!
    }

    func requestOnboarding() {
        onboardingRequestID = UUID()
    }

    func scan() async {
        isWorking = true
        progress = nil
        status = "正在扫描下载文件夹…"
        defer { isWorking = false }
        let saved = await store.decisions()
        profile = await profileStore.load()
        intelligenceAvailability = await ai.availability
        files = await scanner.scan(
            downloadsURL: downloadsURL,
            saved: saved,
            profile: profile,
            mode: classificationMode
        )
        folderBranding.brandManagedFolders(downloadsURL: downloadsURL, profile: profile)
        if !files.isEmpty {
            try? await store.pruneDecisions(
                keeping: FileScanner.livePaths(for: files, downloadsURL: downloadsURL)
            )
        }
        status = classificationMode == .formatOnly
            ? "已扫描 \(files.count.formatted()) 个文件 • 按格式整理"
            : "已扫描 \(files.count.formatted()) 个文件 • 智能内容模式"
        if selectedFileID != nil && selectedFile == nil { selectedFileID = nil }
    }

    func refreshAfterActivation() async {
        guard !isWorking else { return }
        let previousCount = files.count
        let previousSelection = selectedFileID
        await scan()

        let removedCount = max(0, previousCount - files.count)
        if removedCount > 0 {
            status = "已刷新 • 移除了 \(removedCount) 个已删除文件"
        } else if previousSelection != nil, selectedFileID == nil {
            status = "已刷新 • 已清除被删除文件的预览"
        }
    }

    func setAutomaticOrganization(_ enabled: Bool) {
        automaticOrganization = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticOrganization")
        status = enabled
            ? "自动整理已开启 • 每小时检查一次"
            : "自动整理已关闭"
        if enabled {
            Task { await runAutomaticOrganization() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            lastError = error.localizedDescription
            status = "无法更改登录时打开"
        }
    }

    func setKeepInDock(_ enabled: Bool) {
        guard DockVisibility.apply(keepInDock: enabled) else {
            lastError = "macOS 无法更改程序坞显示。"
            status = "无法更改程序坞显示"
            return
        }
        keepInDock = enabled
        UserDefaults.standard.set(enabled, forKey: "keepInDock")
        status = enabled
            ? "FileMorrow 将保留在程序坞中"
            : "FileMorrow 正在菜单栏中运行"
        if enabled {
            NSApplication.shared.activate()
        }
    }

    func runAutomaticOrganization() async {
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
              automaticOrganization,
              !isWorking
        else { return }
        await scan()

        if classificationMode == .smartContent, intelligenceReady, !awaitingAnalysisFiles.isEmpty {
            await analyzeReady()
        }

        guard !approvedReadyFiles.isEmpty else {
            status = reviewCount == 0
                ? "自动检查完成 • 没有超过 \(archiveDays) 天的文件"
                : "自动检查完成 • \(reviewCount) 个不确定的文件需要审核"
            return
        }

        let count = approvedReadyFiles.count
        await organizeApproved()
        status = "已自动整理 \(count) 个文件 • 可以撤销上次整理"
    }

    func checkAndPrepareOrganization() async {
        guard !isWorking else { return }
        await scan()
        if classificationMode == .smartContent, intelligenceReady, !awaitingAnalysisFiles.isEmpty {
            await analyzeReady()
        }
        prepareOrganizationProposal()
    }

    func completeOnboarding(
        mode: ClassificationMode,
        automaticOrganization enabled: Bool,
        launchAtLogin launchEnabled: Bool
    ) async {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        automaticOrganization = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticOrganization")
        await setClassificationMode(mode)
        setLaunchAtLogin(launchEnabled)
        status = enabled
            ? "设置完成 • 自动整理每小时运行一次"
            : "设置完成 • 自动整理已关闭"
        if enabled { await runAutomaticOrganization() }
    }

    func analyzeReady(limit: Int? = nil) async {
        guard !isWorking else { return }
        guard classificationMode == .smartContent else {
            status = "请在设置中切换到智能内容，才能使用 Apple Intelligence"
            return
        }
        guard intelligenceReady else {
            status = "这台 Mac 上无法使用 Apple Intelligence"
            lastError = intelligenceStatusDetail
            return
        }
        // Identify work by file id, never by array index: `files` is replaced
        // wholesale by any rescan, and this loop suspends on extraction and on
        // the model. An index captured before an await can point at a
        // different file — or past the end of the array — once it resumes.
        let candidates = files.filter(needsAnalysis).map(\.id)
        let selected = limit.map { Array(candidates.prefix($0)) } ?? candidates
        guard !selected.isEmpty else {
            status = "没有需要 AI 分析的文件"
            return
        }

        isWorking = true
        isAnalyzing = true
        shouldCancelAnalysis = false
        lastError = nil
        defer {
            isWorking = false
            isAnalyzing = false
            progress = nil
        }

        var completed = 0
        var pendingDecisions: [SavedDecision] = []
        for id in selected {
            guard !Task.isCancelled, !shouldCancelAnalysis else { break }
            guard let record = files.first(where: { $0.id == id }) else { continue }
            status = "正在读取 \(record.name)…"
            let type = UTType(record.contentType)
            let excerpt = await extractor.extract(from: record.url, contentType: type)

            if let localDecision = EvidenceClassifier.classify(excerpt, profile: profile) {
                if let updated = apply(to: id, excerpt: excerpt, {
                    $0.category = localDecision.category
                    $0.confidence = localDecision.confidence
                    $0.reason = localDecision.reason
                    $0.source = .localContent
                }) {
                    pendingDecisions.append(decision(for: updated))
                }
                completed += 1
                progress = Double(completed) / Double(selected.count)
                continue
            }

            do {
                status = "Apple Intelligence • \(completed + 1)/\(selected.count)"
                let (result, definition) = try await ai.classify(
                    filename: record.name,
                    excerpt: excerpt,
                    categories: profile.enabledCategories
                )
                let category = definition.category
                if let updated = apply(to: id, excerpt: excerpt, { file in
                    if category == .needsReview, record.category != .needsReview {
                        file.category = record.category
                        file.confidence = max(record.confidence, self.minimumConfidence)
                        file.reason = "已知的「\(self.definition(for: record.category).name)」格式，没有找到更明确的主题"
                        file.source = .formatFallback
                    } else {
                        file.category = category
                        file.confidence = category == .needsReview ? min(result.confidence, 59) : result.confidence
                        file.reason = self.cleanReason(result.reason, category: category)
                        file.source = .appleAI
                    }
                }) {
                    pendingDecisions.append(decision(for: updated))
                }
            } catch {
                // A temporary model failure must never erase a useful format rule.
                if let index = files.firstIndex(where: { $0.id == id }) {
                    files[index] = record
                }
                lastError = error.localizedDescription
            }
            completed += 1
            progress = Double(completed) / Double(selected.count)
        }

        // One write for the whole run instead of a full re-encode per file.
        if !pendingDecisions.isEmpty {
            try? await store.save(contentsOf: pendingDecisions)
        }
        status = shouldCancelAnalysis
            ? "已在 \(completed) 个文件后停止 • 判断结果已保存"
            : "已分析 \(completed) 个文件 • 没有移动文件"
    }

    /// Owns the analysis task so other workflows can wait for it to finish
    /// instead of racing a run that is still winding down.
    func startAnalysis(limit: Int? = nil) {
        guard !isWorking else { return }
        analysisTask = Task { [weak self] in await self?.analyzeReady(limit: limit) }
    }

    func cancelAnalysis() {
        shouldCancelAnalysis = true
        status = "将在当前文件完成后停止…"
    }

    private func needsAnalysis(_ record: FileRecord) -> Bool {
        !record.isOrganized
            && record.dateAdded < cutoffDate
            && record.source == .rule
            && (record.confidence < minimumConfidence || record.category == .archives)
    }

    /// Re-resolves a file by id and mutates it in place. Returns nil when the
    /// file disappeared from the list while the caller was suspended.
    private func apply(
        to id: String,
        excerpt: String,
        _ mutate: (inout FileRecord) -> Void
    ) -> FileRecord? {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&files[index])
        files[index].excerpt = excerpt
        return files[index]
    }

    func startDuplicateScan() {
        guard !isWorking else { return }
        duplicateScanTask?.cancel()
        duplicateScanTask = Task { await scanDuplicates() }
    }

    func scanDuplicates() async {
        guard !isWorking else { return }
        isWorking = true
        isScanningDuplicates = true
        duplicateScanProgress = nil
        status = "正在查找完全相同的重复文件…"
        let result = await duplicateScanner.scan(root: downloadsURL) { [weak self] update in
            await MainActor.run {
                self?.duplicateScanProgress = update
                self?.progress = update.fraction
                self?.status = update.currentFile.map {
                    "\(update.stage.rawValue) • \($0)"
                } ?? update.stage.rawValue
            }
        }
        if !Task.isCancelled { duplicateGroups = result }
        isScanningDuplicates = false
        isWorking = false
        progress = nil
        duplicateScanProgress = nil
        status = Task.isCancelled
            ? "重复文件扫描已停止"
            : duplicateGroups.isEmpty
                ? "没有找到完全相同的重复文件"
                : "找到 \(duplicateExtraCount) 个待审核的重复副本"
    }

    func cancelDuplicateScan() {
        duplicateScanTask?.cancel()
        status = "正在停止重复文件扫描…"
    }

    func trashDuplicateExtras(in group: DuplicateGroup) async {
        guard !isWorking else { return }
        isWorking = true
        status = "正在把重复副本移到废纸篓…"
        do {
            let count = try await duplicateScanner.trashExtras(in: group)
            status = "已将 \(count) 个完全相同的副本移到废纸篓"
            duplicateGroups = await duplicateScanner.scan(root: downloadsURL)
            await scan()
        } catch {
            lastError = error.localizedDescription
            status = "重复文件清理需要注意"
        }
        isWorking = false
    }

    func startExtractedArchiveScan() {
        guard !isWorking else { return }
        archiveScanTask?.cancel()
        archiveScanTask = Task { [weak self] in await self?.scanExtractedArchives() }
    }

    func scanExtractedArchives() async {
        guard !isWorking else { return }
        isWorking = true
        isScanningExtractedArchives = true
        extractedArchiveScanProgress = nil
        status = "正在检查哪些压缩包已经解压…"
        let result = await archiveScanner.scan(
            root: downloadsURL,
            profile: profile
        ) { [weak self] update in
            await MainActor.run {
                self?.extractedArchiveScanProgress = update
                self?.progress = update.fraction
                self?.status = update.currentArchive.map { "正在检查 \($0)…" }
                    ?? "正在检查压缩包…"
            }
        }
        if !Task.isCancelled {
            extractedArchives = result
            hasScannedExtractedArchives = true
        }
        isScanningExtractedArchives = false
        isWorking = false
        progress = nil
        extractedArchiveScanProgress = nil
        status = Task.isCancelled
            ? "压缩包检查已停止"
            : extractedArchives.isEmpty
                ? "还没有完全解压的压缩包"
                : "\(extractedArchiveCount) 个已解压压缩包 • 可回收 \(ByteCountFormatter.string(fromByteCount: extractedArchiveReclaimableSize, countStyle: .file))"
    }

    func cancelExtractedArchiveScan() {
        archiveScanTask?.cancel()
        status = "正在停止压缩包检查…"
    }

    func trashExtractedArchives(_ archives: [ExtractedArchive]) async {
        guard !isWorking, !archives.isEmpty else { return }
        isWorking = true
        status = "正在把已解压的压缩包移到废纸篓…"
        defer { isWorking = false }

        var reclaimed: Int64 = 0
        var resolved: Set<String> = []
        var firstFailure: String?
        for archive in archives {
            do {
                if try await archiveScanner.trash(archive) {
                    reclaimed += archive.archiveSize
                }
                // Either it moved to Trash or it was already gone; both mean
                // it no longer belongs in the list.
                resolved.insert(archive.id)
            } catch {
                if firstFailure == nil { firstFailure = error.localizedDescription }
            }
        }

        let trashed = resolved.count
        extractedArchives.removeAll { resolved.contains($0.id) }
        lastError = firstFailure
        status = trashed == 0
            ? "没有压缩包被移到废纸篓"
            : "已将 \(trashed) 个已解压压缩包移到废纸篓 • 回收了 \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file))"
        await scan()
    }

    func startInstallerScan() {
        guard !isWorking else { return }
        installerScanTask?.cancel()
        installerScanTask = Task { [weak self] in await self?.scanInstallers() }
    }

    func scanInstallers() async {
        guard !isWorking else { return }
        isWorking = true
        isScanningInstallers = true
        installerScanProgress = nil
        status = "正在检查哪些安装包已经用过…"
        let result = await installerScanner.scan(root: downloadsURL, profile: profile) { [weak self] update in
            await MainActor.run {
                self?.installerScanProgress = update
                self?.progress = update.fraction
                self?.status = update.currentInstaller.map { "正在检查 \($0)…" }
                    ?? "正在检查安装包…"
            }
        }
        if !Task.isCancelled {
            redundantInstallers = result
            hasScannedInstallers = true
        }
        isScanningInstallers = false
        isWorking = false
        progress = nil
        installerScanProgress = nil
        status = Task.isCancelled
            ? "安装包检查已停止"
            : redundantInstallers.isEmpty
                ? "没有安装包对应本机已安装的软件"
                : "\(redundantInstallerCount) 个已用安装包 • 可回收 \(ByteCountFormatter.string(fromByteCount: redundantInstallerReclaimableSize, countStyle: .file))"
    }

    func cancelInstallerScan() {
        installerScanTask?.cancel()
        status = "正在停止安装包检查…"
    }

    func trashInstallers(_ installers: [RedundantInstaller]) async {
        guard !isWorking, !installers.isEmpty else { return }
        isWorking = true
        status = "正在把已用安装包移到废纸篓…"
        defer { isWorking = false }

        var reclaimed: Int64 = 0
        var resolved: Set<String> = []
        var firstFailure: String?
        for installer in installers {
            do {
                if try await installerScanner.trash(installer) {
                    reclaimed += installer.installerSize
                }
                resolved.insert(installer.id)
            } catch {
                if firstFailure == nil { firstFailure = error.localizedDescription }
            }
        }

        let trashed = resolved.count
        redundantInstallers.removeAll { resolved.contains($0.id) }
        lastError = firstFailure
        status = trashed == 0
            ? "没有安装包被移到废纸篓"
            : "已将 \(trashed) 个已用安装包移到废纸篓 • 回收了 \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file))"
        await scan()
    }

    /// Lets the user pick which copy of a duplicate group survives cleanup.
    func setDuplicateKeeper(_ url: URL, in group: DuplicateGroup) {
        guard let index = duplicateGroups.firstIndex(where: { $0.id == group.id }) else { return }
        duplicateGroups[index] = duplicateGroups[index].keeping(url)
    }

    func setClassificationMode(_ mode: ClassificationMode) async {
        guard mode != classificationMode else { return }
        // Rescanning replaces `files` wholesale, so the analysis run has to be
        // fully stopped first rather than merely asked to stop.
        if isAnalyzing {
            cancelAnalysis()
            await analysisTask?.value
        }
        classificationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "classificationMode")
        await scan()
    }

    func correctSelected(to category: ArchiveCategory) async {
        guard let id = selectedFileID, let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].category = category
        files[index].confidence = 100
        files[index].reason = "已由你确认"
        files[index].source = .user
        try? await saveDecision(for: files[index])
        status = "已保存你的更正"
    }

    func teach(
        fileID: String,
        category: ArchiveCategory,
        filenameKeyword: String,
        rememberExtension: Bool
    ) async {
        guard let fileIndex = files.firstIndex(where: { $0.id == fileID }),
              let categoryIndex = profile.categories.firstIndex(where: { $0.category == category }),
              category != .needsReview else { return }

        let filename = files[fileIndex].name
        let keyword = filenameKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty,
           !profile.categories[categoryIndex].filenameKeywords.contains(where: {
               $0.caseInsensitiveCompare(keyword) == .orderedSame
           }) {
            profile.categories[categoryIndex].filenameKeywords.append(keyword)
        }
        if !profile.categories[categoryIndex].examples.contains(where: {
            $0.caseInsensitiveCompare(filename) == .orderedSame
        }) {
            profile.categories[categoryIndex].examples.append(filename)
        }

        let ext = RuleClassifier.normalizedExtension(files[fileIndex].url)
        if rememberExtension, !ext.isEmpty {
            for index in profile.categories.indices {
                profile.categories[index].extensions.removeAll {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        .caseInsensitiveCompare(ext) == .orderedSame
                }
            }
            profile.categories[categoryIndex].extensions.append(ext)
        }

        files[fileIndex].category = category
        files[fileIndex].confidence = 100
        files[fileIndex].reason = "已由你确认，并加入整理配置"
        files[fileIndex].source = .user
        do {
            try await profileStore.save(profile)
            try await saveDecision(for: files[fileIndex])
            status = rememberExtension || !keyword.isEmpty
                ? "更正已保存 • 以后匹配的文件会沿用"
                : "更正已保存 • 已为 Apple Intelligence 添加示例"
        } catch {
            lastError = error.localizedDescription
            status = "无法保存教学规则"
        }
    }

    func setCategoryEnabled(_ id: String, enabled: Bool) async {
        guard let index = profile.categories.firstIndex(where: { $0.id == id }),
              profile.categories[index].category != .needsReview else { return }
        profile.categories[index].enabled = enabled
        await persistProfileAndRescan()
    }

    func upsertCategory(_ definition: CategoryDefinition) async {
        if let index = profile.categories.firstIndex(where: { $0.id == definition.id }) {
            profile.categories[index] = definition
        } else {
            let insertionIndex = profile.categories.firstIndex { $0.category == .needsReview }
                ?? profile.categories.endIndex
            profile.categories.insert(definition, at: insertionIndex)
        }
        await persistProfileAndRescan()
    }

    func removeCategory(_ id: String) async {
        guard id != ArchiveCategory.needsReview.rawValue else { return }
        profile.categories.removeAll { $0.id == id }
        await persistProfileAndRescan()
    }

    func importProfile(from url: URL) async {
        do {
            profile = try await profileStore.importProfile(from: url)
            status = "已导入「\(profile.name)」配置"
            await scan()
        } catch {
            lastError = error.localizedDescription
            status = "配置导入失败"
        }
    }

    func exportProfile(to url: URL) async {
        do {
            try await profileStore.export(profile, to: url)
            status = "已导出整理配置"
        } catch {
            lastError = error.localizedDescription
            status = "配置导出失败"
        }
    }

    func prepareOrganizationProposal(automaticCheck: Bool = false) {
        let candidates = approvedReadyFiles
        guard !candidates.isEmpty else {
            status = "还没有可以整理的文件"
            return
        }
        let grouped = Dictionary(grouping: candidates) { definition(for: $0.category).name }
        organizationProposal = .init(
            fileCount: candidates.count,
            totalSize: candidates.reduce(0) { $0 + $1.size },
            categoryCounts: grouped.map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name },
            automaticCheck: automaticCheck
        )
        status = automaticCheck
            ? "自动检查找到 \(candidates.count) 个文件 • 等待你确认"
            : "请查看整理计划"
    }

    func organizeApproved() async {
        guard !isWorking else { return }
        isWorking = true
        status = "正在整理已确认的文件…"
        defer { isWorking = false }
        do {
            let count = try await organizer.organize(
                approvedReadyFiles,
                downloadsURL: downloadsURL,
                minimumConfidence: minimumConfidence,
                profile: profile
            )
            lastOrganizedCount = count
            organizationProposal = nil
            status = "已整理 \(count) 个文件 • 可以撤销上次整理"
            await scan()
        } catch {
            lastError = error.localizedDescription
            status = "整理已安全停止"
        }
    }

    func undoLastMove() async {
        guard !isWorking else { return }
        isWorking = true
        status = "正在撤销上次整理…"
        defer { isWorking = false }
        do {
            let count = try await organizer.undoLast()
            if count > 0 { lastOrganizedCount = 0 }
            status = count == 0 ? "没有可撤销的操作" : "已还原 \(count) 个文件"
            await scan()
        } catch {
            lastError = error.localizedDescription
            status = "撤销需要注意"
        }
    }

    func count(for view: AgeView) -> Int {
        files.filter {
            switch view {
            case .today: Calendar.current.isDateInToday($0.dateAdded)
            case .yesterday: Calendar.current.isDateInYesterday($0.dateAdded)
            case .lastWeek: $0.dateAdded >= cutoffDate
            case .ready: ArchiveEligibility.isEligible($0, cutoffDate: cutoffDate)
            case .all: true
            case .duplicates, .extracted, .installers: false
            }
        }.count
    }

    private func ageMatches(_ record: FileRecord) -> Bool {
        switch ageSelection {
        case .today: Calendar.current.isDateInToday(record.dateAdded)
        case .yesterday: Calendar.current.isDateInYesterday(record.dateAdded)
        case .lastWeek: record.dateAdded >= cutoffDate
        case .ready: ArchiveEligibility.isEligible(record, cutoffDate: cutoffDate)
        case .all: true
        case .duplicates, .extracted, .installers: false
        }
    }

    private func saveDecision(for record: FileRecord) async throws {
        try await store.save(decision(for: record))
    }

    private func decision(for record: FileRecord) -> SavedDecision {
        let modified = (try? record.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return .init(
            path: record.url.path,
            modifiedAt: modified,
            category: record.category,
            confidence: record.confidence,
            reason: record.reason,
            source: record.source,
            modelVersion: 6
        )
    }

    private func cleanReason(_ value: String, category: ArchiveCategory) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"[\{\}\[\]\"]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lowercased = cleaned.lowercased()
        let weakPhrases = [
            "confirmation request", "information retrieval", "filename analysis",
            "file classification", "classifier", "insufficient evidence"
        ]
        let hasWeakPhrase = weakPhrases.contains(where: lowercased.contains)
        let hasFormattingJunk = cleaned.contains("=") || cleaned.contains("\\")
        let wordCount = cleaned.split(separator: " ").count
        guard !cleaned.isEmpty, !hasWeakPhrase, !hasFormattingJunk, (3...18).contains(wordCount) else {
            return category == .needsReview
                ? "内容不够明确，不宜自动整理"
                : "内容和文件名符合「\(definition(for: category).name)」"
        }
        return String(cleaned.prefix(140))
    }

    private func persistProfileAndRescan() async {
        do {
            try await profileStore.save(profile)
            status = "已保存配置更改"
            await scan()
        } catch {
            lastError = error.localizedDescription
            status = "无法保存配置"
        }
    }

    private func startAutomaticScheduler() {
        automaticTask = Task { [weak self] in
            await self?.runAutomaticOrganization()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
                guard !Task.isCancelled else { return }
                await self?.runAutomaticOrganization()
            }
        }
    }
}

private extension Int {
    func nonZero(or fallback: Int) -> Int { self == 0 ? fallback : self }
}

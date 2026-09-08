import AppKit
import Foundation

@MainActor
final class FolderBrandingService {
    nonisolated private static let stampVersion = "v1"

    /// Returns how many folders received a new icon. Folders that already
    /// match the current category look are left alone so relaunch does not
    /// hitch the UI by redrawing Finder icons on the main thread.
    @discardableResult
    func brandManagedFolders(downloadsURL: URL, profile: OrganizationProfile) -> Int {
        var updated = 0
        for definition in profile.enabledCategories where definition.category != .needsReview {
            for folderName in definition.managedFolderNames {
                let folder = downloadsURL.appending(path: folderName, directoryHint: .isDirectory)
                guard AppSupportPaths.hasManagedMarker(in: folder) else { continue }
                if applyIconIfNeeded(to: folder, definition: definition) {
                    updated += 1
                }
            }
        }
        return updated
    }

    nonisolated enum IconUpdate: Equatable {
        case unchanged
        case recordExisting
        case redraw
    }

    nonisolated static func iconUpdate(stamp: String?, hasCustomIcon: Bool, signature: String) -> IconUpdate {
        if hasCustomIcon, stamp == signature { return .unchanged }
        if hasCustomIcon, stamp == nil { return .recordExisting }
        return .redraw
    }

    private func applyIconIfNeeded(to folder: URL, definition: CategoryDefinition) -> Bool {
        let signature = Self.signature(for: definition)
        let stampURL = folder.appending(path: AppSupportPaths.iconStampName)
        let stamp = try? String(contentsOf: stampURL, encoding: .utf8)
        let hasIcon = hasCustomIcon(folder)

        switch Self.iconUpdate(stamp: stamp, hasCustomIcon: hasIcon, signature: signature) {
        case .unchanged:
            return false
        case .recordExisting:
            try? signature.write(to: stampURL, atomically: true, encoding: .utf8)
            return false
        case .redraw:
            break
        }

        let image = folderIcon(
            color: color(named: definition.color),
            symbolName: definition.icon
        )
        NSWorkspace.shared.setIcon(image, forFile: folder.path)
        try? signature.write(to: stampURL, atomically: true, encoding: .utf8)
        return true
    }

    nonisolated static func signature(for definition: CategoryDefinition) -> String {
        "\(definition.icon)|\(definition.color)|\(stampVersion)"
    }

    private func hasCustomIcon(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "Icon\r").path)
    }

    private func folderIcon(color: NSColor, symbolName: String) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high

        let folderConfiguration = NSImage.SymbolConfiguration(pointSize: 410, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(folderConfiguration)
        folder?.draw(
            in: NSRect(x: 44, y: 36, width: 424, height: 424),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let badgeRect = NSRect(x: 306, y: 92, width: 126, height: 126)
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: 67, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let requestedSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)
        requestedSymbol?
            .withSymbolConfiguration(badgeConfiguration)?
            .draw(
                in: badgeRect.insetBy(dx: 27, dy: 27),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )

        image.isTemplate = false
        return image
    }

    private func color(named value: String) -> NSColor {
        switch value.lowercased() {
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "mint": .systemMint
        case "teal": .systemTeal
        case "cyan": .systemCyan
        case "blue": .systemBlue
        case "purple": .systemPurple
        case "pink": .systemPink
        case "brown": .systemBrown
        case "gray": .systemGray
        default: .systemIndigo
        }
    }
}

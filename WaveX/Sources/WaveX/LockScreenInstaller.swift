import Foundation
import AppKit

/// Registers exported movies in macOS's Aerial wallpaper catalog
/// (`~/Library/Application Support/com.apple.wallpaper/aerials`). This is a private,
/// unsupported integration: macOS may rewrite the catalog on updates, in which case
/// `install` simply needs to be run again. Everything is scoped to the current user and
/// the original `entries.json` is backed up before the first edit.
enum LockScreenInstaller {
    static let categoryID = "B7E1C0DE-5A5E-4C0B-9C1D-57A0E0A7E001"
    static let subcategoryID = "B7E1C0DE-5A5E-4C0B-9C1D-57A0E0A7E002"
    /// Apple's "Landscape" category. Our subcategory is added there too, so the tile shows up even if
    /// the Settings UI only renders categories it already knows about.
    static let hostCategoryID = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
    static let shotPrefix = "WAVEX_"

    enum InstallError: LocalizedError {
        case catalogMissing
        case malformedCatalog

        var errorDescription: String? {
            switch self {
            case .catalogMissing:
                return "macOS has not created the aerial wallpaper catalog yet. Open System Settings → Wallpaper, scroll to the Aerials section once, then try again."
            case .malformedCatalog:
                return "The aerial catalog (entries.json) has an unexpected format."
            }
        }
    }

    struct Installed: Identifiable, Equatable {
        let id: String
        let name: String
        let variantID: String
    }

    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["WAVEX_AERIALS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }
    static var entriesURL: URL { root.appendingPathComponent("manifest/entries.json") }
    static var backupURL: URL { root.appendingPathComponent("manifest/entries.json.wavex-original") }
    static var videosDir: URL { root.appendingPathComponent("videos", isDirectory: true) }
    static var thumbnailsDir: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }

    static var isCatalogPresent: Bool { FileManager.default.fileExists(atPath: entriesURL.path) }

    // MARK: - Catalog IO

    private static func loadEntries() throws -> [String: Any] {
        guard isCatalogPresent else { throw InstallError.catalogMissing }
        let data = try Data(contentsOf: entriesURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["assets"] is [[String: Any]], json["categories"] is [[String: Any]] else {
            throw InstallError.malformedCatalog
        }
        return json
    }

    private static func saveEntries(_ json: [String: Any]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: backupURL.path) {
            try fm.copyItem(at: entriesURL, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: entriesURL, options: .atomic)
    }

    static func installed() -> [Installed] {
        guard let json = try? loadEntries(), let assets = json["assets"] as? [[String: Any]] else { return [] }
        return assets.compactMap { a in
            guard let shot = a["shotID"] as? String, shot.hasPrefix(shotPrefix), let id = a["id"] as? String else { return nil }
            return Installed(id: id, name: (a["accessibilityLabel"] as? String) ?? shot,
                             variantID: String(shot.dropFirst(shotPrefix.count)))
        }
    }

    // MARK: - Install / remove

    /// Copies the movie and preview into the catalog and adds (or replaces) the entry. Returns the asset ID.
    @discardableResult
    static func install(movie: URL, thumbnail: URL?, variant: Variant) throws -> String {
        var json = try loadEntries()
        var assets = json["assets"] as! [[String: Any]]
        var categories = json["categories"] as! [[String: Any]]
        let fm = FileManager.default

        let shotID = shotPrefix + variant.id
        let assetID = (assets.first { ($0["shotID"] as? String) == shotID }?["id"] as? String) ?? UUID().uuidString
        try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)

        let movieDest = videosDir.appendingPathComponent("\(assetID).mov")
        try? fm.removeItem(at: movieDest)
        try fm.copyItem(at: movie, to: movieDest)

        let thumbDest = thumbnailsDir.appendingPathComponent("\(assetID).png")
        if let thumbnail {
            // The thumbnail cache is keyed by entity ID for assets, categories and subcategories alike.
            for id in [assetID, categoryID, subcategoryID] {
                let dest = thumbnailsDir.appendingPathComponent("\(id).png")
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: thumbnail, to: dest)
            }
        }

        let name = "Wave X · \(variant.name)"
        let order = assets.filter { ($0["shotID"] as? String)?.hasPrefix(shotPrefix) == true }.count
        let entry: [String: Any] = [
            "accessibilityLabel": name,
            "categories": [categoryID, hostCategoryID],
            "id": assetID,
            "includeInShuffle": false,
            "localizedNameKey": name,
            "pointsOfInterest": [String: Any](),
            "preferredOrder": order,
            "previewImage": thumbDest.absoluteString,
            "shotID": shotID,
            "showInTopLevel": true,
            // Every Apple asset belongs to a subcategory and the Settings grid is built from them,
            // so mirror that structure exactly: one "Wave X" category holding one subcategory.
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": movieDest.absoluteString,
        ]
        assets.removeAll { ($0["shotID"] as? String) == shotID }
        assets.append(entry)

        let subcategory: [String: Any] = [
            "id": subcategoryID,
            "localizedNameKey": "Wave X",
            "localizedDescriptionKey": "PlayStation 3 XMB wave",
            "preferredOrder": 0,
            "previewImage": thumbDest.absoluteString,
            "representativeAssetID": assetID,
        ]
        // Mirror the subcategory into Apple's Landscape category.
        if let hi = categories.firstIndex(where: { ($0["id"] as? String) == hostCategoryID }) {
            var subs = (categories[hi]["subcategories"] as? [[String: Any]]) ?? []
            subs.removeAll { ($0["id"] as? String) == subcategoryID }
            var hosted = subcategory
            hosted["preferredOrder"] = -1000   // first tile in the section
            subs.append(hosted)
            categories[hi]["subcategories"] = subs
        }

        categories.removeAll { ($0["id"] as? String) == categoryID }
        categories.append([
            "id": categoryID,
            "localizedNameKey": "Wave X",
            "localizedDescriptionKey": "PlayStation 3 XMB wave",
            "preferredOrder": 99,
            "previewImage": thumbDest.absoluteString,
            "representativeAssetID": assetID,
            "subcategories": [subcategory],
        ])

        json["assets"] = assets
        json["categories"] = categories
        try saveEntries(json)
        try? registerStrings(["Wave X", "PlayStation 3 XMB wave", name])
        return assetID
    }

    // MARK: - Localized strings

    static var loctableURL: URL {
        root.appendingPathComponent("manifest/TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable")
    }
    static var loctableBackupURL: URL { loctableURL.appendingPathExtension("wavex-original") }

    /// Names in the catalog are looked up by key in the aerial strings table. Add our keys
    /// (mapping to themselves) to every language so the lookup never comes back empty.
    static func registerStrings(_ keys: [String]) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: loctableURL.path) else { return }
        if !fm.fileExists(atPath: loctableBackupURL.path) {
            try fm.copyItem(at: loctableURL, to: loctableBackupURL)
        }
        let data = try Data(contentsOf: loctableURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var table = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else { return }
        var changed = false
        for (lang, value) in table {
            guard var strings = value as? [String: Any] else { continue }
            for key in keys where strings[key] == nil {
                strings[key] = key
                changed = true
            }
            table[lang] = strings
        }
        guard changed else { return }
        let out = try PropertyListSerialization.data(fromPropertyList: table, format: format, options: 0)
        try out.write(to: loctableURL, options: .atomic)
    }

    static func restoreStrings() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: loctableBackupURL.path) else { return }
        try? fm.removeItem(at: loctableURL)
        try? fm.moveItem(at: loctableBackupURL, to: loctableURL)
    }

    static func remove(assetID: String) throws {
        var json = try loadEntries()
        var assets = json["assets"] as! [[String: Any]]
        var categories = json["categories"] as! [[String: Any]]
        assets.removeAll { ($0["id"] as? String) == assetID }
        let remaining = assets.filter { ($0["shotID"] as? String)?.hasPrefix(shotPrefix) == true }
        if remaining.isEmpty {
            categories.removeAll { ($0["id"] as? String) == categoryID }
            if let hi = categories.firstIndex(where: { ($0["id"] as? String) == hostCategoryID }) {
                var subs = (categories[hi]["subcategories"] as? [[String: Any]]) ?? []
                subs.removeAll { ($0["id"] as? String) == subcategoryID }
                categories[hi]["subcategories"] = subs
            }
        } else if let idx = categories.firstIndex(where: { ($0["id"] as? String) == categoryID }) {
            categories[idx]["representativeAssetID"] = remaining[0]["id"]
        }
        json["assets"] = assets
        json["categories"] = categories
        try saveEntries(json)
        let fm = FileManager.default
        try? fm.removeItem(at: videosDir.appendingPathComponent("\(assetID).mov"))
        try? fm.removeItem(at: thumbnailsDir.appendingPathComponent("\(assetID).png"))
        if remaining.isEmpty {
            try? fm.removeItem(at: thumbnailsDir.appendingPathComponent("\(categoryID).png"))
            try? fm.removeItem(at: thumbnailsDir.appendingPathComponent("\(subcategoryID).png"))
            restoreStrings()
        }
    }

    static func removeAll() throws {
        for item in installed() { try remove(assetID: item.id) }
    }

    /// Asks the wallpaper agent to re-read the catalog. launchd relaunches it immediately.
    static func restartWallpaperAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        try? p.run()
        p.waitUntilExit()
    }

    static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

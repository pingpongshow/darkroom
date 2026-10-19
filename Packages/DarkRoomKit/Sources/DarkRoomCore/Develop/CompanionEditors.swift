import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import ApplicationServices

/// External editors DarkRoom can hand a photo to ("Edit in…"), and how each returns its result.
public struct CompanionEditor: Identifiable, Hashable, Sendable {
    public enum Return: String, Sendable, Codable {
        /// The editor saves over the working file (or a .psd / .kra beside it); done when its window closes.
        case onClose
        /// darktable: the .xmp history is rendered with darktable-cli when the window closes.
        case darktableCLI
        /// RawTherapee: the .pp3 profile is rendered with rawtherapee-cli when the window closes.
        case rawTherapeeCLI
        /// The user exports into the session's Export folder; the first exported image is the result.
        case watchedExport
    }

    public var id: String
    public var name: String
    public var appURL: URL
    public var returns: Return
    /// Work on a .psd copy (Photoshop / PhotoCraft) so layers can be kept.
    public var workingExtension: String?
    public var handlesRAW: Bool

    /// Known editors by bundle identifier (and app-name hints for ones without a stable id).
    static let known: [(ids: [String], nameHints: [String], name: String, returns: Return, working: String?, raw: Bool)] = [
        (["org.darktable"], ["darktable"], "darktable", .darktableCLI, nil, true),
        (["com.rawtherapee.RawTherapee"], ["RawTherapee"], "RawTherapee", .rawTherapeeCLI, nil, true),
        (["com.adobe.Photoshop"], ["Adobe Photoshop"], "Photoshop", .onClose, "psd", true),
        ([], ["PhotoCraft"], "PhotoCraft", .onClose, "psd", false),
        ([], ["LightCraft"], "LightCraft", .watchedExport, nil, true),
        (["com.adobe.LightroomClassicCC7"], ["Lightroom Classic"], "Lightroom Classic", .watchedExport, nil, true),
        (["com.adobe.mas.lightroomCC", "com.adobe.lightroomCC"], ["Adobe Lightroom"], "Lightroom", .watchedExport, nil, true),
        ([], ["Capture One"], "Capture One", .watchedExport, nil, true),
        ([], ["DxO PhotoLab"], "DxO PhotoLab", .watchedExport, nil, true),
        (["com.seriflabs.affinityphoto2", "com.seriflabs.affinityphoto"], ["Affinity Photo"], "Affinity Photo", .watchedExport, nil, true),
        (["com.pixelmatorteam.pixelmator.x"], ["Pixelmator Pro"], "Pixelmator Pro", .onClose, nil, true),
        (["org.gimp.gimp-2.10", "org.gimp.gimp-3.0", "org.gimp.gimp"], ["GIMP"], "GIMP", .watchedExport, nil, false),
        (["org.krita"], ["krita"], "Krita", .onClose, "kra", false),
        (["com.apple.Preview"], ["Preview"], "Preview", .onClose, nil, false),
    ]

    /// Installed editors (known ones first, then any other app that opens images).
    public static func installed() -> [CompanionEditor] {
        var found: [CompanionEditor] = []
        var seen = Set<URL>()
        let imageApps = (NSWorkspace.shared.urlsForApplications(toOpen: .jpeg) + NSWorkspace.shared.urlsForApplications(toOpen: .rawImage))
        for k in known {
            let url = k.ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
                ?? imageApps.first { app in k.nameHints.contains { app.lastPathComponent.localizedCaseInsensitiveContains($0) } }
                ?? appInApplications(k.nameHints)
            guard let url, !seen.contains(url) else { continue }
            seen.insert(url)
            found.append(CompanionEditor(id: k.name, name: k.name, appURL: url, returns: k.returns, workingExtension: k.working, handlesRAW: k.raw))
        }
        for app in imageApps where !seen.contains(app) && !app.path.contains("/System/") {
            seen.insert(app)
            let name = app.deletingPathExtension().lastPathComponent
            found.append(CompanionEditor(id: name, name: name, appURL: app, returns: .onClose, workingExtension: nil, handlesRAW: false))
        }
        return found
    }

    static func appInApplications(_ hints: [String]) -> URL? {
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            guard let apps = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            if let match = apps.first(where: { app in app.hasSuffix(".app") && hints.contains { app.localizedCaseInsensitiveContains($0) } }) {
                return URL(fileURLWithPath: dir).appending(path: match)
            }
        }
        return nil
    }

    /// Defaults from the plan: darktable for RAW, PhotoCraft for JPG/HEIC/PNG (else the first suitable editor).
    public static func defaultEditor(for file: URL, among editors: [CompanionEditor], preferences: [String: String]) -> CompanionEditor? {
        let isRAW = RenderEngine.isRAW(file)
        let key = isRAW ? "raw" : "image"
        if let chosen = preferences[key], let editor = editors.first(where: { $0.id == chosen }) { return editor }
        let preferred = isRAW ? ["darktable", "RawTherapee", "Lightroom Classic", "Photoshop"] : ["PhotoCraft", "Photoshop", "Pixelmator Pro", "Affinity Photo", "Preview"]
        for name in preferred { if let e = editors.first(where: { $0.id == name }) { return e } }
        return editors.first { isRAW ? $0.handlesRAW : true }
    }
}

/// One "Edit in…" session: working folder, the file handed to the editor, and how to collect the result.
public final class EditSession: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let assetID: String
    public let assetName: String
    public let editor: CompanionEditor
    public let folder: URL
    /// The file opened in the editor.
    public let workFile: URL
    /// The untouched original copy (to detect "nothing changed").
    public let originalCopy: URL
    public let exportFolder: URL
    public let startedAt = Date()
    public var keepEditable: Bool

    init(assetID: String, assetName: String, editor: CompanionEditor, folder: URL, workFile: URL, originalCopy: URL, keepEditable: Bool) {
        self.assetID = assetID; self.assetName = assetName; self.editor = editor
        self.folder = folder; self.workFile = workFile; self.originalCopy = originalCopy
        self.exportFolder = folder.appending(path: "Export")
        self.keepEditable = keepEditable
    }

    /// Prepares the working folder from a downloaded original and opens it in the editor.
    public static func start(assetID: String, assetName: String, original: URL, editor: CompanionEditor,
                             root: URL, keepEditable: Bool) throws -> EditSession {
        let folder = root.appending(path: "\(assetID)-\(Int(Date().timeIntervalSince1970))")
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appending(path: "Export"), withIntermediateDirectories: true)
        let originalCopy = folder.appending(path: ".original-\(original.lastPathComponent)")
        try fm.copyItem(at: original, to: originalCopy)
        var work = folder.appending(path: original.lastPathComponent)
        try fm.copyItem(at: original, to: work)
        if let ext = editor.workingExtension, !RenderEngine.isRAW(original) {
            // Photoshop / PhotoCraft / Krita work on their own document type (layers can be kept).
            let doc = work.deletingPathExtension().appendingPathExtension(ext)
            if ext == "psd" { try Self.writePSD(from: work, to: doc) }
            if FileManager.default.fileExists(atPath: doc.path) { work = doc }
        }
        let session = EditSession(assetID: assetID, assetName: assetName, editor: editor, folder: folder, workFile: work,
                                  originalCopy: originalCopy, keepEditable: keepEditable)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([work], withApplicationAt: editor.appURL, configuration: config) { _, _ in }
        if editor.returns == .watchedExport {
            NSWorkspace.shared.activateFileViewerSelecting([session.exportFolder])
        }
        return session
    }

    /// A flattened PSD the editor can open (ImageIO writes PSD; maximise-compatibility composite included).
    static func writePSD(from source: URL, to destination: URL) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType("com.adobe.photoshop-image")!.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImageFromSource(dest, src, 0, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: Close detection

    /// Whether the editor still shows this photo: its app is running and (with Accessibility access) a window
    /// title mentions the file. Without Accessibility access, only "app quit" or "Done editing" end the session.
    public func isStillOpen() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: editor.appURL)?.bundleIdentifier ?? "")
        guard let app = running.first(where: { !$0.isTerminated }) else { return false }
        guard AXIsProcessTrusted() else { return true }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return true }
        let stem = workFile.deletingPathExtension().lastPathComponent
        for window in windows {
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
               let text = title as? String, text.localizedCaseInsensitiveContains(stem) {
                return true
            }
            var doc: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &doc) == .success,
               let path = doc as? String, path.contains(stem) {
                return true
            }
        }
        return false
    }

    /// Asks for Accessibility access once (used to notice when the photo's window closes).
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Collecting the result

    /// The edited image as a file ImageIO can read, or nil if nothing was saved.
    public func result(darktableCLI: URL? = nil, rawTherapeeCLI: URL? = nil) throws -> URL? {
        let fm = FileManager.default
        switch editor.returns {
        case .watchedExport:
            return latestExport()
        case .darktableCLI:
            let xmp = URL(fileURLWithPath: workFile.path + ".xmp")
            guard fm.fileExists(atPath: xmp.path), let cli = darktableCLI ?? Self.findCLI(in: editor.appURL, names: ["darktable-cli"]) else {
                return try changedFile()
            }
            let out = folder.appending(path: "render.tif")
            try Self.run(cli, [workFile.path, xmp.path, out.path, "--core", "--conf", "plugins/imageio/format/tiff/bpp=16"])
            return fm.fileExists(atPath: out.path) ? out : nil
        case .rawTherapeeCLI:
            let pp3 = URL(fileURLWithPath: workFile.path + ".pp3")
            guard fm.fileExists(atPath: pp3.path), let cli = rawTherapeeCLI ?? Self.findCLI(in: editor.appURL, names: ["rawtherapee-cli"]) else {
                return try changedFile()
            }
            let out = folder.appending(path: "render.tif")
            try Self.run(cli, ["-o", out.path, "-p", pp3.path, "-t", "-b16", "-Y", "-c", workFile.path])
            return fm.fileExists(atPath: out.path) ? out : nil
        case .onClose:
            // An export into the Export folder wins; otherwise the newest changed file in the working folder.
            if let exported = latestExport() { return exported }
            return try changedFile()
        }
    }

    func latestExport() -> URL? {
        let exported = (try? FileManager.default.contentsOfDirectory(at: exportFolder, includingPropertiesForKeys: nil)) ?? []
        return exported.filter { Self.isImage($0) }.max { (Self.modified($0) ?? .distantPast) < (Self.modified($1) ?? .distantPast) }
    }

    /// The newest image in the working folder that differs from the original copy.
    func changedFile() throws -> URL? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files.filter { !$0.lastPathComponent.hasPrefix(".") && Self.isImage($0) }
            .filter { !fm.contentsEqual(atPath: $0.path, andPath: originalCopy.path) }
            .filter { (Self.modified($0) ?? .distantPast) > startedAt.addingTimeInterval(-1) }
        guard let newest = candidates.max(by: { (Self.modified($0) ?? .distantPast) < (Self.modified($1) ?? .distantPast) }) else { return nil }
        // A just-created PSD that was never saved again isn't a result.
        if newest == workFile, newest.pathExtension == "psd", (Self.modified(newest) ?? .distantPast) < startedAt.addingTimeInterval(2) { return nil }
        if newest.pathExtension.lowercased() == "kra" { return try Self.kritaComposite(newest, in: folder) }
        return newest
    }

    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["xmp", "pp3", "afphoto", "xcf", "pxd"].contains(ext) { return false }
        if ext == "kra" { return true }
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) } != nil
    }

    static func modified(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    /// Krita files are zip archives with a flattened `mergedimage.png`.
    static func kritaComposite(_ kra: URL, in folder: URL) throws -> URL? {
        let out = folder.appending(path: "krita-merged")
        try? FileManager.default.removeItem(at: out)
        try run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-o", "-q", kra.path, "mergedimage.png", "-d", out.path])
        let png = out.appending(path: "mergedimage.png")
        return FileManager.default.fileExists(atPath: png.path) ? png : nil
    }

    static func findCLI(in app: URL, names: [String]) -> URL? {
        for name in names {
            for sub in ["Contents/MacOS/\(name)", "Contents/Resources/bin/\(name)", "Contents/MacOS/bin/\(name)"] {
                let url = app.appending(path: sub)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
            for dir in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
                return URL(fileURLWithPath: "\(dir)/\(name)")
            }
        }
        return nil
    }

    static func run(_ tool: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
    }

    /// Project files worth keeping (layers / edit history), moved to Kept Edits when the user asks.
    public func editableFiles() -> [URL] {
        let keep = ["psd", "psb", "kra", "xcf", "afphoto", "pxd", "xmp", "pp3", "tif", "tiff"]
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { keep.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "render.tif" }
    }
}

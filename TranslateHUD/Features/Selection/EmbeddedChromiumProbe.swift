import Foundation

/// Looks for an embedded Chromium, CEF, or Electron runtime inside one app bundle.
///
/// The search starts at `Contents/Frameworks` and stops after a fixed number of
/// directories and a fixed depth. A match is any of:
/// - a file named `icudtl.dat`
/// - a file named `v8_context_snapshot*.bin`
/// - a helper app whose name ends with `Helper (Renderer).app`
///
/// Nested frameworks and nested `.app` bundles under Frameworks are entered, so an
/// engine that only ships as a nested helper is still found. `Contents/MacOS` is not
/// walked. WeChat's article viewer is `WeChatAppEx.app`, its own bundle, and that
/// bundle's Frameworks folder holds the runtime. The main WeChat app keeps the viewer
/// next to its executable; walking MacOS would treat the chat process as the embedder.
///
/// Symbolic links are not followed. The real `Versions/<letter>/Resources` directory
/// is what gets read. `Versions/Current` is usually a link to that directory.
enum EmbeddedChromiumDetector {
    struct Budget: Equatable {
        var maxDirectories: Int
        var maxDepth: Int

        static let standard = Budget(maxDirectories: 48, maxDepth: 8)
    }

    static func containsEngine(in bundleURL: URL, budget: Budget = .standard) -> Bool {
        let root = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return scan(root, budget: budget)
    }

    private static func scan(_ root: URL, budget: Budget) -> Bool {
        var pending: [(url: URL, depth: Int)] = [(root, 0)]
        var visited = 0
        var index = 0
        while index < pending.count {
            if visited >= budget.maxDirectories { return false }
            let current = pending[index]
            index += 1
            visited += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.url.path) else {
                continue
            }
            var children: [(name: String, url: URL)] = []
            for name in names {
                if isSignal(name) { return true }
                if current.depth >= budget.maxDepth { continue }
                let child = current.url.appendingPathComponent(name, isDirectory: false)
                if shouldDescend(name, url: child) {
                    children.append((name, child))
                }
            }
            children.sort { descentPriority($0.name) > descentPriority($1.name) }
            // Visit the likely runtime path before sibling directories that were already
            // queued. Appending would spend the directory cap on helpers and other
            // frameworks before opening Versions/Resources, where icudtl.dat lives.
            let next = children.map { (url: $0.url, depth: current.depth + 1) }
            pending.insert(contentsOf: next, at: index)
        }
        return false
    }

    private static func isSignal(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "icudtl.dat" { return true }
        if lower.hasPrefix("v8_context_snapshot"), lower.hasSuffix(".bin") { return true }
        if lower.hasSuffix("helper (renderer).app") { return true }
        return false
    }

    /// Frameworks and the version/resource directories that hold Chromium's runtime
    /// files are visited before the rest of a wide folder, so the directory cap still
    /// reaches `icudtl.dat` in a normal embedder layout.
    private static func descentPriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.hasSuffix(".framework") { return 4 }
        if lower == "frameworks" { return 3 }
        if lower.hasSuffix(".app"), lower.contains("helper") { return 2 }
        if lower == "versions" || lower == "resources" || lower == "libraries" || lower == "contents" {
            return 1
        }
        return 0
    }

    private static let skippedFileExtensions: Set<String> = [
        "dat", "bin", "pak", "dylib", "so", "plist", "strings", "icns", "png", "jpg",
        "jpeg", "json", "nib", "car", "metallib", "stringsdict", "html", "js", "css",
        "txt", "pdf", "zip", "mo", "qm", "tiff", "gif", "svg", "webp", "mp3", "wav",
        "lproj",
    ]

    private static func mightBeDirectory(_ lowercasedName: String) -> Bool {
        guard let dot = lowercasedName.lastIndex(of: ".") else { return true }
        let ext = String(lowercasedName[lowercasedName.index(after: dot)...])
        if ext == "framework" || ext == "app" || ext == "bundle" { return true }
        return !skippedFileExtensions.contains(ext)
    }

    private static func shouldDescend(_ name: String, url: URL) -> Bool {
        guard mightBeDirectory(name.lowercased()) else { return false }
        if isSymlink(url) { return false }
        return isDirectory(url)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Framework-name listings and embedded-engine scan results, keyed by bundle path.
///
/// The name listing is one directory read and is cached. The file scan runs on a
/// background queue the first time an unclassified bundle misses context. Until that
/// scan finishes, callers leave the host as a normal app and only try
/// `AXManualAccessibility`.
final class BundleEngineCache {
    static let shared = BundleEngineCache()

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let scan: (URL) -> Bool
    private let readFrameworkNames: (URL) -> Set<String>
    private var frameworkNamesByPath: [String: Set<String>] = [:]
    private var embeddedByPath: [String: Bool] = [:]
    private var scanStarted: Set<String> = []

    init(
        queue: DispatchQueue? = nil,
        scan: ((URL) -> Bool)? = nil,
        readFrameworkNames: ((URL) -> Set<String>)? = nil
    ) {
        self.queue = queue ?? DispatchQueue(label: "com.qi.TranslateHUD.bundle-probe", qos: .utility)
        self.scan = scan ?? { EmbeddedChromiumDetector.containsEngine(in: $0) }
        self.readFrameworkNames = readFrameworkNames ?? { BundleEngineCache.frameworkDirectoryNames(in: $0) }
    }

    func frameworkNames(in bundleURL: URL) -> Set<String> {
        let path = Self.key(for: bundleURL)
        lock.lock()
        if let cached = frameworkNamesByPath[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let names = readFrameworkNames(bundleURL)
        lock.lock()
        if let cached = frameworkNamesByPath[path] {
            lock.unlock()
            return cached
        }
        frameworkNamesByPath[path] = names
        lock.unlock()
        return names
    }

    /// `nil` while the scan has not finished. `false` is a finished miss and is not scanned again.
    func embeddedIfKnown(_ bundleURL: URL) -> Bool? {
        let path = Self.key(for: bundleURL)
        lock.lock()
        defer { lock.unlock() }
        return embeddedByPath[path]
    }

    func scheduleScan(of bundleURL: URL) {
        let path = Self.key(for: bundleURL)
        lock.lock()
        let already = embeddedByPath[path] != nil || scanStarted.contains(path)
        if !already {
            scanStarted.insert(path)
        }
        lock.unlock()
        guard !already else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let found = self.scan(bundleURL)
            self.lock.lock()
            self.embeddedByPath[path] = found
            self.lock.unlock()
            let name = bundleURL.lastPathComponent
            if found {
                AppLog.info("选区上下文: \(name) 识别为嵌入式浏览器引擎")
            } else {
                AppLog.info("选区上下文: \(name) 未发现嵌入式浏览器引擎")
            }
        }
    }

    static func frameworkDirectoryNames(in bundleURL: URL) -> Set<String> {
        let directory = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return Set(names)
    }

    private static func key(for bundleURL: URL) -> String {
        bundleURL.standardizedFileURL.path
    }
}

/// Combines the bundle-id / framework-name fast path with the cached scan.
enum ContextHostResolver {
    static func kind(bundleID: String?, bundleURL: URL?, cache: BundleEngineCache) -> ContextHostKind {
        if ContextHostClassifier.isStandaloneBrowser(bundleID: bundleID) {
            return .chromiumBrowser
        }
        let names = bundleURL.map { cache.frameworkNames(in: $0) } ?? []
        let cached = bundleURL.flatMap { cache.embeddedIfKnown($0) }
        let resolved = ContextHostClassifier.kind(
            bundleID: bundleID,
            frameworkNames: names,
            embeddedEngineCached: cached
        )
        if resolved == .other, let bundleURL, cached == nil {
            cache.scheduleScan(of: bundleURL)
        }
        return resolved
    }

    /// True when this bundle is still unclassified and its background scan has
    /// not finished. Callers must not store `nothingWorks` in that window:
    /// the next selection may learn that the process is an embedded engine and
    /// still needs `AXEnhancedUserInterface`.
    static func embeddedScanInFlight(
        bundleID: String?,
        bundleURL: URL?,
        cache: BundleEngineCache
    ) -> Bool {
        guard let bundleURL else { return false }
        if ContextHostClassifier.isStandaloneBrowser(bundleID: bundleID) { return false }
        let names = cache.frameworkNames(in: bundleURL)
        let cached = cache.embeddedIfKnown(bundleURL)
        let kind = ContextHostClassifier.kind(
            bundleID: bundleID,
            frameworkNames: names,
            embeddedEngineCached: cached
        )
        return kind == .other && cached == nil
    }
}

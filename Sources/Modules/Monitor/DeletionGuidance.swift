import Foundation

enum DeletionSafety: Int, Sendable {
    case safe
    case review
    case protected
}

struct DeletionGuidance: Sendable {
    let safety: DeletionSafety
    let message: String?
}

enum DeletionGuide {
    static func guidance(for node: DiskNode) -> DeletionGuidance {
        let path = URL(fileURLWithPath: node.path).standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path

        if isProtected(path) {
            return DeletionGuidance(
                safety: .protected,
                message: "macOS needs this location, so MacDock won't add it to the Collector."
            )
        }

        let safePrefixes = [
            "\(home)/.Trash",
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Developer/Xcode/DerivedData",
        ]
        if safePrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return DeletionGuidance(
                safety: .safe,
                message: "This data is generated automatically and can be rebuilt if needed."
            )
        }

        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let installerExtensions: Set<String> = ["dmg", "pkg", "xip"]
        if path.hasPrefix("\(home)/Downloads/"), installerExtensions.contains(ext) {
            return DeletionGuidance(
                safety: .safe,
                message: installerMessage(path: path)
            )
        }

        if path.hasPrefix("/Applications/") && ext == "app" {
            return DeletionGuidance(
                safety: .review,
                message: "This removes the app, but its settings and support files may remain in your Library."
            )
        }

        if path.hasPrefix("\(home)/Library/Application Support/")
            || path.hasPrefix("\(home)/Library/Containers/")
            || path.hasPrefix("\(home)/Library/Group Containers/") {
            return DeletionGuidance(
                safety: .review,
                message: "This may contain app settings or documents, not only temporary files."
            )
        }

        if path.hasPrefix("\(home)/Documents/")
            || path.hasPrefix("\(home)/Desktop/")
            || path.hasPrefix("\(home)/Pictures/")
            || path.hasPrefix("\(home)/Movies/")
            || path.hasPrefix("\(home)/Music/") {
            return DeletionGuidance(
                safety: .review,
                message: nil
            )
        }

        return DeletionGuidance(
            safety: .review,
            message: nil
        )
    }

    private static func installerMessage(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(
                of: #"(?i)\b(installer|install|setup)\b"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[-_ ]?v?\d+(\.\d+)+.*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = url.deletingPathExtension().lastPathComponent }

        let appURLs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
        for directory in appURLs {
            let apps = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            if let installed = apps.first(where: {
                $0.pathExtension == "app"
                    && $0.deletingPathExtension().lastPathComponent
                        .localizedCaseInsensitiveContains(stem)
            }) {
                return "\(installed.deletingPathExtension().lastPathComponent) is installed. This installer can be removed."
            }
        }
        return "Once the installed app opens from Applications, this installer can be removed."
    }

    private static func isProtected(_ path: String) -> Bool {
        let exact = ["/", "/System", "/Library", "/Users", "/Applications"]
        if exact.contains(path) { return true }
        let prefixes = [
            "/System/",
            "/bin/",
            "/sbin/",
            "/usr/",
            "/private/etc/",
            "/private/var/db/",
            "/private/var/root/",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }
}

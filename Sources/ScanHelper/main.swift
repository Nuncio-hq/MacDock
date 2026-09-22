import Foundation

// MacDockScanHelper — privileged scan backend.
// Usage: MacDockScanHelper <root> <out.json>
// Runs as root (launched via `osascript ... with administrator privileges`),
// scans with the same getattrlistbulk engine, and writes ScanFileResult JSON.
// Live progress goes to <out.json>.progress so the app can poll it.

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("usage: MacDockScanHelper <root> <out>\n".data(using: .utf8)!)
    exit(2)
}
let rootPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let progressPath = outPath + ".progress"

func writeProgress(_ p: ScanProgress) {
    let snap = ScanProgressFile(pid: getpid(), files: p.files,
                                bytes: p.bytes, path: p.currentPath)
    guard let data = try? JSONEncoder().encode(snap) else { return }
    let tmp = progressPath + ".tmp"
    try? data.write(to: URL(fileURLWithPath: tmp))
    try? FileManager.default.moveItem(atPath: tmp, toPath: progressPath)
}

let scanner = DiskScanner(progress: writeProgress)

let root = await scanner.scan(root: rootPath)
let result = ScanFileResult(
    root: root.dto,
    topFiles: scanner.topFiles(limit: 100).map {
        ScanFileDTO(path: $0.path, name: $0.name, size: $0.size)
    })
do {
    let data = try JSONEncoder().encode(result)
    try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

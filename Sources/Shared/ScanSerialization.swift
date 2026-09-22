import Foundation

/// Wire format shared by the app and the privileged MacDockScanHelper:
/// the helper scans as root and writes this JSON; the app decodes it.
struct ScanFileResult: Codable {
    var root: ScanNodeDTO
    var topFiles: [ScanFileDTO]
}

struct ScanNodeDTO: Codable {
    var path: String
    var name: String
    var size: UInt64
    var ownSize: UInt64
    var restricted: Bool
    var children: [ScanNodeDTO]?
}

struct ScanFileDTO: Codable {
    var path: String
    var name: String
    var size: UInt64
}

/// Rewritten periodically by the helper so the app can show live progress
/// (and find the helper's pid) while the privileged scan runs.
struct ScanProgressFile: Codable {
    var pid: Int32
    var files: Int
    var bytes: UInt64
    var path: String
}

extension DiskNode {
    init(dto: ScanNodeDTO) {
        self.init(path: dto.path, name: dto.name, size: dto.size,
                  ownSize: dto.ownSize, isDirectory: true,
                  restricted: dto.restricted,
                  children: dto.children?.map(DiskNode.init(dto:)))
    }

    var dto: ScanNodeDTO {
        ScanNodeDTO(path: path, name: name, size: size, ownSize: ownSize,
                    restricted: restricted, children: children?.map(\.dto))
    }
}

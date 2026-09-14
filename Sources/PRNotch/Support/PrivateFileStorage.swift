import Foundation

enum PrivateFileStorage {
    private static let directoryPermissions = NSNumber(value: 0o700)
    private static let filePermissions = NSNumber(value: 0o600)

    static func write(_ data: Data, to url: URL) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            try fileManager.setAttributes(
                [.posixPermissions: directoryPermissions],
                ofItemAtPath: directory.path
            )
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: filePermissions],
                ofItemAtPath: url.path
            )
        } catch {
            // Cached state is optional; a failed privacy-preserving write must not
            // prevent the app from showing fresh GitHub data in memory.
        }
    }
}

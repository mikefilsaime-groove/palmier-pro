import Foundation

enum ProjectPackageDuplicator {
    @concurrent static func duplicate(_ source: URL) async throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let resolvedSource = source.standardizedFileURL
        guard fileManager.fileExists(atPath: resolvedSource.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let destination = availableDestination(for: resolvedSource, fileManager: fileManager)
        let staging = resolvedSource.deletingLastPathComponent()
            .appendingPathComponent(".creatorstudio-copy-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension(Project.fileExtension)
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(at: resolvedSource, to: staging)
        try Task.checkCancellation()
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    private static func availableDestination(for source: URL, fileManager: FileManager) -> URL {
        let directory = source.deletingLastPathComponent()
        let baseName = source.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            let copySuffix = suffix == 1 ? " Copy" : " Copy \(suffix)"
            let candidate = directory
                .appendingPathComponent(baseName + copySuffix, isDirectory: true)
                .appendingPathExtension(Project.fileExtension)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}

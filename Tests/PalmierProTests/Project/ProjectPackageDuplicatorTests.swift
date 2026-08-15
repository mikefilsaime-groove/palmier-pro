import Foundation
import Testing
@testable import PalmierPro

@Suite("Project package duplication")
struct ProjectPackageDuplicatorTests {
    @Test func duplicatesTheCompletePackageWithoutChangingTheSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-duplicate-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Campaign.palmier", isDirectory: true)
        let media = source.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("timeline".utf8).write(to: source.appendingPathComponent(Project.timelineFilename))
        try Data("media".utf8).write(to: media.appendingPathComponent("clip.mp4"))
        defer { try? FileManager.default.removeItem(at: root) }

        let duplicate = try await ProjectPackageDuplicator.duplicate(source)

        #expect(duplicate.lastPathComponent == "Campaign Copy.palmier")
        #expect(try Data(contentsOf: duplicate.appendingPathComponent(Project.timelineFilename)) == Data("timeline".utf8))
        #expect(try Data(contentsOf: duplicate.appendingPathComponent("media/clip.mp4")) == Data("media".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func choosesTheNextAvailableCopyName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-duplicate-name-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Campaign.palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await ProjectPackageDuplicator.duplicate(source)
        let second = try await ProjectPackageDuplicator.duplicate(source)

        #expect(first.lastPathComponent == "Campaign Copy.palmier")
        #expect(second.lastPathComponent == "Campaign Copy 2.palmier")
    }
}

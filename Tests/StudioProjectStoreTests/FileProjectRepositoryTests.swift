import Foundation
import StudioDomain
@testable import StudioProjectStore
import Testing

@Test func createsListsAndReloadsPortableProject() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-store-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let repository = FileProjectRepository(rootURL: root)
    let created = try await repository.create(title: "Demo", intent: .tutorial)
    let loaded = try await repository.load(id: created.id)
    let listed = try await repository.list()

    #expect(loaded == created)
    #expect(listed.count == 1)
    #expect(listed.first?.id == created.id)
    #expect(
        FileManager.default.fileExists(
            atPath: await repository.packageURL(for: created.id).appendingPathComponent("timeline.json").path
        )
    )
}

@Test func rejectsEmptyProjectTitle() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-store-test-\(UUID().uuidString)", isDirectory: true)
    let repository = FileProjectRepository(rootURL: root)

    await #expect(throws: ProjectStoreError.self) {
        _ = try await repository.create(title: "   ", intent: .social)
    }
}

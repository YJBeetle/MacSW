import Foundation
import XCTest
@testable import MacSWCore

final class SolidWorksDocumentTests: XCTestCase {
    func testNativeTypesAcceptUppercaseSpacesUnicodeAndLiteralURLCharacters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for suffix in ["SLDPRT", "sldasm", "SldDrw"] {
            let file = root.appendingPathComponent("零件 空格 #100% 'a'.\(suffix)")
            try Data("test".utf8).write(to: file)
            XCTAssertEqual(try SolidWorksDocument.validatedURL(file), file.resolvingSymlinksInPath())
        }
        XCTAssertThrowsError(try SolidWorksDocument.validatedURL(URL(string: "https://example.com/model.sldprt")!))
        XCTAssertThrowsError(try SolidWorksDocument.validatedURL(root.appendingPathComponent("missing.sldprt")))
        let folder = root.appendingPathComponent("folder.sldasm")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SolidWorksDocument.validatedURL(folder))
        let unsupported = root.appendingPathComponent("file.step")
        try Data().write(to: unsupported)
        XCTAssertThrowsError(try SolidWorksDocument.validatedURL(unsupported))
    }
}

@MainActor
final class DocumentOpenQueueTests: XCTestCase {
    func testColdLaunchQueuesUntilReadyCoalescesAndPreservesOrder() async {
        let first = URL(fileURLWithPath: "/models/one.sldprt")
        let second = URL(fileURLWithPath: "/models/two.sldasm")
        var opened: [URL] = []
        let queue = DocumentOpenQueue(open: { opened.append($0) }, report: { _, _ in XCTFail() })
        queue.enqueue([first, second, first])
        XCTAssertTrue(opened.isEmpty)
        queue.start()
        await queue.waitForPending()
        XCTAssertEqual(opened, [first, second])
        queue.enqueue([first])
        await queue.waitForPending()
        XCTAssertEqual(opened, [first, second, first])
    }

    func testNewEventDuringOpenIsSerializedAndFailureDoesNotDiscardNextFile() async {
        let first = URL(fileURLWithPath: "/models/broken.sldprt")
        let second = URL(fileURLWithPath: "/models/two.slddrw")
        var opened: [URL] = []
        var failed: [URL] = []
        var resume: CheckedContinuation<Void, Never>?
        let queue = DocumentOpenQueue(open: { file in
            opened.append(file)
            if file == first {
                await withCheckedContinuation { resume = $0 }
                throw SolidWorksDocument.failure("open failed")
            }
        }, report: { file, _ in failed.append(file) })
        queue.start()
        queue.enqueue([first])
        for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        XCTAssertNotNil(resume)
        queue.enqueue([first, second])
        XCTAssertEqual(opened, [first])
        resume?.resume()
        await queue.waitForPending()
        XCTAssertEqual(opened, [first, second])
        XCTAssertEqual(failed, [first])
    }
}

@MainActor
final class RuntimeDocumentOpeningTests: XCTestCase {
    private actor Calls {
        var files: [URL] = []
        func record(_ file: URL) { files.append(file) }
    }

    private func fixture() throws -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-open-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(appSupportDirectory: root)
        let executable = paths.bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        let file = root.appendingPathComponent("零件 with spaces.SLDPRT")
        try Data("fixture".utf8).write(to: file)
        return (paths, file)
    }

    func testExistingHostIsReusedWithoutLaunchingAnotherProcess() async throws {
        let (paths, file) = try fixture()
        let calls = Calls()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [WineProcess(name: "sldworks.exe", pid: 42, residentKB: 10, elapsed: "00:05")] },
            documentOpener: { url, prefix in
                XCTAssertEqual(prefix, paths.bottle)
                await calls.record(url)
            })
        try await store.openDocument(file)
        let files = await calls.files
        XCTAssertEqual(files, [file.resolvingSymlinksInPath()])
        XCTAssertEqual(store.state, .running)
        XCTAssertFalse(store.isOpeningDocument)
        XCTAssertTrue(store.statusMessage.contains("已在 SOLIDWORKS 中打开"))
    }

    func testMissingInstallationNeverCreatesBottleOrCallsBridge() async throws {
        let (installed, file) = try fixture()
        let paths = AppPaths(appSupportDirectory: installed.appSupportDirectory.appendingPathComponent("missing"))
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in XCTFail() }, swcliPreparation: { _ in XCTFail() },
            documentOpener: { _, _ in XCTFail() })
        do { try await store.openDocument(file); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("请先完成")) }
        XCTAssertFalse(paths.bottleExists)
    }

    func testBottleDeletionSuspensionBlocksOpenWithoutCallingBridge() async throws {
        let (paths, file) = try fixture()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in XCTFail() }, swcliPreparation: { _ in XCTFail() },
            documentOpener: { _, _ in XCTFail() })
        await store.suspendFontPreparationForBottleDeletion()
        do { try await store.openDocument(file); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("维护")) }
        XCTAssertFalse(store.isOpeningDocument)
    }

    func testFailedOpenClearsBusyStateAndCanBeRetried() async throws {
        let (paths, file) = try fixture()
        let calls = Calls()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [WineProcess(name: "sldworks.exe", pid: 42, residentKB: 10, elapsed: "00:05")] },
            documentOpener: { url, _ in
                await calls.record(url)
                if await calls.files.count == 1 { throw SolidWorksDocument.failure("native open failed") }
            })
        do { try await store.openDocument(file); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("native open failed")) }
        XCTAssertFalse(store.isOpeningDocument)
        try await store.openDocument(file)
        let count = await calls.files.count
        XCTAssertEqual(count, 2)
    }

    func testOpeningBlocksDuplicateRequestsAndContainerShutdown() async throws {
        let (paths, file) = try fixture()
        let entered = expectation(description: "bridge entered")
        let gate = OpeningGate()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [WineProcess(name: "sldworks.exe", pid: 42, residentKB: 10, elapsed: "00:05")] },
            documentOpener: { _, _ in entered.fulfill(); await gate.wait() })
        let opening = Task { try await store.openDocument(file) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(store.isOpeningDocument)
        do { try await store.openDocument(file); XCTFail("duplicate bridge") }
        catch { XCTAssertTrue(error.localizedDescription.contains("维护")) }
        do { try await store.stopContainerForAppQuit(); XCTFail("must not stop the host") }
        catch { XCTAssertTrue(error.localizedDescription.contains("正在打开文件")) }
        await gate.release()
        try await opening.value
        XCTAssertFalse(store.isOpeningDocument)
    }

    private actor OpeningGate {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}

import XCTest
import Foundation
import Darwin
import PortmonCore
@testable import PortmonApp

private actor ProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls = 0

    func run(_ port: Int) async -> HealthReport {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation = $0 }
            return HealthReport(state: .hung)
        }
        return HealthReport(state: .healthy)
    }

    func started() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func count() -> Int { calls }
}

@MainActor
final class HealthProbeServiceTests: XCTestCase {
    func testInvalidationWhileProbeIsRunningDoesNotRestoreStaleCache() async {
        let gate = ProbeGate()
        let probe = HealthProbe(ttl: 60, probe: { await gate.run($0) })
        let first = Task { await probe.probe(ports: [3000]) }
        for _ in 0..<1000 {
            if await gate.started() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let started = await gate.started()
        XCTAssertTrue(started)
        guard started else { first.cancel(); return }
        await probe.invalidate(port: 3000)
        await gate.release()
        _ = await first.value
        let current = await probe.probe(ports: [3000])
        XCTAssertEqual(current[3000]?.state, .healthy)
        let calls = await gate.count()
        XCTAssertEqual(calls, 2)
    }
}

@MainActor
final class TunnelServiceTests: XCTestCase {
    func testStartAndStopWithLocalFixture() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("cloudflared")
        try "#!/bin/sh\necho 'https://fixture-test.trycloudflare.com'\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let service = TunnelService(executablePath: script.path, recordsOwnership: false)
        let url = try await service.start(port: 12345, timeout: 3)
        XCTAssertEqual(url, "https://fixture-test.trycloudflare.com")
        await service.stop(port: 12345)
        let stopped = await service.url(for: 12345)
        XCTAssertNil(stopped)
    }

    func testOldTimeoutDoesNotCancelReplacement() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("cloudflared")
        func writeScript(_ text: String) throws {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        try writeScript("#!/bin/sh\necho 'https://first-test.trycloudflare.com'\nexec /bin/sleep 60\n")
        let service = TunnelService(executablePath: script.path, recordsOwnership: false)
        _ = try await service.start(port: 12347, timeout: 1.5)
        await service.stop(port: 12347)
        try writeScript("#!/bin/sh\n/bin/sleep 2\necho 'https://second-test.trycloudflare.com'\nexec /bin/sleep 60\n")
        do {
            let url = try await service.start(port: 12347, timeout: 5)
            XCTAssertEqual(url, "https://second-test.trycloudflare.com")
            await service.stop(port: 12347)
        } catch {
            await service.stop(port: 12347)
            throw error
        }
    }

    func testReportsCloudflaredFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("cloudflared")
        try "#!/bin/sh\necho 'failed to start fixture'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let service = TunnelService(executablePath: script.path, recordsOwnership: false)
        do {
            _ = try await service.start(port: 12346, timeout: 3)
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("failed to start fixture"))
        }
        await service.stop(port: 12346)
    }
}

@MainActor
final class TunnelOwnershipTests: XCTestCase {
    func testCleanupOnlySignalsMatchingTunnelOfGoneOwner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let owner = try XCTUnwrap(TunnelOwnership.identity(getpid()))
        let tunnel = try XCTUnwrap(TunnelOwnership.identity(process.processIdentifier))
        let file = dir.appendingPathComponent("record.json")
        func write(_ record: TunnelOwnership.Record) throws {
            try JSONEncoder().encode(record).write(to: file)
        }
        try write(.init(owner: owner, tunnel: tunnel))
        TunnelOwnership.cleanOrphans(in: dir)
        XCTAssertTrue(process.isRunning)
        let goneOwner = TunnelOwnership.Identity(pid: owner.pid, seconds: owner.seconds, microseconds: owner.microseconds &+ 1)
        let otherTunnel = TunnelOwnership.Identity(pid: tunnel.pid, seconds: tunnel.seconds, microseconds: tunnel.microseconds &+ 1)
        try write(.init(owner: goneOwner, tunnel: otherTunnel))
        TunnelOwnership.cleanOrphans(in: dir)
        XCTAssertTrue(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try write(.init(owner: goneOwner, tunnel: tunnel))
        TunnelOwnership.cleanOrphans(in: dir)
        for _ in 0..<100 where process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning {
            XCTAssertEqual(process.terminationReason, .uncaughtSignal)
            XCTAssertEqual(process.terminationStatus, SIGTERM)
        }
    }
}

private final class ScanRace: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let releaseFirst = DispatchSemaphore(value: 0)

    func hasStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }

    func scan() -> [ServerEntry] {
        lock.lock()
        count += 1
        let invocation = count
        lock.unlock()
        if invocation == 1 {
            _ = releaseFirst.wait(timeout: .now() + 5)
        }
        return [ServerEntry(port: invocation == 1 ? 1111 : 2222, pids: [], command: "launchd", user: "test", addresses: ["127.0.0.1"])]
    }
}

@MainActor
final class RefreshOrderingTests: XCTestCase {
    func testCancelledSlowScanCannotOverwriteNewerRefresh() async throws {
        let race = ScanRace()
        let store = ServerStore(scan: { race.scan() }, useSnapshots: false, observeSystem: false)
        defer { race.releaseFirst.signal() }
        store.refresh()
        var started = false
        for _ in 0..<2000 {
            if race.hasStarted() { started = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(started)
        guard started else { return }
        store.refresh(force: true)
        for _ in 0..<2000 {
            if store.entries.first?.port == 2222 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(store.entries.first?.port, 2222)
        race.releaseFirst.signal()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.entries.first?.port, 2222)
    }
}

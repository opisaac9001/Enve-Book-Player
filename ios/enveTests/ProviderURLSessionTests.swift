import Foundation
import Testing
import os

@testable import enve

@Suite(.timeLimit(.minutes(1)))
nonisolated struct ProviderURLSessionTests {
    @Test(arguments: Transfer.allCases)
    func completedRequestsReturnTheirBody(_ transfer: Transfer) async throws {
        let fixture = Fixture(completes: true)
        defer { fixture.close() }
        #expect(try await fixture.send(transfer) == Fixture.body)
    }

    @Test(arguments: Transfer.allCases)
    func retiredSessionsRejectNewRequestsWithoutStartingTransport(_ transfer: Transfer) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.invalidateAndCancel()
        do {
            _ = try await fixture.send(transfer)
            Issue.record("Retired session accepted a request")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(fixture.control.started == 0)
    }

    @Test(arguments: Transfer.allCases)
    func retirementCancelsConcurrentRequestsAndRejectsLaterOnes(_ transfer: Transfer) async throws {
        for _ in 0..<4 {
            let fixture = Fixture()
            defer { fixture.close() }
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<24 {
                    group.addTask {
                        do {
                            _ = try await fixture.send(transfer)
                            return false
                        } catch {
                            return Self.isCancellation(error)
                        }
                    }
                }
                try await waitUntil { fixture.control.started > 0 }
                fixture.transport.invalidateAndCancel()
                for _ in 0..<8 {
                    group.addTask {
                        do {
                            _ = try await fixture.send(transfer)
                            return false
                        } catch {
                            return error is CancellationError
                        }
                    }
                }
                for try await cancelled in group { #expect(cancelled) }
            }
            try await waitUntil { fixture.control.stopped == fixture.control.started }
        }
    }

    @Test(arguments: Transfer.allCases)
    func cancellingTheCallerStopsItsTransport(_ transfer: Transfer) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let operation = Task { try await fixture.send(transfer) }
        try await waitUntil { fixture.control.started == 1 }
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Cancelled request succeeded")
        } catch {
            #expect(Self.isCancellation(error))
        }
        try await waitUntil { fixture.control.stopped == 1 }
    }

    @Test func aRetiredProgressDownloadResumesItsDelegateWithCancellation() async throws {
        let delegate = URLSessionDownloadProgressDelegate(progressHandler: { _ in })
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let transport = ProviderURLSession(session)
        transport.invalidateAndCancel()
        let request = URLRequest(url: URL(string: "https://fixture.invalid/book")!)
        do {
            _ = try await delegate.awaitResult { try transport.downloadTask(with: request) }
            Issue.record("Retired session accepted a progress download")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test(arguments: DownloadEnding.allCases)
    func progressDownloadsCompleteOrCancelWithoutLosingTheirContinuation(_ ending: DownloadEnding) async throws {
        let delegate = URLSessionDownloadProgressDelegate(progressHandler: { _ in })
        let fixture = Fixture(completes: ending == .completed, delegate: delegate)
        defer { fixture.close() }
        let operation = Task {
            try await delegate.awaitResult { try fixture.transport.downloadTask(with: fixture.request) }
        }
        try await waitUntil { fixture.control.started == 1 }
        switch ending {
        case .completed:
            let (file, response) = try await operation.value
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(response.statusCode == 200)
            #expect(try Data(contentsOf: file) == Fixture.body)
        case .callerCancelled, .sessionRetired:
            if ending == .callerCancelled { operation.cancel() } else { fixture.transport.invalidateAndCancel() }
            do {
                _ = try await operation.value
                Issue.record("Cancelled progress download succeeded")
            } catch {
                #expect(Self.isCancellation(error))
            }
            try await waitUntil { fixture.control.stopped == 1 }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Transport lifecycle did not settle")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    enum Transfer: CaseIterable, Sendable { case data, download }
    enum DownloadEnding: CaseIterable, Sendable { case completed, callerCancelled, sessionRetired }

    nonisolated final class Fixture: Sendable {
        static let body = Data("provider transport fixture".utf8)
        let control: Control
        let transport: ProviderURLSession
        let request: URLRequest
        private let identifier: String

        init(completes: Bool = false, delegate: (any URLSessionDelegate)? = nil) {
            let identifier = UUID().uuidString
            let control = Control(completes: completes)
            self.identifier = identifier
            self.control = control
            ControlledProtocol.controls.withLock { $0[identifier] = control }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ControlledProtocol.self]
            transport = ProviderURLSession(URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil))
            var request = URLRequest(url: URL(string: "https://fixture.invalid/book")!)
            request.setValue(identifier, forHTTPHeaderField: "X-Fixture-ID")
            self.request = request
        }

        func send(_ transfer: Transfer) async throws -> Data {
            switch transfer {
            case .data:
                return try await transport.data(for: request).0
            case .download:
                let (file, _) = try await transport.download(for: request)
                defer { try? FileManager.default.removeItem(at: file) }
                return try Data(contentsOf: file)
            }
        }

        func close() {
            transport.invalidateAndCancel()
            _ = ControlledProtocol.controls.withLock { $0.removeValue(forKey: identifier) }
        }
    }

    nonisolated final class Control: Sendable {
        let completes: Bool
        let counts = OSAllocatedUnfairLock(initialState: (started: 0, stopped: 0))
        var started: Int { counts.withLock { $0.started } }
        var stopped: Int { counts.withLock { $0.stopped } }
        init(completes: Bool) { self.completes = completes }
    }

    nonisolated final class ControlledProtocol: URLProtocol, @unchecked Sendable {
        static let controls = OSAllocatedUnfairLock(initialState: [String: Control]())
        private let active = OSAllocatedUnfairLock<Control?>(initialState: nil)

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let control = Self.controls.withLock { $0[request.value(forHTTPHeaderField: "X-Fixture-ID") ?? ""] }
            guard let control else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            active.withLock { $0 = control }
            control.counts.withLock { $0.started += 1 }
            guard control.completes else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(Fixture.body.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Fixture.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            let control = active.withLock { state in
                defer { state = nil }
                return state
            }
            control?.counts.withLock { $0.stopped += 1 }
        }
    }
}

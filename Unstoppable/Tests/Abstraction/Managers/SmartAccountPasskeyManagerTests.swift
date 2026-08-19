import AuthenticationServices
import Foundation
import Testing
@testable import Unstoppable
@testable import WalletCore

struct SmartAccountPasskeyManagerTests {
    @Test func registerRejectsReentryWhileInFlight() async throws {
        let requester = FakeRequester()
        let manager = SmartAccountPasskeyManager(requester: requester)

        let firstTask = Task { try? await manager.register(name: "first") }
        await requester.waitForInvocations(1)

        await #expect(throws: SmartAccountPasskeyManager.AAError.busy) {
            try await manager.register(name: "second")
        }
        #expect(requester.invocations == 1)

        requester.finishPendingRequest()
        _ = await firstTask.value
    }

    @Test func assertForSigningRejectsReentryWhileInFlight() async throws {
        let requester = FakeRequester()
        let manager = SmartAccountPasskeyManager(requester: requester)

        let firstTask = Task { try? await manager.register(name: "first") }
        await requester.waitForInvocations(1)

        await #expect(throws: SmartAccountPasskeyManager.AAError.busy) {
            try await manager.assertForSigning(
                credentialID: Data([0xCC]),
                challenge: Data(repeating: 0x01, count: 32)
            )
        }
        #expect(requester.invocations == 1)

        requester.finishPendingRequest()
        _ = await firstTask.value
    }
}

private final class FakeRequester: PasskeyAuthorizationRequesting, @unchecked Sendable {
    private struct InvocationWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct PendingRequest {
        let requests: [ASAuthorizationRequest]
        let delegate: ASAuthorizationControllerDelegate
    }

    private enum FakeError: Error {
        case finished
    }

    private let lock = NSLock()
    private var invocationCount = 0
    private var invocationWaiters = [InvocationWaiter]()
    private var pendingRequest: PendingRequest?

    var invocations: Int {
        lock.withLock { invocationCount }
    }

    func waitForInvocations(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard invocationCount < count else { return true }

                invocationWaiters.append(InvocationWaiter(count: count, continuation: continuation))
                return false
            }

            if shouldResume {
                continuation.resume()
            }
        }
    }

    func perform(
        requests: [ASAuthorizationRequest],
        delegate: ASAuthorizationControllerDelegate,
        contextProvider _: ASAuthorizationControllerPresentationContextProviding
    ) {
        let readyContinuations = lock.withLock {
            invocationCount += 1
            pendingRequest = PendingRequest(requests: requests, delegate: delegate)

            let currentCount = invocationCount
            var ready = [CheckedContinuation<Void, Never>]()
            var remaining = [InvocationWaiter]()

            for waiter in invocationWaiters {
                if waiter.count <= currentCount {
                    ready.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            invocationWaiters = remaining

            return ready
        }

        for continuation in readyContinuations {
            continuation.resume()
        }
    }

    func finishPendingRequest() {
        let request = lock.withLock {
            defer { pendingRequest = nil }
            return pendingRequest
        }
        guard let request else { return }

        let controller = ASAuthorizationController(authorizationRequests: request.requests)
        request.delegate.authorizationController?(
            controller: controller,
            didCompleteWithError: FakeError.finished
        )
    }
}

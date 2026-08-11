import XCTest
@testable import CribWireKit

final class CameraPairingStateMachineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_754_850_000)
    private let pairingA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let pairingB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let sas = SASCode(digits: "358946")

    // MARK: - Happy path

    func testFullFlowFromStartToActive() {
        var machine = CameraPairingStateMachine()

        XCTAssertEqual(machine.apply(.start), [.generateAndRegisterPairing])
        XCTAssertEqual(machine.state, .generating)

        XCTAssertEqual(machine.apply(.registered(pairingID: pairingA, at: t0)), [])
        guard case .displaying(let display) = machine.state else {
            return XCTFail("expected .displaying, got \(machine.state)")
        }
        XCTAssertEqual(display.current?.pairingID, pairingA)
        XCTAssertEqual(
            display.regeneratesAt,
            t0.addingTimeInterval(PairingTiming.qrRegenerationInterval)
        )
        XCTAssertEqual(display.current?.expiresAt, t0.addingTimeInterval(PairingTiming.pairingTTL))

        let claimEffects = machine.apply(
            .viewerClaimed(pairingID: pairingA, viewerDeviceID: "viewer-1", sasCode: sas)
        )
        XCTAssertEqual(claimEffects, [.stopDisplayingQRCode])
        XCTAssertEqual(
            machine.state,
            .claimed(
                .init(pairingID: pairingA, viewerDeviceID: "viewer-1", sasCode: sas)
            )
        )

        XCTAssertEqual(
            machine.apply(.viewerConfirmed),
            [.persistPairing(pairingID: pairingA, viewerDeviceID: "viewer-1")]
        )
        XCTAssertEqual(machine.state, .active(.init(pairingID: pairingA, viewerDeviceID: "viewer-1")))
    }

    // MARK: - Rotation

    func testRegeneratesQRAfterTwoMinutes() {
        var machine = displayingMachine()

        // One second early: nothing happens.
        XCTAssertEqual(machine.apply(.tick(now: t0.addingTimeInterval(119))), [])
        // On the deadline: ask for a fresh secret.
        XCTAssertEqual(
            machine.apply(.tick(now: t0.addingTimeInterval(120))),
            [.generateAndRegisterPairing]
        )
    }

    func testRepeatedTicksDoNotQueueMultipleRegistrations() {
        var machine = displayingMachine()

        XCTAssertEqual(
            machine.apply(.tick(now: t0.addingTimeInterval(120))),
            [.generateAndRegisterPairing]
        )
        // Registration is in flight; further ticks before the next interval must
        // not fire again.
        XCTAssertEqual(machine.apply(.tick(now: t0.addingTimeInterval(121))), [])
        XCTAssertEqual(machine.apply(.tick(now: t0.addingTimeInterval(200))), [])
    }

    func testRotationKeepsThePreviousCodeClaimable() {
        var machine = displayingMachine()
        _ = machine.apply(.tick(now: t0.addingTimeInterval(120)))
        _ = machine.apply(.registered(pairingID: pairingB, at: t0.addingTimeInterval(120)))

        guard case .displaying(let display) = machine.state else {
            return XCTFail("expected .displaying")
        }
        XCTAssertEqual(display.candidates.map(\.pairingID), [pairingA, pairingB])
        XCTAssertEqual(display.current?.pairingID, pairingB)

        // A viewer that scanned the *old* code a moment before the rotation must
        // still be able to claim it.
        let effects = machine.apply(
            .viewerClaimed(pairingID: pairingA, viewerDeviceID: "viewer-1", sasCode: sas)
        )
        XCTAssertEqual(effects, [.stopDisplayingQRCode, .discardCandidates([pairingB])])
        guard case .claimed(let claimed) = machine.state else {
            return XCTFail("expected .claimed")
        }
        XCTAssertEqual(claimed.pairingID, pairingA)
    }

    func testClaimForAnUnknownPairingIsIgnored() {
        var machine = displayingMachine()
        let effects = machine.apply(
            .viewerClaimed(pairingID: UUID(), viewerDeviceID: "attacker", sasCode: sas)
        )
        XCTAssertEqual(effects, [])
        guard case .displaying = machine.state else {
            return XCTFail("state must not change on an unknown pairing ID")
        }
    }

    // MARK: - Expiry

    func testExpiresAfterTheTenMinuteTTL() {
        // Regeneration pushed beyond the TTL so this test isolates expiry.
        var machine = CameraPairingStateMachine(
            state: .displaying(
                .init(
                    candidates: [PairingCandidate(pairingID: pairingA, createdAt: t0)],
                    regeneratesAt: t0.addingTimeInterval(700)
                )
            )
        )

        XCTAssertEqual(machine.apply(.tick(now: t0.addingTimeInterval(599))), [])

        let effects = machine.apply(.tick(now: t0.addingTimeInterval(600)))
        XCTAssertEqual(effects, [.discardCandidates([pairingA]), .stopDisplayingQRCode])
        XCTAssertEqual(machine.state, .failed(.expired))
    }

    func testOnlyExpiredCandidatesAreDiscarded() {
        var machine = displayingMachine()
        // A later rotation: B is registered at t0+500, so its own regeneration
        // deadline (t0+620) is still ahead at the moment A's TTL runs out.
        _ = machine.apply(.registered(pairingID: pairingB, at: t0.addingTimeInterval(500)))

        // At t0+600 the first candidate is dead but the second lives until t0+1100.
        let effects = machine.apply(.tick(now: t0.addingTimeInterval(600)))
        XCTAssertEqual(effects, [.discardCandidates([pairingA])])
        guard case .displaying(let display) = machine.state else {
            return XCTFail("expected .displaying")
        }
        XCTAssertEqual(display.candidates.map(\.pairingID), [pairingB])
    }

    func testExpiredMachineCanBeRestarted() {
        var machine = CameraPairingStateMachine(
            state: .displaying(
                .init(
                    candidates: [PairingCandidate(pairingID: pairingA, createdAt: t0)],
                    regeneratesAt: t0.addingTimeInterval(700)
                )
            )
        )
        _ = machine.apply(.tick(now: t0.addingTimeInterval(600)))
        XCTAssertEqual(machine.state, .failed(.expired))

        XCTAssertEqual(machine.apply(.start), [.generateAndRegisterPairing])
        XCTAssertEqual(machine.state, .generating)
    }

    // MARK: - Failures

    func testRegistrationFailureIsTerminalAndCarriesASafeMessage() {
        var machine = CameraPairingStateMachine()
        _ = machine.apply(.start)

        XCTAssertEqual(
            machine.apply(.registrationFailed(message: "offline")),
            [.stopDisplayingQRCode]
        )
        XCTAssertEqual(machine.state, .failed(.backend(message: "offline")))
    }

    func testCancelFromEveryNonTerminalState() {
        for state in [
            CameraPairingStateMachine.State.generating,
            .displaying(
                .init(
                    candidates: [PairingCandidate(pairingID: pairingA, createdAt: t0)],
                    regeneratesAt: t0.addingTimeInterval(120)
                )
            ),
            .claimed(.init(pairingID: pairingA, viewerDeviceID: "v", sasCode: sas))
        ] {
            var machine = CameraPairingStateMachine(state: state)
            XCTAssertEqual(machine.apply(.cancel), [.stopDisplayingQRCode])
            XCTAssertEqual(machine.state, .failed(.cancelled))
        }
    }

    func testActivePairingIgnoresFurtherEvents() {
        var machine = CameraPairingStateMachine(
            state: .active(.init(pairingID: pairingA, viewerDeviceID: "v"))
        )
        XCTAssertEqual(machine.apply(.tick(now: t0.addingTimeInterval(10_000))), [])
        XCTAssertEqual(machine.apply(.cancel), [])
        XCTAssertEqual(machine.state, .active(.init(pairingID: pairingA, viewerDeviceID: "v")))
    }

    func testConfirmationBeforeAClaimIsIgnored() {
        var machine = displayingMachine()
        XCTAssertEqual(machine.apply(.viewerConfirmed), [])
        guard case .displaying = machine.state else {
            return XCTFail("must stay in .displaying")
        }
    }

    // MARK: - Helper

    private func displayingMachine() -> CameraPairingStateMachine {
        var machine = CameraPairingStateMachine()
        _ = machine.apply(.start)
        _ = machine.apply(.registered(pairingID: pairingA, at: t0))
        return machine
    }
}

final class ViewerPairingStateMachineTests: XCTestCase {

    private let pairingID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let apiURL = URL(string: "https://api.cribwire.example")!
    private let sas = SASCode(digits: "358946")

    func testFullFlowFromScanToActive() {
        var machine = ViewerPairingStateMachine()

        XCTAssertEqual(machine.apply(.startScanning), [])
        XCTAssertEqual(machine.state, .scanning)

        XCTAssertEqual(
            machine.apply(.scanned(pairingID: pairingID, apiBaseURL: apiURL)),
            [.stopScanning, .claimPairing(pairingID: pairingID, apiBaseURL: apiURL)]
        )
        XCTAssertEqual(machine.state, .claiming(.init(pairingID: pairingID, apiBaseURL: apiURL)))

        XCTAssertEqual(machine.apply(.claimSucceeded(sasCode: sas)), [])
        XCTAssertEqual(
            machine.state,
            .confirmingSAS(.init(pairingID: pairingID, apiBaseURL: apiURL, sasCode: sas))
        )

        // Nothing is persisted until a human has compared the two codes.
        XCTAssertEqual(
            machine.apply(.userConfirmedSAS),
            [.persistPairing(pairingID: pairingID)]
        )
        XCTAssertEqual(machine.state, .active(.init(pairingID: pairingID)))
    }

    func testUnrelatedQRCodesDoNotLeaveTheScanner() {
        var machine = ViewerPairingStateMachine()
        _ = machine.apply(.startScanning)

        XCTAssertEqual(machine.apply(.scanRejected(.notAPairingURL)), [])
        XCTAssertEqual(machine.state, .scanning)

        XCTAssertEqual(machine.apply(.scanRejected(.unsupportedVersion("2"))), [])
        XCTAssertEqual(machine.state, .scanning)

        // …and a good code afterwards still works.
        XCTAssertEqual(
            machine.apply(.scanned(pairingID: pairingID, apiBaseURL: apiURL)),
            [.stopScanning, .claimPairing(pairingID: pairingID, apiBaseURL: apiURL)]
        )
    }

    func testSASMismatchIsTerminalAndDiscardsTheSecret() {
        var machine = confirmingMachine()

        XCTAssertEqual(machine.apply(.userRejectedSAS), [.discardScannedSecret])
        XCTAssertEqual(machine.state, .failed(.sasMismatch))
    }

    func testClaimFailureDiscardsTheSecret() {
        var machine = ViewerPairingStateMachine()
        _ = machine.apply(.startScanning)
        _ = machine.apply(.scanned(pairingID: pairingID, apiBaseURL: apiURL))

        XCTAssertEqual(
            machine.apply(.claimFailed(.viewerLimitReached)),
            [.discardScannedSecret]
        )
        XCTAssertEqual(machine.state, .failed(.viewerLimitReached))
    }

    func testExpiredPairingSurfacesAsAFailure() {
        var machine = ViewerPairingStateMachine()
        _ = machine.apply(.startScanning)
        _ = machine.apply(.scanned(pairingID: pairingID, apiBaseURL: apiURL))

        XCTAssertEqual(machine.apply(.claimFailed(.expired)), [.discardScannedSecret])
        XCTAssertEqual(machine.state, .failed(.expired))
    }

    func testCancelDiscardsTheSecretFromEveryState() {
        var scanning = ViewerPairingStateMachine()
        _ = scanning.apply(.startScanning)
        XCTAssertEqual(scanning.apply(.cancel), [.stopScanning, .discardScannedSecret])
        XCTAssertEqual(scanning.state, .failed(.cancelled))

        var confirming = confirmingMachine()
        XCTAssertEqual(confirming.apply(.cancel), [.discardScannedSecret])
        XCTAssertEqual(confirming.state, .failed(.cancelled))
    }

    func testFailedMachineCanRescan() {
        var machine = confirmingMachine()
        _ = machine.apply(.userRejectedSAS)

        XCTAssertEqual(machine.apply(.startScanning), [])
        XCTAssertEqual(machine.state, .scanning)
    }

    func testActiveStateIgnoresFurtherEvents() {
        var machine = ViewerPairingStateMachine(state: .active(.init(pairingID: pairingID)))
        XCTAssertEqual(machine.apply(.cancel), [])
        XCTAssertEqual(machine.apply(.userRejectedSAS), [])
        XCTAssertEqual(machine.state, .active(.init(pairingID: pairingID)))
    }

    func testScanIsIgnoredWhileAlreadyClaiming() {
        var machine = ViewerPairingStateMachine()
        _ = machine.apply(.startScanning)
        _ = machine.apply(.scanned(pairingID: pairingID, apiBaseURL: apiURL))

        let other = UUID()
        XCTAssertEqual(machine.apply(.scanned(pairingID: other, apiBaseURL: apiURL)), [])
        XCTAssertEqual(machine.state, .claiming(.init(pairingID: pairingID, apiBaseURL: apiURL)))
    }

    private func confirmingMachine() -> ViewerPairingStateMachine {
        var machine = ViewerPairingStateMachine()
        _ = machine.apply(.startScanning)
        _ = machine.apply(.scanned(pairingID: pairingID, apiBaseURL: apiURL))
        _ = machine.apply(.claimSucceeded(sasCode: sas))
        return machine
    }
}

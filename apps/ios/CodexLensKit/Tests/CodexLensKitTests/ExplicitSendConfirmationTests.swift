import XCTest
@testable import CodexLensKit

final class ExplicitSendConfirmationTests: XCTestCase {
    func testAcceptsOnlyConsequenceSpecificTextConfirmation() {
        XCTAssertTrue(ExplicitSendConfirmation.accepts("Confirm text."))
        XCTAssertTrue(ExplicitSendConfirmation.accepts("  CONFIRM   TEXT  "))
    }

    func testRejectsGenericOrdinaryOrEmbeddedAgreement() {
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Yes"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Okay"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Send it"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Yes, send it"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Please confirm text"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("He said send it yesterday"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Do not send it"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Confirm text tomorrow"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Confirm text to Alex"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Confirm text and send it"))
        XCTAssertFalse(ExplicitSendConfirmation.accepts("Confirmed text"))
    }

    func testAuthorizationRequiresCompletedLaterReadback() {
        let preparedAt = Date(timeIntervalSince1970: 1_000)
        var authorization = TextConfirmationAuthorization(
            preparedAt: preparedAt,
            expiresAt: preparedAt.addingTimeInterval(300)
        )

        XCTAssertEqual(
            authorization.decision(
                transcript: "Confirm text",
                transcribedAt: preparedAt.addingTimeInterval(1),
                now: preparedAt.addingTimeInterval(1)
            ),
            .invalidate
        )

        authorization.noteReadbackCompleted(at: preparedAt.addingTimeInterval(2))
        XCTAssertEqual(
            authorization.decision(
                transcript: "Confirm text",
                transcribedAt: preparedAt.addingTimeInterval(3),
                now: preparedAt.addingTimeInterval(3)
            ),
            .authorize
        )
    }

    func testAuthorizationInvalidatesInterveningOrExpiredSpeech() {
        let preparedAt = Date(timeIntervalSince1970: 2_000)
        var authorization = TextConfirmationAuthorization(
            preparedAt: preparedAt,
            expiresAt: preparedAt.addingTimeInterval(60)
        )
        authorization.noteReadbackCompleted(at: preparedAt.addingTimeInterval(2))

        XCTAssertEqual(
            authorization.decision(
                transcript: "Send it",
                transcribedAt: preparedAt.addingTimeInterval(3),
                now: preparedAt.addingTimeInterval(3)
            ),
            .invalidate
        )
        XCTAssertEqual(
            authorization.decision(
                transcript: "Confirm text",
                transcribedAt: preparedAt.addingTimeInterval(61),
                now: preparedAt.addingTimeInterval(61)
            ),
            .invalidate
        )
    }

    func testAuthorizationRejectsStaleTranscriptAndInvalidReadbackTime() {
        let preparedAt = Date(timeIntervalSince1970: 3_000)
        var authorization = TextConfirmationAuthorization(
            preparedAt: preparedAt,
            expiresAt: preparedAt.addingTimeInterval(300)
        )
        authorization.noteReadbackCompleted(at: preparedAt.addingTimeInterval(-1))
        XCTAssertNil(authorization.readbackCompletedAt)

        authorization.noteReadbackCompleted(at: preparedAt.addingTimeInterval(1))
        XCTAssertEqual(
            authorization.decision(
                transcript: "Confirm text",
                transcribedAt: preparedAt.addingTimeInterval(2),
                now: preparedAt.addingTimeInterval(33)
            ),
            .invalidate
        )
    }
}

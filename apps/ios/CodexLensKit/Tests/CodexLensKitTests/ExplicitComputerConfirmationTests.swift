import XCTest
@testable import CodexLensKit

final class ExplicitComputerConfirmationTests: XCTestCase {
    func testAcceptsUnmistakableLaterActionPhrases() {
        XCTAssertTrue(ExplicitComputerConfirmation.accepts("Run it."))
        XCTAssertTrue(ExplicitComputerConfirmation.accepts("Yes, run it!"))
        XCTAssertTrue(ExplicitComputerConfirmation.accepts("Go ahead and run it"))
    }

    func testRejectsGenericOrEmbeddedAgreement() {
        XCTAssertFalse(ExplicitComputerConfirmation.accepts("Yes"))
        XCTAssertFalse(ExplicitComputerConfirmation.accepts("Okay"))
        XCTAssertFalse(ExplicitComputerConfirmation.accepts("He said run it yesterday"))
        XCTAssertFalse(ExplicitComputerConfirmation.accepts("Do not run it"))
    }
}

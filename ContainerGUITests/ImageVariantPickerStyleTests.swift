import XCTest

/// Verifies which control the image-detail sheet uses to switch platform variants.
///
/// This exists because of issue #19: a segmented picker is not compressible — an
/// `NSSegmentedControl` claims the sum of its label widths and refuses to go
/// narrower. With a multi-platform image such as `postgres:18` (8 variants, up to
/// `linux/ppc64le`) it claimed more than the sheet's 640 pt, pushed the whole
/// `ScrollView` content past the frame and clipped the labels on both sides.
final class ImageVariantPickerStyleTests: XCTestCase {

    // MARK: - Styles that fit

    func testFewVariantsStaySegmented() {
        // The common case — arm64 + amd64 — reads best as one visible row.
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: 1), .segmented)
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: 2), .segmented)
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: 3), .segmented)
    }

    func testTheWidestFittingCountIsStillSegmented() {
        // 4 × ~105 pt (`linux/ppc64le`) plus the "Wariant" label ≈ 480 pt, inside
        // the ~616 pt the 640 pt sheet leaves after padding. 5 no longer fits.
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: 4), .segmented)
    }

    // MARK: - Styles that would overflow

    func testMoreVariantsThanFitFallBackToAMenu() {
        // A menu has a fixed, compact width, so it cannot push the sheet open.
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: 5), .menu)
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: 8), .menu)
    }

    func testTheImageFromIssue19UsesAMenu() {
        // postgres:18 — the exact case in the bug report.
        let postgresVariants = [
            "linux/amd64", "linux/arm", "linux/arm", "linux/arm64",
            "linux/386", "linux/ppc64le", "linux/riscv64", "linux/s390x",
        ]
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: postgresVariants.count), .menu)
    }

    // MARK: - The threshold itself

    func testTheSegmentedLimitIsPinned() {
        // A layout decision, not a preference: raising it reintroduces issue #19.
        XCTAssertEqual(ImageVariantPickerStyle.segmentedLimit, 4)
    }

    func testDegenerateCountsDoNotFallIntoTheMenuBranch() {
        // `variants` is filtered before it gets here, so an empty list is reachable.
        XCTAssertEqual(ImageVariantPickerStyle.style(forVariantCount: 0), .segmented)
    }
}

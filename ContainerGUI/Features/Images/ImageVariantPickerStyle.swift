/// Which control the image-detail sheet uses to switch between platform variants.
///
/// A segmented picker is not compressible: `NSSegmentedControl` claims the sum of
/// its label widths and refuses to go narrower. A multi-platform image such as
/// `postgres:18` has 8 variants, which claimed more than the sheet's 640 pt,
/// pushed the content past the frame and clipped the labels (issue #19). Past the
/// count that still fits, a menu — fixed, compact width — takes over.
enum ImageVariantPickerStyle {
    case segmented
    case menu

    /// The widest variant label is `linux/ppc64le` at roughly 105 pt. Four of
    /// those plus the picker's own label fit the ~616 pt the sheet leaves after
    /// padding; five do not.
    static let segmentedLimit = 4

    static func style(forVariantCount count: Int) -> ImageVariantPickerStyle {
        count <= segmentedLimit ? .segmented : .menu
    }
}

import CoreGraphics

/// The handful of numbers the interface is allowed to be built from.
///
/// Before these existed the app drew what is conceptually one thing — a section
/// card — fifteen different ways: five paddings crossed with seven corner radii,
/// none of them chosen, all of them arrived at. Nothing looked broken on its own
/// screen; it looked unsettled across screens, which is harder to point at and
/// worse to live with.
///
/// The scale is deliberately short. A value that is not here is a decision
/// somebody should have to justify.
enum Radius {
    /// Chips, badges, the plate that appears behind an icon button on hover.
    static let chip: CGFloat = 6
    /// Section cards — the surface that repeats down every section.
    static let card: CGFloat = 10
    /// Large standalone containers: onboarding, empty states, inner panels.
    static let panel: CGFloat = 14
}

enum Padding {
    /// Inside a chip.
    static let chip: CGFloat = 6
    /// Inside a section card. Roomy on purpose: these hold a title, a line of
    /// explanation and usually a control, and the old 8 crowded all three.
    static let card: CGFloat = 14
}

/// Sheets came in four widths — 480, 560, 620 and 640 — which read as four
/// different dialogs from four different apps. Two is enough: one for a couple
/// of fields, one for a form.
enum SheetWidth {
    static let narrow: CGFloat = 480
    static let standard: CGFloat = 640
}

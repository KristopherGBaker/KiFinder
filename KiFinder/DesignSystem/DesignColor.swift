import SwiftUI

enum DesignColor {
    static let canvas = Color("canvas")
    static let sidebar = Color("sidebar")
    static let surface = Color("surface")
    static let ink = Color("ink")
    static let inkSecondary = Color("inkSecondary")
    static let hairline = Color("hairline")
    static let keep = Color("keep")
    static let maybe = Color("maybe")
    static let inkInverse = Color("inkInverse")
    /// Accent for a manually-drawn face region, distinct from the auto-detected
    /// box accent (`maybe`). A named asset with a light + dark variant (unlike the
    /// former hardcoded teal that had no dark appearance).
    static let manualRegion = Color("manualRegion")
}

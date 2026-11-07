import Foundation

/// Public AX wire names used by newer WebKit SDK headers. Keeping the names
/// locally avoids requiring a newer SDK merely to query optional attributes.
/// Unsupported runtime attributes still go through the reader's normal errors.
enum WebSelectionAttributes {
    static let selectedMarkerRange = "AXSelectedTextMarkerRange"
    static let stringForMarkerRange = "AXStringForTextMarkerRange"
}

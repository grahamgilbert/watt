import Foundation

// Compact, rounded menu-bar values. Full precision remains in the tooltip/popover.
func compactNetworkRate(_ rate:Double) -> String {
    guard rate.isFinite,rate>=0 else {return "—"}
    if rate>=1024*1024*1024 {return String(format:rate>=10*1024*1024*1024 ? "%.0fG" : "%.1fG",min(999,rate/1073741824))}
    if rate>=1024*1024 {return String(format:rate>=10*1024*1024 ? "%.0fM" : "%.1fM",rate/1048576)}
    if rate>=1024 {return String(format:"%.0fK",rate/1024)}
    return String(format:"%.0fB",rate)
}

import Foundation

public struct PortRefresh: Sendable {
    public var selectedPath: String
    public var added: [SerialPortInfo]
    public var removed: [SerialPortInfo]
}
public enum PortDiscovery {
    public static func reconcile(previous: [SerialPortInfo], current: [SerialPortInfo], selected: String) -> PortRefresh {
        let old = Set(previous.map(\.path)), new = Set(current.map(\.path))
        let added = current.filter { !old.contains($0.path) }
        let removed = previous.filter { !new.contains($0.path) }
        // Preserve an explicit selection; choose only a unique USB-style port.
        let usb = current.filter { port in
            let n = port.path.lowercased()
            return n.contains("usb") || n.contains("slab") || n.contains("wch") || n.contains("cp210")
        }
        let path = new.contains(selected) ? selected : (usb.count == 1 ? usb[0].path : "")
        return .init(selectedPath: path, added: added, removed: removed)
    }
}

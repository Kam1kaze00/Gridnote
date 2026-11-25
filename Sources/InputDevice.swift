import AppKit
import IOKit

enum InputDevice: String, CaseIterable {
  case wacom, wacomSingle, huion, xppen, xencelabs, sidecar, sidecarUSB, surface, other, mouse
  var title: String {
    switch self {
    case .wacom: return "Wacom · two-button pen"
    case .wacomSingle: return "Wacom · one-button pen"
    case .huion: return "Huion · Inspiroy / Kamvas"
    case .xppen: return "XPPen · Deco / Artist"
    case .xencelabs: return "Xencelabs · Pen Tablet / Display"
    case .sidecar: return "iPad · Apple Pencil with Sidecar"
    case .sidecarUSB: return "iPad · Apple Pencil (USB-C) with Sidecar"
    case .surface: return "Other active stylus"
    case .other: return "Other pen tablet"
    case .mouse: return "Mouse or trackpad"
    }
  }
  var pressure: Bool { self != .mouse && self != .sidecarUSB }
  var hasRockers: Bool { [.wacom, .huion, .xppen, .xencelabs, .other].contains(self) }
  var supportsUpper: Bool {
    hasRockers || self == .wacomSingle || self == .surface || self == .mouse
  }
  var supportsLower: Bool { hasRockers || self == .mouse }
  var setup: String {
    switch self {
    case .sidecar, .sidecarUSB:
      return
        "Connect the iPad through Sidecar and move this window to it. Write with Apple Pencil and scroll with two fingers. Tap Eraser for regular, stroke or region erasing."
    case .mouse:
      return
        "Drag to write with a fixed-width brush. Scroll with the wheel, trackpad, or Space-drag. Right-click arms the eraser for one stroke."
    case .wacomSingle, .surface:
      return
        "Assign the pen button to Right Click to erase for one tip contact. Hold Space and drag, or use the trackpad, to scroll."
    default:
      return
        "For drivers with application settings, choose Gridnote and map the upper switch to Right Click and the lower switch to Middle Click. Tap the upper switch to erase until tip lift. Hold the lower switch and move vertically to scroll."
    }
  }

  static func connected(vendor preferred: Int? = nil) -> (profile: InputDevice, name: String?) {
    var iterator: io_iterator_t = 0
    if IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    {
      defer { IOObjectRelease(iterator) }
      while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        let vendor =
          (IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? NSNumber)?.intValue
        if let preferred, preferred != vendor { continue }
        let product =
          IORegistryEntryCreateCFProperty(
            service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
          as? String ?? ""
        let name = product.lowercased()
        if vendor == 0x056a {
          return (
            name.contains("dtc133") ? .wacomSingle : .wacom,
            name == "ctl-672" || name == "ctl-472"
              ? "One by Wacom (" + product + ")" : (product.isEmpty ? "Wacom tablet" : product)
          )
        }
        if vendor == 0x256c || name.contains("huion") || name.contains("kamvas") {
          return (.huion, product.isEmpty ? "Huion tablet" : product)
        }
        if vendor == 0x28bd || name.contains("xp-pen") || name.contains("xppen") {
          return (.xppen, product.isEmpty ? "XPPen tablet" : product)
        }
        if name.contains("xencelabs") { return (.xencelabs, product) }
      }
    }
    if preferred == 0x05ac { return (.sidecar, "Apple Pencil") }
    if preferred != nil { return (.other, "Active pen") }
    return (.mouse, nil)
  }
}

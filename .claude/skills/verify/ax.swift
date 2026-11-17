// Read or press a StatBar copy's accessibility tree by PID (the debug and installed copies share a name and bundle ID).
//   swift .claude/skills/verify/ax.swift <pid>                 dump roles and titles (popover contents only while it is open)
//   swift .claude/skills/verify/ax.swift <pid> press <title>   AXPress the control labelled <title> (exact, else prefix)
//   swift .claude/skills/verify/ax.swift <pid> toggle          open or close the popover (presses the status item)
//   swift .claude/skills/verify/ax.swift <pid> window          the open popover's window number, for `screencapture -l`
import ApplicationServices
import CoreGraphics
let args = Array(CommandLine.arguments.dropFirst())
guard let pid = Int32(args.first ?? "") else { print("usage: ax.swift <pid> [toggle | press <title> | window]"); exit(2) }
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func label(_ e: AXUIElement) -> String { (attr(e, "AXTitle") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (attr(e, "AXDescription") as? String) ?? (attr(e, "AXValue") as? String) ?? "" }
func walk(_ e: AXUIElement, _ depth: Int = 0, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(e, depth) { return true }
    for kid in attr(e, "AXChildren") as? [AXUIElement] ?? [] where walk(kid, depth + 1, visit) { return true }
    return false
}
switch args.dropFirst().first {
case "press":
    let title = args.dropFirst(2).joined(separator: " ")
    var found = false
    // Exact label first ("CPU" is the sort button, not "CPU cores"), then prefix ("Plugged in" for a changing label).
    // Static text is skipped: the "Memory" heading accepts AXPress as a no-op and would shadow the Memory sort button.
    for exact in [true, false] where !found {
        _ = walk(app) { e, _ in
            let l = label(e)
            guard exact ? l == title : l.hasPrefix(title), attr(e, "AXRole") as? String != "AXStaticText",
                  AXUIElementPerformAction(e, kAXPressAction as CFString) == .success else { return false }
            found = true
            return true
        }
    }
    print(found ? "pressed \(title)" : "FAIL: no pressable element titled \(title) (popover closed? any click elsewhere closes it)")
    exit(found ? 0 : 1)
case "toggle":
    var ok = false
    _ = walk(app) { e, _ in
        guard attr(e, "AXRole") as? String == "AXMenuBarItem" else { return false }
        ok = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        return true
    }
    print(ok ? "toggled" : "FAIL: no status item (is AX allowed for this terminal?)")
    exit(ok ? 0 : 1)
case "window":
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = all.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
    print("\(mine?[kCGWindowNumber as String] ?? 0)")
default:
    _ = walk(app) { e, d in print(String(repeating: "  ", count: d) + "\(attr(e, "AXRole") as? String ?? "?") \(label(e))"); return false }
}

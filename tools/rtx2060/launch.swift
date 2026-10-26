// launch BUNDLE-ID [TIMEOUT] - opens the app and prints JSON with the time to its first on-screen window, then quits it.
// An app that is already running is left alone (reported as skipped): the harness never closes the owner's apps.
// The window test is CGWindowList's owner pid at layer 0, which needs no Screen Recording permission.
import AppKit

let a = CommandLine.arguments
guard a.count >= 2 else { FileHandle.standardError.write("usage: launch BUNDLE-ID [TIMEOUT]\n".data(using: .utf8)!); exit(2) }
let id = a[1], timeout = a.count > 2 ? Double(a[2]) ?? 30 : 30
func out(_ d: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { out(["app": id, "skipped": "already running"]) }
guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { out(["app": id, "skipped": "not installed"]) }

func hasWindow(_ pid: pid_t) -> Bool {
    guard let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    return l.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
}

let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true; cfg.addsToRecentItems = false
let t0 = Date()
var app: NSRunningApplication?, err: Error?
NSWorkspace.shared.openApplication(at: url, configuration: cfg) { r, e in app = r; err = e }
var running: Double?, window: Double?
while Date().timeIntervalSince(t0) < timeout {
    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    if app != nil && running == nil { running = Date().timeIntervalSince(t0) * 1000 }
    if let p = app, hasWindow(p.processIdentifier) { window = Date().timeIntervalSince(t0) * 1000; break }
    if err != nil { break }
}
var r: [String: Any] = ["app": id]
if let e = err { r["error"] = "\(e)" }
if let v = running { r["process_ms"] = (v * 10).rounded() / 10 }
if let v = window { r["window_ms"] = (v * 10).rounded() / 10 } else { r["window_ms"] = NSNull() }
// let the first frame settle before quitting so its shaders reach the cache, as a real launch would
RunLoop.current.run(until: Date().addingTimeInterval(2))
if let p = app {
    p.terminate()
    let q = Date()
    while !p.isTerminated && Date().timeIntervalSince(q) < 10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if !p.isTerminated { p.forceTerminate() }
}
out(r)

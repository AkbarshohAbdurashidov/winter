import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Menu-bar app: quit only via "Quit Winter". AppKit does not count the
  // overlay NSPanels as windows, so closing the status menu's own window
  // looked like "last window closed" and quit the app.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

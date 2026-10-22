// Makes DualPane the default application for opening folders and volumes, so `open ~/Documents`
// and folders opened from other apps land in DualPane. "off" hands them back to Finder.
// Usage: swift Tools/set-default-folder-app.swift [on|off]
import AppKit
import UniformTypeIdentifiers

let off = CommandLine.arguments.dropFirst().first == "off"
let app = URL(fileURLWithPath: off ? "/System/Library/CoreServices/Finder.app" : NSHomeDirectory() + "/Applications/DualPane.app")
let types: [UTType] = [.folder, .volume]
var remaining = types.count
for type in types {
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
        if let error = error { print("\(type.identifier): \(error.localizedDescription)") }
        remaining -= 1
    }
}
let deadline = Date(timeIntervalSinceNow: 60)
while remaining > 0 && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
for type in types { print("\(type.identifier) opens with", NSWorkspace.shared.urlForApplication(toOpen: type)?.path ?? "(none)") }

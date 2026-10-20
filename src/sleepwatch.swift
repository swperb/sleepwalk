// sleepwatch runs `sleepwalk sleep` just before the Mac sleeps and `sleepwalk wake`
// after the user wakes it. `sleepwalk install` builds it and loads it as a LaunchAgent.
// See README.md.
//
// Usage: sleepwatch /path/to/sleepwalk [sleep-budget-seconds]

import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt

// IOKit's power messages are C macros that Swift does not import:
// iokit_common_msg(n) is 0xE0000000 | n.
let msgCanSystemSleep: UInt32 = 0xE000_0270
let msgSystemWillSleep: UInt32 = 0xE000_0280

func log(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) sleepwatch: \(text)\n".data(using: .utf8)!)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    log("usage: sleepwatch /path/to/sleepwalk [sleep-budget-seconds]")
    exit(2)
}
let tool = arguments[1]
let sleepBudget: TimeInterval = arguments.count > 2 ? TimeInterval(arguments[2]) ?? 25 : 25

/// Runs `tool command`. With `wait`, blocks for at most that many seconds and then stops it.
func runTool(_ command: String, wait: TimeInterval?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = [command]
    do {
        try process.run()
    } catch {
        log("could not start \(tool) \(command): \(error)")
        return
    }
    guard let wait = wait else { return }
    let deadline = Date().addingTimeInterval(wait)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
        process.terminate()
        log("\(command) ran past \(Int(wait))s; stopped it so the Mac can sleep")
    }
}

var rootPort: io_connect_t = 0

// macOS waits for IOAllowPowerChange (up to about 30 seconds) before it sleeps, which
// gives the handoff time to commit, push and start the cloud session while the network
// is still up.
let powerCallback: IOServiceInterestCallback = { _, _, messageType, messageArgument in
    switch messageType {
    case msgCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
    case msgSystemWillSleep:
        runTool("sleep", wait: sleepBudget)
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
    default:
        break
    }
}

var notifyPort: IONotificationPortRef?
var notifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &notifyPort, powerCallback, &notifier)
guard rootPort != 0, let port = notifyPort else {
    log("IORegisterForSystemPower failed")
    exit(1)
}
CFRunLoopAddSource(
    CFRunLoopGetCurrent(),
    IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
    .defaultMode)

// NSWorkspace reports only full wakes, not the dark wakes of Power Nap, so it is the
// signal that the user is back. `sleepwalk wake` also checks that the lid is open.
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    runTool("wake", wait: nil)
}

// `sleepwalk simulate` sends SIGUSR1 and SIGUSR2 to rehearse a sleep and a wake, so the
// steps run exactly as they would from here, without closing the lid.
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)
let simulatedSleep = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
simulatedSleep.setEventHandler {
    log("simulated sleep")
    runTool("sleep", wait: sleepBudget)
    log("simulated sleep finished")
}
simulatedSleep.resume()
let simulatedWake = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
simulatedWake.setEventHandler {
    log("simulated wake")
    runTool("wake", wait: nil)
}
simulatedWake.resume()

log("watching for sleep and wake; handoff tool \(tool), budget \(Int(sleepBudget))s")
// Raise any macOS privacy prompts now, while the user is at the Mac, not at lid close.
runTool("preflight", wait: nil)
RunLoop.main.run()

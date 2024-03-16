import ArgumentParser

import Foundation


// ----------------------------------------
// What CPU architecture are we running on?
// ----------------------------------------

func myArch() -> String {
    #if arch(x86_64)
    "x86_64"
    #else
    "arm64"
    #endif
}

// ------------------------------------------
// Data structures for arguments and devices.
// ------------------------------------------

enum OS: String, ExpressibleByArgument {
    case iphone, watch, tv
}

struct Device: Decodable {
    var udid: String
    var name: String
    var state: String
    var runtime: Runtime!
}

struct Runtime: Decodable {
    var identifier: String
    var platform: String
    var version: String

    var os: OS {
        switch platform {
        case "iOS": return .iphone
        case "tvOS": return .tv
        case "watchOS": return .watch
        default:
            fail("Don't know what OS corresponds to simulator runtime \(self).")
        }
    }
}

// ----------------------------
// Helper for managing failure.
// ----------------------------

func fail(_ str: String) -> Never {
    fputs("error: \(str)\n", stderr);
    exit(1)
}


// ---------------------
// Subprocess execution.
// ---------------------

// This terrible hack calls private Foundation API to avoid creating a new
// process group, which keeps the subprocess connected to our shell and lets
// sudo work properly.
@objc protocol NSTaskPrivate {
    @objc func setStartsNewProcessGroup(_ b: ObjCBool)
}
extension Process {
    func dontStartNewProcessGroup() {
        unsafeBitCast(self, to: NSTaskPrivate.self)
            .setStartsNewProcessGroup(false)
    }
}

func runCmd(_ command: String, _ args: [String], redirectStdout: Bool) -> Data {
    print("  Executing:", ([command] + args).joined(separator: " "))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.dontStartNewProcessGroup()

    let pipe = redirectStdout ? Pipe() : nil
    if redirectStdout {
        process.standardOutput = pipe
    }

    try! process.run()
    let data = pipe?.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        fail("\(command) failed with error code \(process.terminationStatus)")
    }
    return data ?? Data()
}

func getCmdOutput(_ command: String, _ args: [String]) -> Data {
    runCmd(command, args, redirectStdout: true)
}

func runCmd(_ command: String, _ args: [String]) -> Void {
    _ = runCmd(command, args, redirectStdout: false)
}

func simctl(_ args: String...) -> Data {
    getCmdOutput("/usr/bin/xcrun", ["simctl"] + args)
}


// -------------------------------
// Inspecting devices from simctl.
// -------------------------------

func simctlDevices() -> [Device] {
    let data = simctl("list", "-j")
    let decoder = JSONDecoder()

    struct SimctlJSON: Decodable {
        var devices: [String: [Device]]
        var runtimes: [Runtime]
    }
    let decoded = try! decoder.decode(SimctlJSON.self, from: data)
    return decoded.devices.flatMap { runtimeID, devices -> [Device] in
        guard let runtime = decoded.runtimes.first(where: {
            $0.identifier == runtimeID
        }) else {
            return []
        }
        // Set the runtime field of all the devices in the runtime.
        return devices.map {
            var device = $0
            device.runtime = runtime
            return device
        }
    }
}

func getDevice(_ str: String) -> Device {
    let devices = simctlDevices()
    let matchingDevices = devices.filter { $0.udid == str || $0.name == str }
    if matchingDevices.isEmpty {
        fail("Can't find device with name/udid '\(str)' - run 'xcrun simctl "
           + "list devices' and find a suitable device in the list")
    }
    let latestRuntime = matchingDevices.compactMap(\.runtime).sorted(by: {
        $0.version.compare($1.version, options: .numeric) == .orderedAscending
    }).last!
    return matchingDevices.first(where: {
        $0.runtime.identifier == latestRuntime.identifier
    })!
}

func getDevice(_ str: String?, os: OS, version: String) -> Device {
    if let str {
        return getDevice(str)
    }

    let devices = simctlDevices()
    let matchingDevices = devices.filter {
        $0.runtime.os == os && $0.runtime.version == version
    }
    if matchingDevices.isEmpty {
        fail("Can't find device matching: \(os) \(version) - run 'xcrun simctl "
           + "list devices' to see what's installed and select a specific "
           + "device with --device-id, or install an appropriate simulator "
           + "runtime with 'xcrun simctl runtime add <build>'")
    }
    return matchingDevices.first!
}


// --------------------------
// Getting info about dylibs.
// --------------------------

func getLibInfo(path: String, arch: String) -> (os: OS, version: String) {
    let output = getCmdOutput("/usr/bin/dyld_info",
                              ["-arch", arch, "-platform", path])
    guard let string = String(data: output, encoding: .utf8) else {
        fail("dyld_info output was not valid UTF-8 somehow.")
    }
    guard let lastLine = string.split(separator: "\n").last else {
        fail("dyld_info output was empty")
    }

    let components = lastLine.split(separator: " ",
                                    omittingEmptySubsequences: true)
    if components.count < 2 {
        fail("dyld_info's last line wasn't formatted like we expected: "
           + "\(lastLine)")
    }

    let platform = components[0]
    let version = String(components[1])

    let os: OS
    switch platform {
    case "iOS-sim": os = .iphone
    case "tvOS-sim": os = .tv
    case "watchOS-sim": os = .watch
    default:
        fail("Unknown libobjc platform: \(platform)")
    }
    return (os, version)
}

// -------------------------------
// Locating the project directory.
// -------------------------------

func findProjectDirectory() -> String {
    let commandName = CommandLine.arguments[0]

    var url = URL(fileURLWithPath: commandName)
    while url.path != "/" {
        let xcodeprojURL = url.appendingPathComponent("objc.xcodeproj")
        if (try? xcodeprojURL.checkResourceIsReachable()) == true {
            return url.path
        }
        url.deleteLastPathComponent()
    }
    fail("Could not locate directory containing objc.xcodeproj.")
}

@main
struct Main: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Run objc4 tests in the simulator."
    )

    @Option(help: "UDID or name of device (from xcrun simctl list devices)")
    var deviceID: String?

    @Option
    var projectDirectory: String?

    @Option(help: "Build the project with buildit using the specified train.")
    var builditTrain: String?

    @Option(help: "Test the libobjc in the specified root.")
    var root: String?

    func run() throws {
        // Validate parameters.
        if (builditTrain != nil && root != nil)
            || (builditTrain == nil && root == nil) {
            fail("Must specify exactly one of --buildit-train and --root.")
        }

        if builditTrain != nil && geteuid() != 0 {
            print("Not running as root. Buildit will attempt to sudo, be ready "
                + "to authenticate.")
        }

        // Find the project directory we're using.
        let resolvedProjectDirectory = projectDirectory
                                    ?? findProjectDirectory()

        // Locate, and possibly build, the root.
        let finalRootPath: String

        if let builditTrain {
            print("Building objc4 with buildit")
            runCmd("/usr/bin/sudo",
                   ["/usr/local/bin/buildit",
                    "-release", builditTrain,
                    "-project", "objc4_Sim",
                    resolvedProjectDirectory])
            finalRootPath =
                "/tmp/objc4_Sim_objc4.roots/BuildRecords/objc4_Sim_install/Root"
        } else {
            if (root! as NSString).pathComponents.contains("SWE") {
                print("NFS root detected, copying to /tmp.")
                finalRootPath = "/tmp/objc4-nfs-root"
                try? FileManager.default.removeItem(atPath: finalRootPath)
                try! FileManager.default.copyItem(atPath: root!,
                                                  toPath: finalRootPath)
            } else {
                finalRootPath = root!
            }
        }

        // Inspect the library in the root.
        let libobjc = (finalRootPath as NSString).appendingPathComponent(
            "usr/lib/libobjc.A.dylib")
        let (os, libobjcVersion) = getLibInfo(path: libobjc, arch: myArch())

        // Find the appropriate device.
        let device = getDevice(deviceID, os: os, version: libobjcVersion)
        print("Found device \(device.name) \(device.udid) \(device.runtime!)")

        if device.state != "Booted" {
            print("Device not booted, booting it now...")
            _ = simctl("boot", device.udid)
        }

        print("Running tests")
        let testScript = (resolvedProjectDirectory as NSString)
            .appendingPathComponent("test/test.pl")
        runCmd(testScript,
               ["ROOT=\(finalRootPath)",
                "OS=\(os.rawValue)simulator",
                "DEVICE=\(device.udid)",
                "ARCH=\(myArch())"])
    }
}

// --------
// The end.
// --------

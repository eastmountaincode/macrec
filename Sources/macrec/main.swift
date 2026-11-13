import Foundation
import MacRecCore

func usage() -> Never {
    let msg = """
    macrec — record system audio + microphone to two synced .m4a tracks

    USAGE:
      macrec record [--output DIR] [--title TITLE] [--mic DEVICE_ID] [--mic-gain-db DB] [--system-gain-db DB]
      macrec devices
      macrec --help

    Recording stops on Ctrl-C; both tracks are finalized cleanly before exit.

    The first run will trigger macOS permission prompts:
      • Microphone (required)
      • System Audio Recording Only (required for call/system audio)
    Re-run after granting both.

    """
    FileHandle.standardError.write(Data(msg.utf8))
    exit(2)
}

func resolveOutputDir(_ arg: String?) -> URL {
    if let arg = arg {
        return URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, isDirectory: true)
    }
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    return desktop.appendingPathComponent("macrec", isDirectory: true)
}

func listDevices() {
    let devices = AudioDevices.availableInputs()
    if devices.isEmpty {
        print("No audio input devices found.")
        return
    }
    print("Audio input devices:")
    for d in devices {
        print("  \(d.id)\t\(d.name)")
    }
}

@main
struct CLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { usage() }

        switch cmd {
        case "--help", "-h", "help":
            usage()
        case "devices":
            listDevices()
        case "record":
            await runRecord(args: Array(args.dropFirst()))
        default:
            usage()
        }
    }

    static func runRecord(args: [String]) async {
        var output: String?
        var title: String?
        var mic: String?
        var micGainDecibels = 0.0
        var systemGainDecibels = 0.0
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--output", "-o":
                i += 1; if i < args.count { output = args[i] }
            case "--title", "-t":
                i += 1; if i < args.count { title = args[i] }
            case "--mic":
                i += 1; if i < args.count { mic = args[i] }
            case "--mic-gain-db":
                i += 1; if i < args.count { micGainDecibels = Double(args[i]) ?? 0 }
            case "--system-gain-db":
                i += 1; if i < args.count { systemGainDecibels = Double(args[i]) ?? 0 }
            default:
                FileHandle.standardError.write(Data("unknown arg: \(args[i])\n".utf8))
                usage()
            }
            i += 1
        }

        let outDir = resolveOutputDir(output)
        let recorder = Recorder()

        let stopSignal = DispatchSemaphore(value: 0)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sigint.setEventHandler { stopSignal.signal() }
        sigterm.setEventHandler { stopSignal.signal() }
        sigint.resume()
        sigterm.resume()

        do {
            let session = try await recorder.start(
                outputDirectory: outDir,
                title: title,
                micDeviceID: mic,
                micGainDecibels: micGainDecibels,
                systemGainDecibels: systemGainDecibels
            )
            print("recording to \(session.directory.path)")
            print("  me   → \(session.micFile.lastPathComponent)")
            print("  call → \(session.systemFile.lastPathComponent)")
            print("press Ctrl-C to stop.")

            // Block until signal arrives.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    stopSignal.wait()
                    cont.resume()
                }
            }

            print("\nstopping…")
            let finished = try await recorder.stop()
            print("done. files in \(finished.directory.path)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

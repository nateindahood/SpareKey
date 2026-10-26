import Foundation
import SpareKeyKit

/// `SpareKey --service` runs the background clock loop (used by the LaunchAgent);
/// `SpareKey --info` prints the keyboard state for quick testing; otherwise the app opens.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--service") {
            Service.run()
        } else if args.contains("--info") {
            do {
                try DeviceQueue.shared.runSync { d in
                    d.verbose = args.contains("-v")
                    let p = try d.profile()
                    let lp = p.ledParam()
                    print("\(d.model), firmware \(try d.firmware())")
                    print("lighting: \(Effects.byID(p.effect)?.name ?? "effect \(p.effect)"), "
                          + "brightness \(Profile.level(for: lp.brightness))/5, speed \(lp.speed)/4, mix \(lp.mix)")
                    print("sleep after \(p.sleepMinutes) min, win lock \(p.winLock), WASD swap \(p.wasdSwap)")
                    print("base layer, first keys: \(try d.keymatrix(table: 0, layer: 0).prefix(6).map { String(format: "%08x", $0) })")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
                exit(1)
            }
        } else if args.contains("--backup") {
            do {
                try DeviceQueue.shared.runSync { try Keyboard.ensureFirstBackup($0) }
                print(Store.backupDir.appendingPathComponent("s98-original.json").path)
                exit(0)
            } catch {
                FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
                exit(1)
            }
        } else if args.contains("--restore-profile") {
            do {
                let url = Store.backupDir.appendingPathComponent("s98-original.json")
                let same = try DeviceQueue.shared.runSync { try Keyboard.restoreProfile($0, from: url) }
                print(same ? "profile restored and verified" : "profile written, but it reads back differently")
                exit(same ? 0 : 1)
            } catch {
                FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
                exit(1)
            }
        } else if args.contains("--probe") {
            S98Device.probe()
            exit(0)
        } else if args.contains("--clock") {
            do {
                try DeviceQueue.shared.runSync { try $0.syncClock() }
                print("clock set")
                exit(0)
            } catch {
                FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
                exit(1)
            }
        } else {
            SpareKeyApp.main()
        }
    }
}

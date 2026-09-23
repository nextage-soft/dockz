import Foundation

/// User-tunable VM settings persisted as JSON at ~/.dockz/config.json.
/// Decoding is field-by-field so adding new settings never resets old ones.
struct DockzSettings: Codable {
    var cpuCount: Int = 4
    var memoryGiB: UInt64 = 4
    var diskLimitGB: Int = 64
    var shareHomeDirectory: Bool = true
    var enableRosetta: Bool = true
    /// IANA zone for the VM; empty = follow this Mac.
    var timeZone: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 4
        memoryGiB = try container.decodeIfPresent(UInt64.self, forKey: .memoryGiB) ?? 4
        diskLimitGB = try container.decodeIfPresent(Int.self, forKey: .diskLimitGB) ?? 64
        shareHomeDirectory = try container.decodeIfPresent(Bool.self, forKey: .shareHomeDirectory) ?? true
        enableRosetta = try container.decodeIfPresent(Bool.self, forKey: .enableRosetta) ?? true
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? ""
    }

    static func load(from paths: DockzPaths) -> DockzSettings {
        guard let data = try? Data(contentsOf: paths.configFile),
              let settings = try? JSONDecoder().decode(DockzSettings.self, from: data) else {
            let defaults = DockzSettings()
            defaults.save(to: paths)
            return defaults
        }
        return settings
    }

    /// Returns false when the config could not be written (full/read-only
    /// disk) — callers surface that instead of silently losing the settings.
    @discardableResult
    func save(to paths: DockzPaths) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        do {
            try data.write(to: paths.configFile)
            return true
        } catch {
            NSLog("dockz: could not save settings — \(error.localizedDescription)")
            return false
        }
    }
}

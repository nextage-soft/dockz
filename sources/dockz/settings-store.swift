import Foundation

/// User-tunable VM settings persisted as JSON at ~/.dockz/config.json.
/// Decoding is field-by-field so adding new settings never resets old ones.
struct DockzSettings: Codable {
    var cpuCount: Int = 4
    var memoryGiB: UInt64 = 4
    var diskLimitGB: Int = 64
    var shareHomeDirectory: Bool = true
    var enableRosetta: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 4
        memoryGiB = try container.decodeIfPresent(UInt64.self, forKey: .memoryGiB) ?? 4
        diskLimitGB = try container.decodeIfPresent(Int.self, forKey: .diskLimitGB) ?? 64
        shareHomeDirectory = try container.decodeIfPresent(Bool.self, forKey: .shareHomeDirectory) ?? true
        enableRosetta = try container.decodeIfPresent(Bool.self, forKey: .enableRosetta) ?? true
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

    func save(to paths: DockzPaths) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: paths.configFile)
        }
    }
}

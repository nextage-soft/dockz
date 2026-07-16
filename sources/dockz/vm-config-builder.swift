import Foundation
import Virtualization

/// Builds the VZVirtualMachineConfiguration for the Dockz guest VM.
enum VMConfigBuilder {
    static func build(paths: DockzPaths, settings: DockzSettings) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = clampCPUCount(settings.cpuCount)
        config.memorySize = clampMemorySize(settings.memoryGiB * 1024 * 1024 * 1024)
        config.bootLoader = try makeBootLoader(paths: paths)
        config.platform = try makePlatform(paths: paths)
        config.storageDevices = try makeStorageDevices(paths: paths)
        config.networkDevices = [try makeNetwork(paths: paths)]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.serialPorts = [try makeSerialConsole(paths: paths)]
        config.directorySharingDevices = makeDirectoryShares(settings: settings)
        try config.validate()
        return config
    }

    // MARK: - Devices

    private static func makeBootLoader(paths: DockzPaths) throws -> VZEFIBootLoader {
        let efi = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: paths.efiVariableStore.path) {
            efi.variableStore = VZEFIVariableStore(url: paths.efiVariableStore)
        } else {
            efi.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: paths.efiVariableStore)
        }
        return efi
    }

    private static func makePlatform(paths: DockzPaths) throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: paths.machineIdentifier),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            let identifier = VZGenericMachineIdentifier()
            try identifier.dataRepresentation.write(to: paths.machineIdentifier)
            platform.machineIdentifier = identifier
        }
        return platform
    }

    private static func makeStorageDevices(paths: DockzPaths) throws -> [VZStorageDeviceConfiguration] {
        let mainAttachment = try VZDiskImageStorageDeviceAttachment(
            url: paths.diskImage,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .fsync
        )
        var devices: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(attachment: mainAttachment)]
        // Cloud-image machines carry a read-only cloud-init seed ISO.
        if FileManager.default.fileExists(atPath: paths.seedISO.path),
           let seedAttachment = try? VZDiskImageStorageDeviceAttachment(url: paths.seedISO, readOnly: true) {
            devices.append(VZVirtioBlockDeviceConfiguration(attachment: seedAttachment))
        }
        return devices
    }

    private static func makeNetwork(paths: DockzPaths) throws -> VZVirtioNetworkDeviceConfiguration {
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        // A stable MAC address keeps the DHCP lease (and guest IP) stable.
        if let stored = try? String(contentsOf: paths.macAddressFile, encoding: .utf8),
           let mac = VZMACAddress(string: stored.trimmingCharacters(in: .whitespacesAndNewlines)) {
            network.macAddress = mac
        } else {
            let mac = VZMACAddress.randomLocallyAdministered()
            try? mac.string.write(to: paths.macAddressFile, atomically: true, encoding: .utf8)
            network.macAddress = mac
        }
        return network
    }

    private static func makeSerialConsole(paths: DockzPaths) throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: paths.consoleLog, append: false)
        return console
    }

    private static func makeDirectoryShares(settings: DockzSettings) -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        if settings.shareHomeDirectory {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "home")
            device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: home, readOnly: false))
            devices.append(device)
        }
        if settings.enableRosetta, VZLinuxRosettaDirectoryShare.availability == .installed,
           let rosetta = try? VZLinuxRosettaDirectoryShare() {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            device.share = rosetta
            devices.append(device)
        }
        return devices
    }

    // MARK: - Limits

    private static func clampCPUCount(_ requested: Int) -> Int {
        let hardwareMax = ProcessInfo.processInfo.processorCount
        let upper = min(hardwareMax, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        return max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(requested, upper))
    }

    private static func clampMemorySize(_ requested: UInt64) -> UInt64 {
        let lower = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let upper = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return max(lower, min(requested, upper))
    }
}

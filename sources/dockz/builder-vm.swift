import Foundation
import Virtualization

/// The throwaway Alpine-netboot VM used by `Dockz build-image` to provision
/// the guest disk image without any Docker daemon. Boots kernel+initramfs via
/// VZLinuxBootLoader, shares the repo's guest/ directory over virtiofs and
/// exposes the serial console as a pair of pipes for expect-style automation.
final class BuilderVM: NSObject, VZVirtualMachineDelegate {
    private let queue = DispatchQueue(label: "com.nextagesoft.dockz.builder-vm")
    private var virtualMachine: VZVirtualMachine?
    private let stopSemaphore = DispatchSemaphore(value: 0)

    let hostToGuest = Pipe()
    let guestToHost = Pipe()

    var consoleReadHandle: FileHandle { guestToHost.fileHandleForReading }
    var consoleWriteHandle: FileHandle { hostToGuest.fileHandleForWriting }

    func start(kernel: URL, initrd: URL, disk: URL, guestDir: URL) throws {
        let bootLoader = VZLinuxBootLoader(kernelURL: kernel)
        bootLoader.initialRamdiskURL = initrd
        bootLoader.commandLine = [
            "console=hvc0",
            "ip=dhcp",
            "alpine_repo=\(ImageBuilderCLI.alpineRepoURL)",
            "modloop=\(ImageBuilderCLI.alpineModloopURL)",
        ].joined(separator: " ")

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = min(4, ProcessInfo.processInfo.processorCount)
        config.memorySize = 2 * 1024 * 1024 * 1024
        config.bootLoader = bootLoader

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        let share = VZVirtioFileSystemDeviceConfiguration(tag: "dockzsrc")
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: guestDir, readOnly: true))
        config.directorySharingDevices = [share]

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: hostToGuest.fileHandleForReading,
            fileHandleForWriting: guestToHost.fileHandleForWriting
        )
        config.serialPorts = [serial]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try config.validate()

        var startError: Error?
        let started = DispatchSemaphore(value: 0)
        queue.async {
            let vm = VZVirtualMachine(configuration: config, queue: self.queue)
            vm.delegate = self
            self.virtualMachine = vm
            vm.start { result in
                if case .failure(let error) = result { startError = error }
                started.signal()
            }
        }
        started.wait()
        if let startError { throw startError }
    }

    /// Blocks until the guest powers itself off (or the timeout elapses).
    func waitForShutdown(timeout: TimeInterval) -> Bool {
        return stopSemaphore.wait(timeout: .now() + timeout) == .success
    }

    func forceStop() {
        queue.async {
            guard let vm = self.virtualMachine else { return }
            vm.stop { _ in self.virtualMachine = nil }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        self.virtualMachine = nil
        stopSemaphore.signal()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        self.virtualMachine = nil
        stopSemaphore.signal()
    }
}

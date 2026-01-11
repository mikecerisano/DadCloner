import Foundation
import AppKit
import DiskArbitration

/// Information about a mounted volume
struct VolumeInfo: Identifiable, Equatable {
    let id: String // UUID
    let path: String
    let name: String
    let totalSize: Int64
    let freeSpace: Int64
    let isExternal: Bool
    let isWritable: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var formattedFreeSpace: String {
        ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
    }

    var usedPercentage: Double {
        guard totalSize > 0 else { return 0 }
        return Double(totalSize - freeSpace) / Double(totalSize) * 100
    }
}

/// Validation result for drive checks
enum DriveValidationResult: Equatable {
    case valid
    case notMounted
    case wrongDrive(mountedUUID: String)
    case notReadable
    case notWritable
    case markerMissing
    case backupFolderMissing

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String {
        switch self {
        case .valid:
            return "Drive is valid"
        case .notMounted:
            return "Drive is not mounted"
        case .wrongDrive(let uuid):
            return "Wrong drive mounted (UUID: \(uuid))"
        case .notReadable:
            return "Drive is not readable"
        case .notWritable:
            return "Drive is not writable"
        case .markerMissing:
            return "Backup marker file is missing - this may not be the correct backup drive"
        case .backupFolderMissing:
            return "Backup folder is missing on the drive"
        }
    }

    static func == (lhs: DriveValidationResult, rhs: DriveValidationResult) -> Bool {
        switch (lhs, rhs) {
        case (.valid, .valid):
            return true
        case (.notMounted, .notMounted):
            return true
        case (.wrongDrive(let uuid1), .wrongDrive(let uuid2)):
            return uuid1 == uuid2
        case (.notReadable, .notReadable):
            return true
        case (.notWritable, .notWritable):
            return true
        case (.markerMissing, .markerMissing):
            return true
        case (.backupFolderMissing, .backupFolderMissing):
            return true
        default:
            return false
        }
    }
}

/// Monitors and validates drives for backup operations
@Observable
final class DriveMonitor {

    // MARK: - Singleton
    static let shared = DriveMonitor()

    // MARK: - Properties
    private(set) var mountedVolumes: [VolumeInfo] = []
    private(set) var sourceStatus: DriveValidationResult = .notMounted
    private(set) var backupStatus: DriveValidationResult = .notMounted

    private var workspace: NSWorkspace { NSWorkspace.shared }

    // MARK: - Initialization
    private init() {
        refreshMountedVolumes()
        startMonitoring()
    }

    // MARK: - Volume Discovery

    /// Refresh the list of mounted volumes
    func refreshMountedVolumes() {
        var volumes: [VolumeInfo] = []

        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeIsInternalKey
        ]

        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            mountedVolumes = []
            return
        }

        for url in volumeURLs {
            // Skip system volumes
            if url.path == "/" { continue }
            if url.path.hasPrefix("/System") { continue }

            do {
                let resourceValues = try url.resourceValues(forKeys: Set(keys))

                let name = resourceValues.volumeName ?? url.lastPathComponent
                let uuid = resourceValues.volumeUUIDString ?? ""
                let totalSize = Int64(resourceValues.volumeTotalCapacity ?? 0)
                let freeSpace = Int64(resourceValues.volumeAvailableCapacity ?? 0)
                let isInternal = resourceValues.volumeIsInternal ?? true
                let isReadOnly = resourceValues.volumeIsReadOnly ?? true

                // Skip volumes without UUID (virtual volumes, etc.)
                guard !uuid.isEmpty else { continue }

                let info = VolumeInfo(
                    id: uuid,
                    path: url.path,
                    name: name,
                    totalSize: totalSize,
                    freeSpace: freeSpace,
                    isExternal: !isInternal,
                    isWritable: !isReadOnly
                )

                volumes.append(info)
            } catch {
                print("Error getting volume info for \(url): \(error)")
            }
        }

        mountedVolumes = volumes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Update validation status
        validateDrives()
    }

    /// Get UUID for a volume at the given path
    static func getVolumeUUID(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
            return resourceValues.volumeUUIDString
        } catch {
            print("Error getting UUID for \(path): \(error)")
            return nil
        }
    }

    /// Get volume info for a path
    static func getVolumeInfo(at path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)

        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeIsInternalKey
        ]

        do {
            let resourceValues = try url.resourceValues(forKeys: Set(keys))

            let name = resourceValues.volumeName ?? url.lastPathComponent
            let uuid = resourceValues.volumeUUIDString ?? ""
            let totalSize = Int64(resourceValues.volumeTotalCapacity ?? 0)
            let freeSpace = Int64(resourceValues.volumeAvailableCapacity ?? 0)
            let isInternal = resourceValues.volumeIsInternal ?? true
            let isReadOnly = resourceValues.volumeIsReadOnly ?? true

            guard !uuid.isEmpty else { return nil }

            return VolumeInfo(
                id: uuid,
                path: url.path,
                name: name,
                totalSize: totalSize,
                freeSpace: freeSpace,
                isExternal: !isInternal,
                isWritable: !isReadOnly
            )
        } catch {
            return nil
        }
    }

    // MARK: - Drive Validation

    /// Validate both configured drives
    func validateDrives() {
        let config = SyncConfiguration.shared

        guard config.isConfigured else {
            sourceStatus = .notMounted
            backupStatus = .notMounted
            return
        }

        sourceStatus = validateSourceDrive()
        backupStatus = validateBackupDrive()
    }

    /// Validate the source drive
    func validateSourceDrive() -> DriveValidationResult {
        let config = SyncConfiguration.shared
        let path = config.sourceDrivePath
        let expectedUUID = config.sourceDriveUUID

        guard !path.isEmpty, !expectedUUID.isEmpty else {
            return .notMounted
        }

        // Check if path exists
        guard FileManager.default.fileExists(atPath: path) else {
            return .notMounted
        }

        // Check UUID matches
        guard let currentUUID = DriveMonitor.getVolumeUUID(at: path) else {
            return .notMounted
        }

        if currentUUID != expectedUUID {
            return .wrongDrive(mountedUUID: currentUUID)
        }

        // Check readability
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .notReadable
        }

        return .valid
    }

    /// Validate the backup drive
    func validateBackupDrive() -> DriveValidationResult {
        let config = SyncConfiguration.shared
        let path = config.backupDrivePath
        let expectedUUID = config.backupDriveUUID
        let destinationPath = config.backupDestinationPath

        guard !path.isEmpty, !expectedUUID.isEmpty else {
            return .notMounted
        }

        // Check if path exists
        guard FileManager.default.fileExists(atPath: path) else {
            return .notMounted
        }

        // Check UUID matches
        guard let currentUUID = DriveMonitor.getVolumeUUID(at: path) else {
            return .notMounted
        }

        if currentUUID != expectedUUID {
            return .wrongDrive(mountedUUID: currentUUID)
        }

        // Ensure backup destination folder exists (create if needed)
        if !FileManager.default.fileExists(atPath: destinationPath) {
            guard FileManager.default.isWritableFile(atPath: path) else {
                return .notWritable
            }
            guard config.ensureBackupDestinationFolder() else {
                return .backupFolderMissing
            }
        }

        // Check writability
        guard FileManager.default.isWritableFile(atPath: destinationPath) else {
            return .notWritable
        }

        // Check for backup marker file
        let markerPath = config.backupMarkerPath
        guard FileManager.default.fileExists(atPath: markerPath) else {
            return .markerMissing
        }

        return .valid
    }

    /// Check if both drives are ready for sync
    var areDrivesReady: Bool {
        sourceStatus.isValid && backupStatus.isValid
    }

    /// Get a summary status message
    var statusMessage: String {
        if !SyncConfiguration.shared.isConfigured {
            return "Not configured"
        }

        if areDrivesReady {
            return "Ready to sync"
        }

        var issues: [String] = []
        if !sourceStatus.isValid {
            issues.append("Source: \(sourceStatus.errorMessage)")
        }
        if !backupStatus.isValid {
            issues.append("Backup: \(backupStatus.errorMessage)")
        }

        return issues.joined(separator: "; ")
    }

    // MARK: - Monitoring

    private var workspaceObserver: NSObjectProtocol?

    /// Start monitoring for volume mount/unmount events
    func startMonitoring() {
        // Watch for volume mount events
        workspaceObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMountedVolumes()
        }

        // Watch for volume unmount events
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMountedVolumes()
        }
    }

    /// Stop monitoring
    func stopMonitoring() {
        if let observer = workspaceObserver {
            workspace.notificationCenter.removeObserver(observer)
        }
    }

    deinit {
        stopMonitoring()
    }
}

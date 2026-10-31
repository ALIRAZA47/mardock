import Foundation
import MarDockCore

/// Hides, restores and tunes the macOS Dock through the helper. Before
/// MarDock changes anything it records the original values, so "Restore"
/// always puts back exactly what was there.
@MainActor
final class SystemDockManager: ObservableObject {
    @Published private(set) var values: [String: SystemDockValue] = [:]
    @Published private(set) var isAvailable = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    private let agent: AgentClient
    private let defaults: UserDefaults
    private let backupKey = "systemDock.backup.v1"
    private let hiddenKey = "systemDock.hiddenByMarDock.v1"

    init(agent: AgentClient, defaults: UserDefaults = .standard) {
        self.agent = agent
        self.defaults = defaults
    }

    /// True if MarDock hid the macOS Dock and hasn't restored it yet.
    var isHiddenByMarDock: Bool { defaults.bool(forKey: hiddenKey) }
    var looksHidden: Bool { SystemDockSchema.looksHidden(values) }

    func refresh() async {
        do {
            values = try await agent.readSystemDock()
            isAvailable = true
            lastError = nil
        } catch {
            isAvailable = false
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func hide() async -> Bool {
        await perform {
            await self.refresh()
            guard self.isAvailable else { return false }
            // Already out of the way (e.g. MarDock relaunching): don't restart
            // the Dock again, which would make it flash.
            if self.looksHidden { return true }
            self.saveBackup(SystemDockSchema.backup(of: self.values, adding: self.isHiddenByMarDock ? self.loadBackup() : nil))
            try await self.agent.applySystemDock(SystemDockSchema.hideChanges, restartDock: true)
            self.defaults.set(true, forKey: self.hiddenKey)
            return true
        }
    }

    @discardableResult
    func restore() async -> Bool {
        await perform {
            try await self.agent.applySystemDock(SystemDockSchema.restoreChanges(from: self.loadBackup()), restartDock: true)
            self.defaults.set(false, forKey: self.hiddenKey)
            self.defaults.removeObject(forKey: self.backupKey)
            return true
        }
    }

    /// Applies tweaks to the macOS Dock (and restarts it so they take effect).
    @discardableResult
    func apply(_ changes: [SystemDockChange]) async -> Bool {
        guard SystemDockSchema.isValid(changes) else { return false }
        return await perform {
            try await self.agent.applySystemDock(changes, restartDock: true)
            return true
        }
    }

    /// Removes every tweak MarDock knows about, except that a hidden Dock stays hidden.
    @discardableResult
    func resetTweaks() async -> Bool {
        let keys = SystemDockSchema.keys.keys.sorted().filter { !(isHiddenByMarDock && SystemDockSchema.hidingKeys.contains($0)) }
        return await apply(keys.map { SystemDockChange(key: $0, value: nil) })
    }

    private func perform(_ body: () async throws -> Bool) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await body()
            await refresh()
            return result
        } catch {
            lastError = error.localizedDescription
            appLog.error("macOS Dock operation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func saveBackup(_ backup: [String: SystemDockValue]) {
        defaults.set(try? JSONEncoder().encode(backup), forKey: backupKey)
    }

    private func loadBackup() -> [String: SystemDockValue] {
        guard let data = defaults.data(forKey: backupKey), data.count < 16_384,
              let backup = try? JSONDecoder().decode([String: SystemDockValue].self, from: data)
        else { return [:] }
        return backup
    }
}

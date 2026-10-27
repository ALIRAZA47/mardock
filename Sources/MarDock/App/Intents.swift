import AppIntents
import MarDockCore

// Shortcuts actions and a Focus filter. Each one changes only MarDock's own
// dock (its profile, theme, position, hiding or magnification); none reads
// anything or reaches outside the app. Shortcuts finds them through the
// metadata scripts/build-app.sh extracts into the bundle, as Xcode would.

/// The app's state, once it has finished launching (Shortcuts may launch
/// MarDock to run an action).
@MainActor
private func runningCoordinator() async throws -> AppCoordinator {
    for _ in 0..<40 {
        if let coordinator = AppCoordinator.current { return coordinator }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw DockIntentError.notReady
}

enum DockIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case unknownProfile
    case unknownTheme

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "MarDock isn't ready yet. Try again in a moment."
        case .unknownProfile: return "That profile doesn't exist any more."
        case .unknownTheme: return "That theme doesn't exist any more."
        }
    }
}

// MARK: - Profiles

struct ProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dock Profile"
    static var defaultQuery = ProfileQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProfileQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ProfileEntity] {
        try await all()
    }

    @MainActor
    private func all() async throws -> [ProfileEntity] {
        try await runningCoordinator().profiles.profiles.map { ProfileEntity(id: $0.id, name: $0.name) }
    }
}

struct SwitchProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Dock Profile"
    static var description = IntentDescription("Switches MarDock to one of your profiles, such as Work or Personal.")

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch MarDock to \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let profiles = try await runningCoordinator().profiles
        guard profiles.profiles.contains(where: { $0.id == profile.id }) else { throw DockIntentError.unknownProfile }
        profiles.activate(profile.id)
        return .result()
    }
}

/// Uses a profile while a Focus is on, and goes back to the one before when
/// it turns off.
struct DockFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Set Dock Profile"
    static var description = IntentDescription("Uses one of your MarDock profiles while this Focus is on.")

    @Parameter(title: "Profile")
    var profile: ProfileEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(profile?.name ?? "No change")")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runningCoordinator().profiles.applyFocus(profile?.id)
        return .result()
    }
}

// MARK: - Themes

struct ThemeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dock Theme"
    static var defaultQuery = ThemeQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ThemeQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ThemeEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ThemeEntity] {
        try await all()
    }

    /// The built-in themes, then the user's own.
    @MainActor
    private func all() async throws -> [ThemeEntity] {
        let custom = try await runningCoordinator().themes.custom
        return (ThemeID.allCases.map { ThemeRecipe.builtIn($0) } + custom).map { ThemeEntity(id: $0.id, name: $0.name) }
    }
}

struct SetThemeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Dock Theme"
    static var description = IntentDescription("Changes MarDock's theme to a built-in theme or one you made.")

    @Parameter(title: "Theme")
    var theme: ThemeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set the MarDock theme to \(\.$theme)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let coordinator = try await runningCoordinator()
        if theme.id.hasPrefix("builtin:"), let builtIn = ThemeID(rawValue: String(theme.id.dropFirst("builtin:".count))) {
            coordinator.settings.update {
                $0.theme = builtIn
                $0.customTheme = nil
            }
        } else if coordinator.themes.custom.contains(where: { $0.id == theme.id }) {
            coordinator.settings.update { $0.customTheme = theme.id }
        } else {
            throw DockIntentError.unknownTheme
        }
        return .result()
    }
}

// MARK: - Position, hiding and magnification

enum DockPositionOption: String, AppEnum {
    case bottom, left, right

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dock Position"
    static var caseDisplayRepresentations: [DockPositionOption: DisplayRepresentation] = [
        .bottom: "Bottom",
        .left: "Left",
        .right: "Right",
    ]
}

struct SetDockPositionIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Dock Position"
    static var description = IntentDescription("Moves MarDock to the bottom, left or right of the screen.")

    @Parameter(title: "Position")
    var position: DockPositionOption

    static var parameterSummary: some ParameterSummary {
        Summary("Move MarDock to the \(\.$position)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let value = DockPosition(rawValue: position.rawValue) ?? .bottom
        try await runningCoordinator().settings.update { $0.position = value }
        return .result()
    }
}

enum AutoHideOption: String, AppEnum {
    case off, always, smart

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dock Hiding"
    static var caseDisplayRepresentations: [AutoHideOption: DisplayRepresentation] = [
        .off: "Never hide",
        .always: "Always hide",
        .smart: "Hide when a window overlaps",
    ]
}

struct SetAutoHideIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Dock Hiding"
    static var description = IntentDescription("Chooses whether MarDock hides: never, always, or only when a window overlaps it.")

    @Parameter(title: "Hiding")
    var mode: AutoHideOption

    static var parameterSummary: some ParameterSummary {
        Summary("Set MarDock hiding to \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let value = AutoHideMode(rawValue: mode.rawValue) ?? .off
        try await runningCoordinator().settings.update { $0.autoHide = value }
        return .result()
    }
}

struct SetMagnificationIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Dock Magnification"
    static var description = IntentDescription("Turns MarDock's magnification on or off.")

    @Parameter(title: "Magnification", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set MarDock magnification to \(\.$enabled)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let enabled = enabled
        try await runningCoordinator().settings.update { $0.magnificationEnabled = enabled }
        return .result()
    }
}

struct OpenDockSettingsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open MarDock Settings"
    static var description = IntentDescription("Opens MarDock's settings.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runningCoordinator().showSettings()
        return .result()
    }
}

// MARK: - Siri and Spotlight

struct MarDockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SwitchProfileIntent(),
            phrases: [
                "Switch \(.applicationName) to \(\.$profile)",
                "Use my \(\.$profile) dock in \(.applicationName)",
            ],
            shortTitle: "Switch Profile",
            systemImageName: "person.2"
        )
        AppShortcut(
            intent: SetThemeIntent(),
            phrases: [
                "Change the \(.applicationName) theme",
                "Set the \(.applicationName) theme to \(\.$theme)",
            ],
            shortTitle: "Set Theme",
            systemImageName: "paintpalette"
        )
        AppShortcut(
            intent: SetAutoHideIntent(),
            phrases: ["Change how \(.applicationName) hides"],
            shortTitle: "Set Hiding",
            systemImageName: "eye.slash"
        )
    }
}

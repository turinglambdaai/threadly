import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct ThreadlyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(DesignTokens.accent)
                .environmentObject(model)
                .environmentObject(model.store)
                .frame(minWidth: 920, minHeight: 600)
                .sheet(isPresented: Binding(
                    get: { model.aboutVisible },
                    set: { model.aboutVisible = $0 })) {
                    AboutSheet()
                }
                .task { model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check for Updates…") { model.checkForUpdates(manual: true) }
                    .keyboardShortcut("u")
                Divider()
                Button("Refresh") { model.store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            // Replace the system About panel with the family About sheet
            // (version, license, site + issue links).
            CommandGroup(replacing: .appInfo) {
                Button("About Threadly") { model.aboutVisible = true }
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var ready = false
    @Published var bootStatus = "Starting engine…"
    @Published var updateOutcome: Result<UpdateService.CheckResult, Error>?
    @Published var aboutVisible = false

    var pendingUpdateManifest: UpdateService.Manifest? {
        if case .success(.available(let m)) = updateOutcome {
            return m
        }
        return nil
    }

    let store = ThreadlyStore()
    let updateService = UpdateService()
    private var backend: EmbeddedRacketBackend?

    func checkForUpdates(manual: Bool) {
        Task {
            let outcome = await updateService.check(manual: manual)
            await MainActor.run { self.updateOutcome = outcome }
            if case .failure(let error) = outcome, manual {
                await MainActor.run {
                    self.store.statusLine = "Update check failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func installUpdate(_ manifest: UpdateService.Manifest) async {
        do {
            try await updateService.downloadAndInstall(manifest)
        } catch {
            store.statusLine = "Install failed: \(error.localizedDescription)"
        }
    }

    func start() {
        guard backend == nil else { return }

        // THREADLY_APPEARANCE=dark|light pins the appearance for dual-theme
        // verification (the family bar: every UI change proves both modes);
        // unset follows the system. NSApp.appearance, not
        // preferredColorScheme — WKWebView reads the app appearance.
        switch ProcessInfo.processInfo.environment["THREADLY_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        do {
            let config = try Self.runtimeConfiguration()
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            // start() only wires pipes and spawns the Racket thread (the
            // runtime boots off-main), so it is safe to call synchronously;
            // the Task below inherits start()'s MainActor isolation —
            // nothing non-Sendable crosses an actor boundary (same shape
            // the PodLens host ships on both release runners).
            try backend.start(onEvent: { [weak self] name, value in
                guard let event = try? RivetEvent.decode(name: name, value: value) else { return }
                Task { @MainActor [weak self] in
                    self?.store.handleEvent(event)
                }
            })
            let api = RivetAPI(client: backend.client)
            Task { [weak self] in
                await self?.finishBoot(api: api)
            }
        } catch {
            ready = false
            bootStatus = "Engine error: \(error)"
        }
    }

    /// Main-actor boot completion (the Task above inherits the isolation).
    private func finishBoot(api: RivetAPI) async {
        store.bind(api: api)
        ready = true
        bootStatus = "Ready"
        await store.loadCategories()
        await store.load(scope: .latest)
        silentUpdateCheck()
    }

    /// Launch-time check: throttled to once per 4 hours inside the service;
    /// only an available update surfaces, never a failure.
    private func silentUpdateCheck() {
        Task {
            let outcome = await updateService.check(manual: false)
            if case .success(.available) = outcome {
                await MainActor.run { self.updateOutcome = outcome }
            }
        }
    }

    private static func runtimeConfiguration() throws -> EmbeddedRacketConfiguration {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        // Packaged apps keep Racket data in Contents/Resources. `raco rivet
        // dev` runs the staged executable directly, where runtime/res live
        // next to the executable.
        let roots = [
            Bundle.main.resourceURL,
            executable.deletingLastPathComponent()
        ].compactMap { $0 }

        for root in roots {
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let core = root.appendingPathComponent("res/core.zo")
            let required = [
                runtime.appendingPathComponent("petite.boot"),
                runtime.appendingPathComponent("scheme.boot"),
                runtime.appendingPathComponent("racket.boot"),
                core
            ]
            if required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return EmbeddedRacketConfiguration(
                    executable: executable,
                    petiteBoot: required[0],
                    schemeBoot: required[1],
                    racketBoot: required[2],
                    core: core,
                    moduleName: RivetGeneratedConfig.moduleName,
                    entryName: RivetGeneratedConfig.entryName
                )
            }
        }

        throw HostError.missingRuntimeLayout(
            roots.map(\.path).joined(separator: ", ")
        )
    }
}

enum HostError: Error, CustomStringConvertible {
    case missingRuntimeLayout(String)

    var description: String {
        switch self {
        case .missingRuntimeLayout(let roots):
            return "missing Rivet runtime/res layout under: \(roots)"
        }
    }
}

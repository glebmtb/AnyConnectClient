import AppKit
import AnyConnectClientSupport
import Darwin
import OpenConnectRuntime
import VPNCore

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let profileLoader = ProfileConfigurationLoader()
    private let endpointRegistry = ActiveSocksEndpointRegistry()
    private let runtimeRecoveryRegistry = RuntimeRecoveryRegistry()

    private var runtimes: [VPNProfileID: ProfileRuntime] = [:]
    private var selectedProfileID: VPNProfileID?
    private var pulseTimer: Timer?
    private var pulseOn = false
    private var recentEvents: [String] = []
    private var recentEventItems: [NSMenuItem] = []
    private var profileActionItems: [NSMenuItem] = []
    private var settingsProfileItems: [NSMenuItem] = []
    private var retainedButtonTargets: [ClosureButtonTarget] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var terminationInProgress = false

    private lazy var titleItem = NSMenuItem(title: AppVersion.current.menuTitle, action: nil, keyEquivalent: "")
    private lazy var profileItem = NSMenuItem(title: "Profiles: loading", action: nil, keyEquivalent: "")
    private lazy var connectionsHeaderItem = NSMenuItem(title: "Connections", action: nil, keyEquivalent: "")
    private lazy var settingsProfilesHeaderItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
    private lazy var statusMenuItem = NSMenuItem(title: "Status: stopped", action: nil, keyEquivalent: "")
    private lazy var activeProfilesItem = NSMenuItem(title: "Active ports: none", action: nil, keyEquivalent: "")
    private lazy var addProfileItem = NSMenuItem(title: "Add Profile...", action: #selector(addProfileClicked), keyEquivalent: "n")
    private lazy var resetAllDataItem = NSMenuItem(title: "Reset All Data...", action: #selector(resetAllDataClicked), keyEquivalent: "")
    private lazy var recentHeaderItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationMenu()
        configureStatusButton()
        configureMenu()
        configureSignalHandlers()
        refreshProfilesFromSettings()
        updateAggregateUI()
        Task {
            await recoverRuntimeRegistry()
            connectAutoStartProfiles()
            connectAllProfilesForDebugIfRequested()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else {
            return .terminateNow
        }

        terminationInProgress = true
        Task {
            await shutdownAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.image = makeStatusImage()
        button.image?.isTemplate = true
        button.contentTintColor = .systemGray
        button.toolTip = "AnyConnectClient"
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit AnyConnectClient",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureMenu() {
        [titleItem, profileItem, statusMenuItem, activeProfilesItem, connectionsHeaderItem, settingsProfilesHeaderItem, recentHeaderItem].forEach { item in
            item.isEnabled = false
        }

        addProfileItem.target = self
        resetAllDataItem.target = self

        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(profileItem)
        menu.addItem(activeProfilesItem)
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(connectionsHeaderItem)
        renderProfileActionsMenu()
        menu.addItem(NSMenuItem.separator())
        menu.addItem(settingsProfilesHeaderItem)
        renderSettingsProfilesMenu()
        menu.addItem(addProfileItem)
        menu.addItem(resetAllDataItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(recentHeaderItem)
        renderRecentEventsMenu()
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q"))
        menu.items.last?.target = self

        statusItem.menu = menu
    }

    private func configureSignalHandlers() {
        [SIGINT, SIGTERM].forEach { signalNumber in
            signal(signalNumber, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else {
                        Darwin.exit(128 + signalNumber)
                    }
                    await self.shutdownAllSessions()
                    Darwin.exit(128 + signalNumber)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func connectAllProfilesForDebugIfRequested() {
        guard ProcessInfo.processInfo.environment["ANYCONNECTCLIENT_AUTOCONNECT_ALL"] == "1" else {
            return
        }

        Task {
            let profileIDs = runtimes.values
                .map(\.settings)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map(\.id)

            for profileID in profileIDs {
                await connect(profileID: profileID)
            }
        }
    }

    private func connectAutoStartProfiles() {
        guard ProcessInfo.processInfo.environment["ANYCONNECTCLIENT_AUTOCONNECT_ALL"] != "1" else {
            return
        }

        Task {
            let profileIDs = runtimes.values
                .filter { $0.settings.autoStartOnLaunch && $0.state.canConnect }
                .map(\.settings)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map(\.id)

            for profileID in profileIDs {
                appendEvent(profileID: profileID, "Auto-starting")
                await connect(profileID: profileID)
            }
        }
    }

    private func refreshProfilesFromSettings() {
        do {
            let selected = try profileLoader.loadEditableSettings()
            let profiles = try profileLoader.loadAllProfileSettings()
            syncRuntimes(with: profiles)
            selectedProfileID = profiles.contains { $0.id == selected.id } ? selected.id : nil
            updateSelectedProfileDisplay()
        } catch {
            appendEvent("Profile load failed: \(userFacing(error))")
            statusMenuItem.title = "Status: failed"
        }
    }

    private func syncRuntimes(with profiles: [VPNProfileSettings]) {
        let ids = Set(profiles.map(\.id))
        for settings in profiles {
            if let runtime = runtimes[settings.id] {
                runtime.settings = settings
            } else {
                runtimes[settings.id] = ProfileRuntime(settings: settings)
            }
        }

        for (id, runtime) in runtimes where !ids.contains(id) && runtime.session == nil {
            runtimes.removeValue(forKey: id)
        }
    }

    private func updateSelectedProfileDisplay() {
        profileItem.title = "Profiles: \(runtimes.count)"

        let activeProfiles = runtimes.values
            .filter { $0.state.isActiveConnection }
            .map { "\($0.settings.displayName) \($0.settings.socksPort)" }
            .sorted()
        activeProfilesItem.title = activeProfiles.isEmpty
            ? "Active ports: none"
            : "Active ports: \(activeProfiles.joined(separator: ", "))"
    }

    @objc private func addProfileClicked() {
        showAddProfile()
    }

    @objc private func resetAllDataClicked() {
        showResetAllDataConfirmation()
    }

    @objc private func settingsProfileClicked(_ sender: NSMenuItem) {
        guard let profileID = profileID(from: sender) else { return }
        showSettings(profileID: profileID)
    }

    @objc private func toggleProfileClicked(_ sender: NSMenuItem) {
        guard let profileID = profileID(from: sender),
              let runtime = runtimes[profileID] else {
            return
        }

        if runtime.state.canConnect {
            Task { await connect(profileID: profileID) }
        } else if runtime.state.canDisconnect {
            Task { await disconnect(profileID: profileID) }
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    private func connect(profileID: VPNProfileID, serverPinRetryBudget: Int = 1) async {
        guard let runtime = runtimes[profileID] else {
            return
        }

        guard runtime.state.canConnect else {
            return
        }

        do {
            let loadedProfile = try runtime.loadedProfile ?? profileLoader.load(profileID: profileID)
            runtime.loadedProfile = loadedProfile

            let session = OpenConnectSession(
                runtimePaths: runtimePaths(),
                endpointRegistry: endpointRegistry,
                configuration: OpenConnectSessionConfiguration(startupTimeoutNanoseconds: 45_000_000_000)
            )
            runtime.session = session

            let secrets = [
                loadedProfile.credentials.password,
                loadedProfile.profile.serverCertificatePin
            ].compactMap { $0 }

            setState(.connecting, for: profileID)
            appendEvent(profileID: profileID, "Connecting")

            let started = try await session.start(
                profile: loadedProfile.profile,
                credentials: loadedProfile.credentials,
                redactor: Redactor(literalSecrets: secrets)
            )

            runtime.settings = VPNProfileSettings(
                id: loadedProfile.profile.id,
                displayName: loadedProfile.profile.displayName,
                server: loadedProfile.profile.server,
                username: loadedProfile.profile.username,
                authGroup: loadedProfile.profile.authGroup,
                socksHost: started.socksEndpoint.host,
                socksPort: started.socksEndpoint.port,
                autoStartOnLaunch: runtime.settings.autoStartOnLaunch
            )
            setState(.connected, for: profileID)
            appendEvent(profileID: profileID, "Connected")
            await persistRuntimeRegistryEntry(
                profileID: profileID,
                session: session,
                socksPort: started.socksEndpoint.port
            )
            observe(started.events, profileID: profileID)
        } catch {
            if serverPinRetryBudget > 0,
               let pin = await runtime.session?.serverCertificatePinSuggestion() {
                await runtime.session?.stop()
                runtime.session = nil

                do {
                    try profileLoader.saveServerCertificatePin(pin, for: profileID)
                    runtime.loadedProfile = nil
                    setState(.connecting, for: profileID)
                    appendEvent(profileID: profileID, "Server pin saved; retrying")
                    await connect(profileID: profileID, serverPinRetryBudget: serverPinRetryBudget - 1)
                    return
                } catch {
                    setState(.failed(message: userFacing(error)), for: profileID)
                    appendEvent(profileID: profileID, "Server pin save failed: \(userFacing(error))")
                    return
                }
            }

            setState(.failed(message: userFacing(error)), for: profileID)
            appendEvent(profileID: profileID, "Connect failed: \(userFacing(error))")
            await runtime.session?.stop()
            runtime.session = nil
            try? runtimeRecoveryRegistry.remove(profileID: profileID)
        }
    }

    private func disconnect(profileID: VPNProfileID) async {
        guard let runtime = runtimes[profileID] else {
            return
        }

        runtime.eventsTask?.cancel()
        runtime.eventsTask = nil
        appendEvent(profileID: profileID, "Disconnect requested")

        if let session = runtime.session {
            setState(.disconnecting, for: profileID)
            await session.stop()
        }
        if let recoveredRuntime = runtime.recoveredRuntime {
            setState(.disconnecting, for: profileID)
            await stopRecoveredRuntime(recoveredRuntime)
        }

        runtime.session = nil
        runtime.recoveredRuntime = nil
        try? runtimeRecoveryRegistry.remove(profileID: profileID)
        setState(.stopped, for: profileID)
        appendEvent(profileID: profileID, "Disconnected")
    }

    private func reconnect(profileID: VPNProfileID) async {
        await disconnect(profileID: profileID)
        await connect(profileID: profileID)
    }

    private func recoverRuntimeRegistry() async {
        let document = runtimeRecoveryRegistry.load()
        guard !document.entries.isEmpty else {
            return
        }

        var retainedEntries: [RuntimeRecoveryEntry] = []
        for entry in document.entries {
            guard let runtime = runtimes[entry.profileID] else {
                await cleanupRegisteredRuntime(entry)
                continue
            }

            guard runtime.session == nil,
                  runtime.recoveredRuntime == nil,
                  runtime.settings.socksPort == entry.socksPort,
                  processExists(entry.openConnectProcessIdentifier),
                  entry.ocproxyProcessIdentifier.map(processExists) ?? true,
                  let endpoint = try? SocksEndpoint(host: runtime.settings.socksHost, port: entry.socksPort),
                  await SocksHealthCheck(connectTimeoutMilliseconds: 200).isListening(endpoint: endpoint)
            else {
                await cleanupRegisteredRuntime(entry)
                continue
            }

            let recoveredRuntime = RecoveredRuntime(
                openConnectProcessIdentifier: entry.openConnectProcessIdentifier,
                ocproxyProcessIdentifier: entry.ocproxyProcessIdentifier,
                socksPort: entry.socksPort
            )
            runtime.recoveredRuntime = recoveredRuntime
            runtime.state = .connected
            retainedEntries.append(entry)
            appendEvent(profileID: entry.profileID, "Recovered existing runtime")
        }

        if retainedEntries.isEmpty {
            try? runtimeRecoveryRegistry.removeAll()
        } else {
            try? runtimeRecoveryRegistry.save(RuntimeRecoveryDocument(entries: retainedEntries))
        }
        updateAggregateUI()
    }

    private func persistRuntimeRegistryEntry(
        profileID: VPNProfileID,
        session: OpenConnectSession,
        socksPort: Int
    ) async {
        let snapshot = await session.runtimeSnapshot()
        guard let openConnectProcessIdentifier = snapshot.openConnectProcessIdentifier else {
            return
        }

        let port = snapshot.activeEndpoint?.port ?? socksPort
        let entry = RuntimeRecoveryEntry(
            profileID: profileID,
            socksPort: port,
            openConnectProcessIdentifier: openConnectProcessIdentifier,
            ocproxyProcessIdentifier: snapshot.ocproxyProcessIdentifier,
            updatedAt: Date()
        )
        try? runtimeRecoveryRegistry.upsert(entry)
    }

    private func cleanupRegisteredRuntime(_ entry: RuntimeRecoveryEntry) async {
        await stopProcessIdentifiers([
            entry.openConnectProcessIdentifier,
            entry.ocproxyProcessIdentifier
        ].compactMap { $0 })
    }

    private func stopRecoveredRuntime(_ runtime: RecoveredRuntime) async {
        await stopProcessIdentifiers([
            runtime.openConnectProcessIdentifier,
            runtime.ocproxyProcessIdentifier
        ].compactMap { $0 })
    }

    private func stopProcessIdentifiers(_ processIdentifiers: [Int32]) async {
        let uniqueIdentifiers = Array(Set(processIdentifiers.filter { $0 > 0 }))
        guard !uniqueIdentifiers.isEmpty else {
            return
        }

        for processIdentifier in uniqueIdentifiers where processExists(processIdentifier) {
            Darwin.kill(pid_t(processIdentifier), SIGTERM)
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        for processIdentifier in uniqueIdentifiers where processExists(processIdentifier) {
            Darwin.kill(pid_t(processIdentifier), SIGKILL)
        }
    }

    private func processExists(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else {
            return false
        }

        let result = Darwin.kill(pid_t(processIdentifier), 0)
        return result == 0 || errno == EPERM
    }

    private func shutdownAllSessions() async {
        pulseTimer?.invalidate()
        pulseTimer = nil

        for runtime in runtimes.values {
            runtime.eventsTask?.cancel()
            runtime.eventsTask = nil
        }

        let sessions = runtimes.values.compactMap(\.session)
        for session in sessions {
            await session.stop()
        }

        let recoveredRuntimes = runtimes.values.compactMap(\.recoveredRuntime)
        for recoveredRuntime in recoveredRuntimes {
            await stopRecoveredRuntime(recoveredRuntime)
        }

        for runtime in runtimes.values {
            runtime.session = nil
            runtime.recoveredRuntime = nil
            runtime.state = .stopped
        }
        try? runtimeRecoveryRegistry.removeAll()
        updateAggregateUI()
    }

    private func observe(_ events: AsyncStream<OpenConnectProcessEvent>, profileID: VPNProfileID) {
        guard let runtime = runtimes[profileID] else {
            return
        }

        runtime.eventsTask?.cancel()
        runtime.eventsTask = Task { [weak self] in
            guard let self else { return }

            for await event in events {
                self.handle(event, profileID: profileID)
            }
        }
    }

    private func handle(_ event: OpenConnectProcessEvent, profileID: VPNProfileID) {
        guard let runtime = runtimes[profileID] else {
            return
        }

        switch event {
        case .started:
            appendEvent(profileID: profileID, "Process started")
        case .output:
            break
        case .serverCertificatePinSuggested:
            appendEvent(profileID: profileID, "Server pin received")
        case .stateChanged(let state):
            setState(sanitizedStateForDisplay(state), for: profileID)
        case .exited(let status):
            try? runtimeRecoveryRegistry.remove(profileID: profileID)
            runtime.recoveredRuntime = nil
            if status == 0 || status == 15 {
                setState(.stopped, for: profileID)
                appendEvent(profileID: profileID, "Process exited")
            } else {
                setState(.failed(message: "Process exited with status \(status)"), for: profileID)
                appendEvent(profileID: profileID, "Process exited with status \(status)")
            }
            runtime.session = nil
        }
    }

    private func setState(_ state: ConnectionState, for profileID: VPNProfileID) {
        runtimes[profileID]?.state = state
        updateAggregateUI()
    }

    private func updateAggregateUI() {
        let aggregateState = aggregateState()
        statusMenuItem.title = "Status: \(statusSummary())"

        renderProfileActionsMenu()
        renderSettingsProfilesMenu()
        updateStatusIcon(for: aggregateState)
        updateSelectedProfileDisplay()
    }

    private func updateStatusIcon(for state: ConnectionState) {
        pulseTimer?.invalidate()
        pulseTimer = nil

        guard let button = statusItem.button else {
            return
        }

        switch state {
        case .stopped, .disconnecting:
            button.contentTintColor = .systemGray
        case .connecting, .authenticating, .reconnecting:
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.togglePulse() }
            }
            togglePulse()
        case .connected:
            button.contentTintColor = .systemGreen
        case .failed:
            button.contentTintColor = .systemRed
        }
    }

    private func aggregateState() -> ConnectionState {
        let states = runtimes.values.map(\.state)
        if let failed = states.first(where: { if case .failed = $0 { true } else { false } }) {
            return failed
        }
        if states.contains(where: \.isConnectingLike) {
            return .connecting
        }
        if states.contains(.connected) {
            return .connected
        }
        if states.contains(.disconnecting) {
            return .disconnecting
        }
        return .stopped
    }

    private func statusSummary() -> String {
        let states = runtimes.values.map(\.state)
        let connected = states.filter { $0 == .connected }.count
        let active = states.filter(\.isRunning).count
        let failed = states.filter { if case .failed = $0 { true } else { false } }.count
        let total = runtimes.count

        if failed > 0 {
            return "\(failed) failed / \(total) profiles"
        }
        if active > 0 {
            return "\(connected) connected / \(total) profiles"
        }
        return "stopped / \(total) profiles"
    }

    private func togglePulse() {
        pulseOn.toggle()
        statusItem.button?.contentTintColor = pulseOn ? .systemGreen : .systemGray
    }

    private func appendEvent(profileID: VPNProfileID? = nil, _ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let prefix = profileID.flatMap { runtimes[$0]?.settings.displayName }.map { "[\($0)] " } ?? ""
        recentEvents.append(prefix + trimmed)
        if recentEvents.count > 10 {
            recentEvents.removeFirst(recentEvents.count - 10)
        }

        renderRecentEventsMenu()
    }

    private func renderRecentEventsMenu() {
        for item in recentEventItems {
            menu.removeItem(item)
        }
        recentEventItems.removeAll()

        guard let headerIndex = menu.items.firstIndex(of: recentHeaderItem) else {
            return
        }

        let lines = recentMenuLines()
        for (offset, line) in lines.enumerated() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentEventItems.append(item)
            menu.insertItem(item, at: headerIndex + 1 + offset)
        }
    }

    private func renderProfileActionsMenu() {
        for item in profileActionItems {
            menu.removeItem(item)
        }
        profileActionItems.removeAll()

        guard let headerIndex = menu.items.firstIndex(of: connectionsHeaderItem) else {
            return
        }

        let profiles = runtimes.values
            .map(\.settings)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        for (offset, profile) in profiles.enumerated() {
            guard let runtime = runtimes[profile.id] else {
                continue
            }

            let item = NSMenuItem(
                title: profileActionTitle(profile, state: runtime.state),
                action: #selector(toggleProfileClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id.rawValue
            item.state = runtime.state.isActiveConnection ? .on : .off
            item.isEnabled = runtime.state.canConnect || runtime.state.canDisconnect
            profileActionItems.append(item)
            menu.insertItem(item, at: headerIndex + 1 + offset)
        }
    }

    private func renderSettingsProfilesMenu() {
        for item in settingsProfileItems {
            menu.removeItem(item)
        }
        settingsProfileItems.removeAll()

        guard let headerIndex = menu.items.firstIndex(of: settingsProfilesHeaderItem) else {
            return
        }

        let profiles = runtimes.values
            .map(\.settings)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        for (offset, profile) in profiles.enumerated() {
            let item = NSMenuItem(
                title: "\(profile.displayName)  port \(profile.socksPort)",
                action: #selector(settingsProfileClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id.rawValue
            item.state = .off
            settingsProfileItems.append(item)
            menu.insertItem(item, at: headerIndex + 1 + offset)
        }
    }

    private func profileActionTitle(_ profile: VPNProfileSettings, state: ConnectionState) -> String {
        let action = if state.canConnect {
            "Connect"
        } else if state.canDisconnect {
            "Disconnect"
        } else {
            "Wait"
        }

        return "\(action) \(profile.displayName)  \(state.shortLabel)  port \(profile.socksPort)"
    }

    private func recentMenuLines() -> [String] {
        guard !recentEvents.isEmpty else {
            return ["  none"]
        }

        return recentEvents
            .suffix(5)
            .reversed()
            .flatMap { event in
                event.wrappedForMenu(maxLineLength: 72).enumerated().map { offset, line in
                    offset == 0 ? "  - \(line)" : "    \(line)"
                }
            }
    }

    private func showSettings(profileID: VPNProfileID) {
        let settings: VPNProfileSettings
        do {
            settings = try profileLoader.selectProfile(id: profileID)
            selectedProfileID = settings.id
        } catch {
            showErrorAlert(message: userFacing(error))
            return
        }

        let serverField = NSTextField(string: settings.server)
        let usernameField = NSTextField(string: settings.username)
        let portField = NSTextField(string: String(settings.socksPort))
        let passwordSecureField = NSSecureTextField(string: "")
        let passwordTextField = NSTextField(string: "")
        let revealPasswordButton = NSButton(title: "Show", target: nil, action: nil)
        let autoStartButton = NSButton(checkboxWithTitle: "On app launch", target: nil, action: nil)
        let unsafeStorageButton = NSButton(checkboxWithTitle: "Store without Touch ID (unsafe)", target: nil, action: nil)
        let testButton = NSButton(title: "Test", target: nil, action: nil)
        let testStatusLabel = NSTextField(labelWithString: "Not tested")
        let routeImportButton = NSButton(title: "Fetch", target: nil, action: nil)
        let routeImportStatusLabel = NSTextField(labelWithString: "Ready")
        passwordSecureField.placeholderString = "Leave unchanged"
        passwordTextField.placeholderString = "Leave unchanged"
        passwordTextField.isHidden = true
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.lineBreakMode = .byTruncatingTail
        routeImportStatusLabel.textColor = .secondaryLabelColor
        routeImportStatusLabel.lineBreakMode = .byTruncatingTail
        autoStartButton.state = settings.autoStartOnLaunch ? .on : .off
        unsafeStorageButton.state = settings.credentialStorageMode == .unsafeLocal ? .on : .off

        [serverField, usernameField, portField, passwordSecureField, passwordTextField].forEach { field in
            field.frame.size = NSSize(width: 320, height: 24)
        }
        autoStartButton.frame.size = NSSize(width: 320, height: 24)
        unsafeStorageButton.frame.size = NSSize(width: 320, height: 24)

        var isPasswordRevealed = false
        var unsafeStorageWarningAccepted = settings.credentialStorageMode == .unsafeLocal
        let unsafeStorageTarget = ClosureButtonTarget { [weak self, weak unsafeStorageButton] in
            guard let self, let unsafeStorageButton else {
                return
            }

            guard unsafeStorageButton.state == .on else {
                unsafeStorageWarningAccepted = settings.credentialStorageMode == .unsafeLocal
                return
            }

            if self.confirmUnsafeCredentialStorage() {
                unsafeStorageWarningAccepted = true
            } else {
                unsafeStorageButton.state = .off
                unsafeStorageWarningAccepted = false
            }
        }

        let revealTarget = ClosureButtonTarget { [weak self, weak passwordSecureField, weak passwordTextField, weak revealPasswordButton] in
            Task { @MainActor in
                guard let self, let passwordSecureField, let passwordTextField, let revealPasswordButton else {
                    return
                }

                if isPasswordRevealed {
                    passwordSecureField.stringValue = passwordTextField.stringValue
                    passwordTextField.isHidden = true
                    passwordSecureField.isHidden = false
                    revealPasswordButton.title = "Show"
                    isPasswordRevealed = false
                    return
                }

                do {
                    let password = try self.profileLoader.selectedProfilePassword()
                    passwordTextField.stringValue = password
                    passwordSecureField.stringValue = password
                    passwordSecureField.isHidden = true
                    passwordTextField.isHidden = false
                    revealPasswordButton.title = "Hide"
                    isPasswordRevealed = true
                } catch {
                    if case CredentialStoreError.credentialVaultLocked = error {
                        return
                    }
                    self.showErrorAlert(message: self.userFacing(error))
                }
            }
        }

        let testTarget = ClosureButtonTarget { [
            weak self,
            weak serverField,
            weak usernameField,
            weak portField,
            weak passwordSecureField,
            weak passwordTextField,
            weak testButton,
            weak testStatusLabel
        ] in
            Task { @MainActor in
                guard let self,
                      let serverField,
                      let usernameField,
                      let portField,
                      let passwordSecureField,
                      let passwordTextField,
                      let testButton,
                      let testStatusLabel
                else {
                    return
                }

                testButton.isEnabled = false
                testStatusLabel.textColor = .secondaryLabelColor
                testStatusLabel.stringValue = "Testing..."
                testStatusLabel.toolTip = nil

                do {
                    let report = try await self.testProfileSettings(
                        baseSettings: settings,
                        server: serverField.stringValue,
                        username: usernameField.stringValue,
                        portText: portField.stringValue,
                        passwordOverride: self.passwordOverride(
                            isRevealed: isPasswordRevealed,
                            secureField: passwordSecureField,
                            textField: passwordTextField
                        )
                    )
                    testStatusLabel.textColor = .systemGreen
                    testStatusLabel.stringValue = report.shortMessage
                    testStatusLabel.toolTip = report.detailMessage
                    self.appendEvent(profileID: settings.id, "Test OK: \(report.eventMessage)")
                } catch {
                    let message = self.userFacing(error)
                    let display = self.testFailureDisplay(for: error)
                    testStatusLabel.textColor = .systemRed
                    testStatusLabel.stringValue = display.shortMessage
                    testStatusLabel.toolTip = message
                    self.appendEvent(profileID: settings.id, "Test failed: \(message)")
                }

                testButton.isEnabled = true
            }
        }

        let routeImportTarget = ClosureButtonTarget { [
            weak self,
            weak serverField,
            weak usernameField,
            weak portField,
            weak passwordSecureField,
            weak passwordTextField,
            weak routeImportButton,
            weak routeImportStatusLabel
        ] in
            Task { @MainActor in
                guard let self,
                      let serverField,
                      let usernameField,
                      let portField,
                      let passwordSecureField,
                      let passwordTextField,
                      let routeImportButton,
                      let routeImportStatusLabel
                else {
                    return
                }

                routeImportButton.isEnabled = false
                routeImportStatusLabel.textColor = .secondaryLabelColor
                routeImportStatusLabel.stringValue = "Fetching..."
                routeImportStatusLabel.toolTip = nil

                do {
                    let snapshot = try await self.fetchRouteImportSettings(
                        baseSettings: settings,
                        server: serverField.stringValue,
                        username: usernameField.stringValue,
                        portText: portField.stringValue,
                        passwordOverride: self.passwordOverride(
                            isRevealed: isPasswordRevealed,
                            secureField: passwordSecureField,
                            textField: passwordTextField
                        )
                    )
                    routeImportStatusLabel.textColor = snapshot.isEmpty ? .secondaryLabelColor : .systemGreen
                    routeImportStatusLabel.stringValue = snapshot.isEmpty ? "No routes" : "\(snapshot.routeCount) routes"
                    routeImportStatusLabel.toolTip = nil
                    self.appendEvent(profileID: settings.id, snapshot.isEmpty ? "Route import empty" : "Route import fetched")
                    self.showRouteImport(snapshot, profileName: settings.displayName)
                } catch {
                    let message = self.userFacing(error)
                    routeImportStatusLabel.textColor = .systemRed
                    routeImportStatusLabel.stringValue = message.truncatedForStatus
                    routeImportStatusLabel.toolTip = message
                    self.appendEvent(profileID: settings.id, "Route import failed: \(message)")
                }

                routeImportButton.isEnabled = true
            }
        }
        unsafeStorageButton.target = unsafeStorageTarget
        unsafeStorageButton.action = #selector(ClosureButtonTarget.run)
        revealPasswordButton.target = revealTarget
        revealPasswordButton.action = #selector(ClosureButtonTarget.run)
        testButton.target = testTarget
        testButton.action = #selector(ClosureButtonTarget.run)
        routeImportButton.target = routeImportTarget
        routeImportButton.action = #selector(ClosureButtonTarget.run)
        retainedButtonTargets.append(unsafeStorageTarget)
        retainedButtonTargets.append(revealTarget)
        retainedButtonTargets.append(testTarget)
        retainedButtonTargets.append(routeImportTarget)
        defer {
            retainedButtonTargets.removeAll { $0 === unsafeStorageTarget }
            retainedButtonTargets.removeAll { $0 === revealTarget }
            retainedButtonTargets.removeAll { $0 === testTarget }
            retainedButtonTargets.removeAll { $0 === routeImportTarget }
        }

        let alert = NSAlert()
        alert.messageText = "VPN Settings"
        alert.icon = makeStatusImage()
        alert.addButton(withTitle: "Save")
        let deleteButton = alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        deleteButton.isEnabled = runtimes[settings.id]?.state.canDeleteProfile ?? true
        alert.accessoryView = makeSettingsView(
            serverField: serverField,
            usernameField: usernameField,
            portField: portField,
            autoStartButton: autoStartButton,
            unsafeStorageButton: unsafeStorageButton,
            passwordRow: makePasswordRow(
                secureField: passwordSecureField,
                textField: passwordTextField,
                revealButton: revealPasswordButton
            ),
            testRow: makeTestRow(
                button: testButton,
                statusLabel: testStatusLabel
            ),
            routeImportRow: makeTestRow(
                button: routeImportButton,
                statusLabel: routeImportStatusLabel
            )
        )

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            confirmDeleteProfile(settings)
            return
        }
        guard response == .alertFirstButtonReturn else {
            return
        }

        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText) else {
            showErrorAlert(message: "Invalid SOCKS port: \(portText)")
            return
        }

        do {
            let passwordValue = isPasswordRevealed ? passwordTextField.stringValue : passwordSecureField.stringValue
            let normalizedServer = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let passwordChanged = !passwordValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let requestedStorageMode: CredentialStorageMode = unsafeStorageButton.state == .on ? .unsafeLocal : .touchIDVault
            let enablesUnsafeStorage = settings.credentialStorageMode != .unsafeLocal && requestedStorageMode == .unsafeLocal
            if enablesUnsafeStorage, !unsafeStorageWarningAccepted, !confirmUnsafeCredentialStorage() {
                return
            }
            let requiresReconnect = settings.server != normalizedServer
                || settings.username != normalizedUsername
                || settings.socksPort != port
                || passwordChanged

            guard let updated = try saveProfileSettingsWithPasswordFallback(
                currentSettings: settings,
                server: serverField.stringValue,
                username: usernameField.stringValue,
                socksPort: port,
                password: passwordValue,
                autoStartOnLaunch: autoStartButton.state == .on,
                credentialStorageMode: requestedStorageMode
            ) else {
                return
            }
            selectedProfileID = updated.id
            if let runtime = runtimes[updated.id] {
                runtime.settings = updated
                runtime.loadedProfile = nil
            } else {
                runtimes[updated.id] = ProfileRuntime(settings: updated)
            }
            appendEvent(profileID: updated.id, "Settings saved")

            if requiresReconnect, runtimes[updated.id]?.state.isRunning == true {
                appendEvent(profileID: updated.id, "Reconnecting with updated settings")
                Task { await reconnect(profileID: updated.id) }
            }
            updateAggregateUI()
        } catch {
            showErrorAlert(message: userFacing(error))
            appendEvent("Settings failed: \(userFacing(error))")
        }
    }

    private func showAddProfile() {
        let nameField = NSTextField(string: "")
        let serverField = NSTextField(string: "")
        let usernameField = NSTextField(string: "")
        let authGroupField = NSTextField(string: "")
        let portField = NSTextField(string: String(nextAvailableSocksPort()))
        let passwordField = NSSecureTextField(string: "")
        let unsafeStorageButton = NSButton(checkboxWithTitle: "Store without Touch ID (unsafe)", target: nil, action: nil)

        nameField.placeholderString = "profile name"
        serverField.placeholderString = "required"
        usernameField.placeholderString = "login"
        authGroupField.placeholderString = "optional"
        passwordField.placeholderString = "required"

        [nameField, serverField, usernameField, authGroupField, portField, passwordField].forEach { field in
            field.frame.size = NSSize(width: 320, height: 24)
        }
        unsafeStorageButton.frame.size = NSSize(width: 320, height: 24)

        var unsafeStorageWarningAccepted = false
        let unsafeStorageTarget = ClosureButtonTarget { [weak self, weak unsafeStorageButton] in
            guard let self, let unsafeStorageButton else {
                return
            }

            guard unsafeStorageButton.state == .on else {
                unsafeStorageWarningAccepted = false
                return
            }

            if self.confirmUnsafeCredentialStorage() {
                unsafeStorageWarningAccepted = true
            } else {
                unsafeStorageButton.state = .off
                unsafeStorageWarningAccepted = false
            }
        }
        unsafeStorageButton.target = unsafeStorageTarget
        unsafeStorageButton.action = #selector(ClosureButtonTarget.run)
        retainedButtonTargets.append(unsafeStorageTarget)
        defer {
            retainedButtonTargets.removeAll { $0 === unsafeStorageTarget }
        }

        let alert = NSAlert()
        alert.messageText = "Add VPN Profile"
        alert.icon = makeStatusImage()
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = makeFormView(rows: [
            ("Name", nameField),
            ("Server", serverField),
            ("Login", usernameField),
            ("Auth Group", authGroupField),
            ("SOCKS Port", portField),
            ("Password", passwordField),
            ("Storage", unsafeStorageButton)
        ])

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText) else {
            showErrorAlert(message: "Invalid SOCKS port: \(portText)")
            return
        }

        do {
            let credentialStorageMode: CredentialStorageMode = unsafeStorageButton.state == .on ? .unsafeLocal : .touchIDVault
            if credentialStorageMode == .unsafeLocal, !unsafeStorageWarningAccepted, !confirmUnsafeCredentialStorage() {
                return
            }
            let created = try profileLoader.createProfileSettings(
                displayName: nameField.stringValue,
                server: serverField.stringValue,
                username: usernameField.stringValue,
                authGroup: authGroupField.stringValue,
                socksPort: port,
                password: passwordField.stringValue,
                credentialStorageMode: credentialStorageMode
            )
            selectedProfileID = created.id
            syncRuntimes(with: try profileLoader.loadAllProfileSettings())
            updateAggregateUI()
            appendEvent(profileID: created.id, "Profile added")
        } catch {
            showErrorAlert(message: userFacing(error))
            appendEvent("Add profile failed: \(userFacing(error))")
        }
    }

    private func saveProfileSettingsWithPasswordFallback(
        currentSettings: VPNProfileSettings,
        server: String,
        username: String,
        socksPort: Int,
        password: String,
        autoStartOnLaunch: Bool,
        credentialStorageMode: CredentialStorageMode
    ) throws -> VPNProfileSettings? {
        do {
            return try profileLoader.saveProfileSettings(
                server: server,
                username: username,
                socksPort: socksPort,
                password: password,
                autoStartOnLaunch: autoStartOnLaunch,
                credentialStorageMode: credentialStorageMode
            )
        } catch CredentialStoreError.credentialVaultLocked
            where credentialStorageMode == .unsafeLocal
                && currentSettings.credentialStorageMode != .unsafeLocal
                && password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let replacementPassword = promptPasswordForUnsafeStorage(profileName: currentSettings.displayName) else {
                return nil
            }

            return try profileLoader.saveProfileSettings(
                server: server,
                username: username,
                socksPort: socksPort,
                password: replacementPassword,
                autoStartOnLaunch: autoStartOnLaunch,
                credentialStorageMode: credentialStorageMode
            )
        }
    }

    private func confirmUnsafeCredentialStorage() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Use unsafe credential storage?"
        alert.informativeText = "This stores VPN credentials without Touch ID protection. Anyone with access to your macOS user account or app data may be able to use this profile. Use only if you accept the risk."
        alert.addButton(withTitle: "Use Unsafe Storage")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func promptPasswordForUnsafeStorage(profileName: String) -> String? {
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "VPN password"
        passwordField.frame.size = NSSize(width: 320, height: 24)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Enter VPN Password"
        alert.informativeText = "Touch ID was cancelled or unavailable. Enter the VPN password to save this profile without Touch ID."
        alert.accessoryView = makeFormView(rows: [
            ("Password", passwordField)
        ])
        alert.addButton(withTitle: "Save Unsafe")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let password = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            showErrorAlert(message: "VPN password is required.")
            return nil
        }
        appendEvent("Unsafe password entered for \(profileName)")
        return passwordField.stringValue
    }

    private func confirmDeleteProfile(_ settings: VPNProfileSettings) {
        guard runtimes[settings.id]?.state.canDeleteProfile ?? true else {
            showErrorAlert(message: "Disconnect this profile before deleting it.")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(settings.displayName)?"
        alert.informativeText = "This removes the profile settings and saved credentials for this profile."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            let document = try profileLoader.deleteProfile(id: settings.id)
            runtimes.removeValue(forKey: settings.id)
            try? runtimeRecoveryRegistry.remove(profileID: settings.id)
            syncRuntimes(with: document.profiles)
            self.selectedProfileID = document.selectedProfile?.id
            updateAggregateUI()
            appendEvent("Deleted profile \(settings.displayName)")
        } catch {
            showErrorAlert(message: userFacing(error))
            appendEvent("Delete profile failed: \(userFacing(error))")
        }
    }

    private func showResetAllDataConfirmation() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset All Data?"
        alert.informativeText = "This disconnects all profiles, deletes all profile settings, and removes the Touch ID credential vault, unsafe local credentials, and old AnyConnectClient Keychain items."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task { await resetAllData() }
    }

    private func resetAllData() async {
        for profileID in Array(runtimes.keys) {
            await disconnect(profileID: profileID)
        }

        do {
            try profileLoader.resetAllData()
            try? runtimeRecoveryRegistry.removeAll()
            runtimes.removeAll()
            selectedProfileID = nil
            updateAggregateUI()
            appendEvent("Reset all data")
        } catch {
            showErrorAlert(message: userFacing(error))
            appendEvent("Reset failed: \(userFacing(error))")
        }
    }

    private func makeStatusImage() -> NSImage {
        if let image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "AnyConnectClient") {
            return image
        }
        return NSImage(systemSymbolName: "network", accessibilityDescription: "AnyConnectClient")
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }

    private func runtimePaths() -> RuntimePaths {
        let fileManager = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let bundledOpenConnect = resourceURL.appendingPathComponent("openconnect").path
            let bundledOcproxy = resourceURL.appendingPathComponent("ocproxy").path
            if fileManager.isExecutableFile(atPath: bundledOpenConnect),
               fileManager.isExecutableFile(atPath: bundledOcproxy) {
                return RuntimePaths(
                    openConnectExecutablePath: bundledOpenConnect,
                    ocproxyExecutablePath: bundledOcproxy
                )
            }
        }

        let packageRoot = fileManager.currentDirectoryPath
        return RuntimePaths(
            openConnectExecutablePath: "\(packageRoot)/ThirdParty/openconnect-9.21/openconnect",
            ocproxyExecutablePath: "\(packageRoot)/ThirdParty/ocproxy/ocproxy"
        )
    }

    private func makeOpenConnectSession() -> OpenConnectSession {
        OpenConnectSession(
            runtimePaths: runtimePaths(),
            endpointRegistry: endpointRegistry,
            configuration: OpenConnectSessionConfiguration(startupTimeoutNanoseconds: 25_000_000_000)
        )
    }

    private func profileID(from item: NSMenuItem) -> VPNProfileID? {
        guard let raw = item.representedObject as? String else {
            return nil
        }
        return VPNProfileID(rawValue: raw)
    }

    private func nextAvailableSocksPort() -> Int {
        let usedPorts = Set(runtimes.values.map(\.settings.socksPort))
        var port = (usedPorts.max() ?? 11083) + 1
        while usedPorts.contains(port) {
            port += 1
        }
        return port
    }

    private func userFacing(_ error: Error) -> String {
        switch error {
        case VPNConnectionError.authenticationFailed:
            return "Authentication failed. Check login, password, and auth group."
        case VPNConnectionError.serverCertificateChanged:
            return "Server certificate pin was rejected."
        case VPNConnectionError.socksPortUnavailable:
            return "SOCKS port is already in use."
        case VPNConnectionError.socksReadinessTimedOut:
            return "SOCKS did not become ready."
        case VPNConnectionError.vpnReadinessTimedOut:
            return "VPN tunnel did not become ready."
        case VPNConnectionError.processExited(let status):
            return "OpenConnect exited with status \(status)."
        case ProfileSettingsStoreError.duplicateSocksEndpoint(let endpoint):
            return "SOCKS port \(endpoint.port) is already used by another profile. Choose another port."
        case CredentialStoreError.credentialVaultLocked:
            return "Credential vault is locked. Use Touch ID to unlock it once for this app session."
        default:
            break
        }

        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return sanitizedTextForDisplay(description)
        }
        return sanitizedTextForDisplay(String(describing: error))
    }

    private func sanitizedStateForDisplay(_ state: ConnectionState) -> ConnectionState {
        switch state {
        case .failed(let message):
            return .failed(message: sanitizedTextForDisplay(message))
        case .stopped, .connecting, .authenticating, .connected, .reconnecting, .disconnecting:
            return state
        }
    }

    private func sanitizedTextForDisplay(_ text: String) -> String {
        var output = text
        output = replacing(pattern: #"https?://[^\s]+"#, in: output, with: "<address>")
        output = replacing(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#, in: output, with: "<address>")
        output = replacing(pattern: #"\b[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+(?:\:\d{1,5})?\b"#, in: output, with: "<address>")
        return output
    }

    private func replacing(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private func testFailureDisplay(for error: Error) -> ProfileTestFailureDisplay {
        switch error {
        case VPNConnectionError.authenticationFailed:
            return ProfileTestFailureDisplay(shortMessage: "Auth failed")
        case VPNConnectionError.serverCertificateChanged:
            return ProfileTestFailureDisplay(shortMessage: "Pin rejected")
        case VPNConnectionError.socksPortUnavailable:
            return ProfileTestFailureDisplay(shortMessage: "Port busy")
        case VPNConnectionError.socksReadinessTimedOut:
            return ProfileTestFailureDisplay(shortMessage: "SOCKS timeout")
        case VPNConnectionError.vpnReadinessTimedOut:
            return ProfileTestFailureDisplay(shortMessage: "VPN timeout")
        case VPNConnectionError.processExited:
            return ProfileTestFailureDisplay(shortMessage: "VPN exited")
        case CredentialStoreError.missingPassword:
            return ProfileTestFailureDisplay(shortMessage: "No password")
        case CredentialStoreError.keychainInteractionRequired:
            return ProfileTestFailureDisplay(shortMessage: "Keychain locked")
        case CredentialStoreError.credentialVaultLocked:
            return ProfileTestFailureDisplay(shortMessage: "Vault locked")
        case ProfileConfigurationLoaderError.invalidPort:
            return ProfileTestFailureDisplay(shortMessage: "Bad port")
        case ProfileSettingsStoreError.duplicateSocksEndpoint:
            return ProfileTestFailureDisplay(shortMessage: "Port in use")
        default:
            let message = userFacing(error)
            if message.localizedCaseInsensitiveContains("authentication failed") {
                return ProfileTestFailureDisplay(shortMessage: "Auth failed")
            }
            if message.localizedCaseInsensitiveContains("password") {
                return ProfileTestFailureDisplay(shortMessage: "Password issue")
            }
            if message.localizedCaseInsensitiveContains("port") {
                return ProfileTestFailureDisplay(shortMessage: "Port issue")
            }
            if message.localizedCaseInsensitiveContains("timeout") {
                return ProfileTestFailureDisplay(shortMessage: "Timeout")
            }
            return ProfileTestFailureDisplay(shortMessage: message.truncatedForStatus)
        }
    }

    private func passwordOverride(
        isRevealed: Bool,
        secureField: NSSecureTextField,
        textField: NSTextField
    ) -> String? {
        let value = isRevealed ? textField.stringValue : secureField.stringValue
        return value.isEmpty ? nil : value
    }

    private func testProfileSettings(
        baseSettings: VPNProfileSettings,
        server: String,
        username: String,
        portText: String,
        passwordOverride: String?
    ) async throws -> ProfileTestReport {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProfileConfigurationLoaderError.invalidPort(portText)
        }

        let endpoint = try SocksEndpoint(host: baseSettings.socksHost, port: port)
        let allSettings = try profileLoader.loadAllProfileSettings()
        if allSettings.contains(where: { $0.id != baseSettings.id && $0.socksHost == endpoint.host && $0.socksPort == endpoint.port }) {
            throw ProfileSettingsStoreError.duplicateSocksEndpoint(endpoint)
        }

        let loadedProfile = try profileLoader.load(profileID: baseSettings.id)
        let password = passwordOverride ?? loadedProfile.credentials.password
        let profile = try VPNProfile(
            id: baseSettings.id,
            displayName: baseSettings.displayName,
            server: server,
            username: username,
            authGroup: baseSettings.authGroup,
            socksEndpoint: endpoint,
            serverCertificatePin: loadedProfile.profile.serverCertificatePin
        )
        let credentials = VPNCredentials(profileID: profile.id, password: password)
        let (session, _) = try await startTestSessionWithServerPinRetry(
            profile: profile,
            credentials: credentials
        )

        defer {
            Task { await session.stop() }
        }

        let report = ProfileTestReport(
            shortMessage: "OK",
            detailMessage: "VPN authenticated and SOCKS is ready.",
            eventMessage: "VPN authenticated, SOCKS ready"
        )
        await session.stop()
        return report
    }

    private func fetchRouteImportSettings(
        baseSettings: VPNProfileSettings,
        server: String,
        username: String,
        portText: String,
        passwordOverride: String?
    ) async throws -> RouteImportSnapshot {
        if let runtime = runtimes[baseSettings.id], let session = runtime.session, runtime.state.isActiveConnection {
            return await session.routeImportSnapshot()
        }
        if runtimes[baseSettings.id]?.recoveredRuntime != nil {
            throw RouteImportFetchError.reconnectRequired
        }

        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProfileConfigurationLoaderError.invalidPort(portText)
        }

        let endpoint = try SocksEndpoint(host: baseSettings.socksHost, port: port)
        let allSettings = try profileLoader.loadAllProfileSettings()
        if allSettings.contains(where: { $0.id != baseSettings.id && $0.socksHost == endpoint.host && $0.socksPort == endpoint.port }) {
            throw ProfileSettingsStoreError.duplicateSocksEndpoint(endpoint)
        }

        let loadedProfile = try profileLoader.load(profileID: baseSettings.id)
        let password = passwordOverride ?? loadedProfile.credentials.password
        let profile = try VPNProfile(
            id: baseSettings.id,
            displayName: baseSettings.displayName,
            server: server,
            username: username,
            authGroup: baseSettings.authGroup,
            socksEndpoint: endpoint,
            serverCertificatePin: loadedProfile.profile.serverCertificatePin
        )
        let credentials = VPNCredentials(profileID: profile.id, password: password)
        let (session, _) = try await startTestSessionWithServerPinRetry(
            profile: profile,
            credentials: credentials
        )

        let snapshot = await session.routeImportSnapshot()
        await session.stop()
        return snapshot
    }

    private func showRouteImport(_ snapshot: RouteImportSnapshot, profileName: String) {
        let text = snapshot.formattedText
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.messageText = "Route Import"
        alert.informativeText = "Profile: \(profileName)"
        alert.icon = makeStatusImage()
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func startTestSessionWithServerPinRetry(
        profile: VPNProfile,
        credentials: VPNCredentials
    ) async throws -> (OpenConnectSession, OpenConnectSessionStart) {
        let session = makeOpenConnectSession()
        let secrets = [
            credentials.password,
            profile.serverCertificatePin
        ].compactMap { $0 }

        do {
            let started = try await session.start(
                profile: profile,
                credentials: credentials,
                redactor: Redactor(literalSecrets: secrets)
            )
            return (session, started)
        } catch {
            guard let suggestedPin = await session.serverCertificatePinSuggestion() else {
                throw error
            }

            await session.stop()
            try profileLoader.saveServerCertificatePin(suggestedPin, for: profile.id)
            appendEvent(profileID: profile.id, "Server pin saved for test; retrying")

            let retriedSession = makeOpenConnectSession()
            let retriedProfile = try profile.replacingServerCertificatePin(suggestedPin)
            let retriedSecrets = [
                credentials.password,
                retriedProfile.serverCertificatePin
            ].compactMap { $0 }
            let started = try await retriedSession.start(
                profile: retriedProfile,
                credentials: credentials,
                redactor: Redactor(literalSecrets: retriedSecrets)
            )
            return (retriedSession, started)
        }
    }

    private func makeSettingsView(
        serverField: NSTextField,
        usernameField: NSTextField,
        portField: NSTextField,
        autoStartButton: NSButton,
        unsafeStorageButton: NSButton,
        passwordRow: NSView,
        testRow: NSView,
        routeImportRow: NSView
    ) -> NSView {
        makeFormView(rows: [
            ("Server", serverField),
            ("Login", usernameField),
            ("SOCKS Port", portField),
            ("Auto-start", autoStartButton),
            ("Storage", unsafeStorageButton),
            ("Password", passwordRow),
            ("Test", testRow),
            ("Routes", routeImportRow)
        ])
    }

    private func makeFormView(rows: [(String, NSView)]) -> NSView {
        let formWidth: CGFloat = 440
        let labelWidth: CGFloat = 92
        let fieldX: CGFloat = 108
        let fieldWidth: CGFloat = 320
        let rowHeight: CGFloat = 24
        let rowGap: CGFloat = 12
        let formHeight = rowHeight * CGFloat(rows.count) + rowGap * CGFloat(max(0, rows.count - 1))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: formWidth, height: formHeight))

        for (index, row) in rows.enumerated() {
            let y = formHeight - rowHeight - CGFloat(index) * (rowHeight + rowGap)
            let label = NSTextField(labelWithString: row.0)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: y + 2, width: labelWidth, height: 20)
            row.1.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: rowHeight)
            view.addSubview(label)
            view.addSubview(row.1)
        }

        return view
    }

    private func makePasswordRow(
        secureField: NSSecureTextField,
        textField: NSTextField,
        revealButton: NSButton
    ) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        secureField.frame = NSRect(x: 0, y: 0, width: 248, height: 24)
        textField.frame = secureField.frame
        revealButton.bezelStyle = .rounded
        revealButton.frame = NSRect(x: 258, y: -2, width: 62, height: 28)

        row.addSubview(secureField)
        row.addSubview(textField)
        row.addSubview(revealButton)
        return row
    }

    private func makeTestRow(
        button: NSButton,
        statusLabel: NSTextField
    ) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 0, y: -1, width: 72, height: 28)
        statusLabel.frame = NSRect(x: 84, y: 3, width: 236, height: 20)

        row.addSubview(button)
        row.addSubview(statusLabel)
        return row
    }

    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
private final class ProfileRuntime {
    var settings: VPNProfileSettings
    var loadedProfile: LoadedVPNProfile?
    var session: OpenConnectSession?
    var recoveredRuntime: RecoveredRuntime?
    var eventsTask: Task<Void, Never>?
    var state: ConnectionState = .stopped

    init(settings: VPNProfileSettings) {
        self.settings = settings
    }
}

private struct RecoveredRuntime: Equatable, Sendable {
    let openConnectProcessIdentifier: Int32
    let ocproxyProcessIdentifier: Int32?
    let socksPort: Int
}

@MainActor
private final class ClosureButtonTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

private struct ProfileTestReport: Sendable {
    let shortMessage: String
    let detailMessage: String
    let eventMessage: String
}

private struct ProfileTestFailureDisplay: Sendable {
    let shortMessage: String
}

private enum RouteImportFetchError: Error, LocalizedError {
    case reconnectRequired

    var errorDescription: String? {
        switch self {
        case .reconnectRequired:
            "Route import is unavailable for a recovered session. Reconnect this profile and try again."
        }
    }
}

private extension VPNProfile {
    func replacingServerCertificatePin(_ pin: String?) throws -> VPNProfile {
        try VPNProfile(
            id: id,
            displayName: displayName,
            vpnProtocol: vpnProtocol,
            server: server,
            username: username,
            authGroup: authGroup,
            socksEndpoint: socksEndpoint,
            serverCertificatePin: pin,
            reconnectPolicy: reconnectPolicy
        )
    }
}

private extension ConnectionState {
    var label: String {
        switch self {
        case .stopped:
            "stopped"
        case .connecting:
            "connecting"
        case .authenticating:
            "authenticating"
        case .connected:
            "connected"
        case .reconnecting(let attempt):
            attempt > 0 ? "reconnecting #\(attempt)" : "reconnecting"
        case .disconnecting:
            "disconnecting"
        case .failed(let message):
            "failed: \(message.truncatedForMenu)"
        }
    }

    var shortLabel: String {
        switch self {
        case .stopped:
            "stopped"
        case .connecting:
            "connecting"
        case .authenticating:
            "auth"
        case .connected:
            "connected"
        case .reconnecting:
            "reconnecting"
        case .disconnecting:
            "disconnecting"
        case .failed:
            "failed"
        }
    }

    var canConnect: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .connecting, .authenticating, .connected, .reconnecting, .disconnecting:
            false
        }
    }

    var canDisconnect: Bool {
        switch self {
        case .connecting, .authenticating, .connected, .reconnecting:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }

    var canReconnect: Bool {
        switch self {
        case .connected, .failed:
            true
        case .stopped, .connecting, .authenticating, .reconnecting, .disconnecting:
            false
        }
    }

    var isRunning: Bool {
        switch self {
        case .connecting, .authenticating, .connected, .reconnecting:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }

    var isConnectingLike: Bool {
        switch self {
        case .connecting, .authenticating, .reconnecting:
            true
        case .stopped, .connected, .disconnecting, .failed:
            false
        }
    }

    var isActiveConnection: Bool {
        switch self {
        case .connecting, .authenticating, .connected, .reconnecting:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }

    var canDeleteProfile: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .connecting, .authenticating, .connected, .reconnecting, .disconnecting:
            false
        }
    }
}

private extension String {
    var truncatedForMenu: String {
        guard count > 80 else {
            return self
        }
        return String(prefix(77)) + "..."
    }

    var truncatedForStatus: String {
        guard count > 28 else {
            return self
        }
        return String(prefix(25)) + "..."
    }

    func wrappedForMenu(maxLineLength: Int) -> [String] {
        let words = split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return [self]
        }

        var lines: [String] = []
        var current = ""

        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxLineLength {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }

            while current.count > maxLineLength {
                let splitIndex = current.index(current.startIndex, offsetBy: maxLineLength)
                lines.append(String(current[..<splitIndex]))
                current = String(current[splitIndex...])
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines
    }
}

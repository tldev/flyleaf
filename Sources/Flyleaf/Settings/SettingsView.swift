import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PanelSettings().tabItem { Label("Panel", systemImage: "rectangle.portrait.on.rectangle.portrait") }
            PackSettings().tabItem { Label("Pack Builder", systemImage: "sparkles") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 600, height: 520)
        .environment(state)
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = Prefs.shared.launchAtLogin
    @State private var notifications = Prefs.shared.notificationsEnabled

    var body: some View {
        @Bindable var prefs = Prefs.shared
        Form {
            Toggle("Launch Flyleaf at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    Prefs.shared.launchAtLogin = on
                    LoginItem.set(enabled: on)
                }
            Toggle("Chapter briefing notifications", isOn: $notifications)
                .onChange(of: notifications) { _, on in
                    Prefs.shared.notificationsEnabled = on
                    if on { Task { _ = await AppNotifications.requestAuthorization() } }
                }
            Toggle("Follow the most recently opened Kindle book", isOn: $prefs.followMostRecent)

            Section("Polling") {
                LabeledContent("While reading") {
                    Stepper("\(prefs.pollActiveSeconds)s", value: $prefs.pollActiveSeconds, in: 30...300, step: 15)
                }
                LabeledContent("When idle") {
                    Stepper("\(prefs.pollIdleSeconds / 60) min", value: $prefs.pollIdleSeconds, in: 120...3600, step: 60)
                }
                Text("Flyleaf polls read-only and backs off when you are away. Overnight it sleeps almost entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PanelSettings: View {
    var body: some View {
        @Bindable var prefs = Prefs.shared
        Form {
            Picker("Size", selection: $prefs.panelSize) {
                ForEach(PanelSize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Theme", selection: $prefs.panelTheme) {
                ForEach(PanelTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Higher contrast background", isOn: $prefs.highContrast)
            Toggle("Click-through (panel never takes clicks)", isOn: $prefs.clickThrough)
                .onChange(of: prefs.clickThrough) { _, _ in
                    PanelController.shared.applyPrefs()
                }
            LabeledContent("Card rotation") {
                Stepper("every \(prefs.rotationSeconds)s", value: $prefs.rotationSeconds, in: 8...120, step: 4)
            }

            Section("Ambient mode") {
                Toggle("Dim into imagery when idle", isOn: $prefs.ambientEnabled)
                LabeledContent("After") {
                    Stepper("\(prefs.ambientDelayMinutes) min without a sync", value: $prefs.ambientDelayMinutes, in: 1...30)
                }
            }

            Section {
                Button(Prefs.shared.panelVisible ? "Hide panel" : "Show panel") {
                    PanelController.shared.toggle()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PackSettings: View {
    @Environment(AppState.self) private var state
    @State private var keyInput = ""
    @State private var hasKey = Keychain.get(account: SecretAccount.anthropicKey) != nil
    @State private var cleared = false
    @State private var orKeyInput = ""
    @State private var hasORKey = Keychain.get(account: SecretAccount.openRouterKey) != nil

    var body: some View {
        @Bindable var prefs = Prefs.shared
        Form {
            Section("Claude account (recommended)") {
                switch state.builderAuth {
                case .subscription(let plan):
                    LabeledContent("Status") {
                        Label("Using your Claude \(plan.capitalized) subscription", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text("Chapter research runs on the Claude Code login on this Mac, drawing on your subscription. Nothing to paste or rotate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .claudeAccount:
                    LabeledContent("Status") {
                        Label("Using your Claude account (CLI)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                default:
                    Text("Sign in to Claude Code on this Mac and Flyleaf uses your Claude subscription automatically. If you use the Claude Code CLI, you're already set; click Check again.")
                        .font(.callout)
                    Button("Check again") {
                        Task { await state.refreshBuilderAuth() }
                    }
                }
            }

            Section("Or an Anthropic API key") {
                if hasKey {
                    let usingKey = state.builderAuth == .apiKey
                    LabeledContent("Status") {
                        Label(
                            usingKey ? "Key saved in Keychain" : "Key saved (Claude account takes priority)",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(usingKey ? .green : .secondary)
                    }
                    Button("Remove key") {
                        Keychain.delete(account: SecretAccount.anthropicKey)
                        hasKey = false
                        Task { await state.refreshBuilderAuth() }
                    }
                } else {
                    HStack {
                        SecureField("sk-ant-…", text: $keyInput)
                        Button("Save") {
                            let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            Keychain.set(trimmed, account: SecretAccount.anthropicKey)
                            keyInput = ""
                            hasKey = true
                            state.builderKeyAdded()
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            Section("Behavior") {
                TextField("Model", text: $prefs.packModel)
                Toggle("Prefetch the next chapter's pack", isOn: $prefs.prefetchNext)
            }

            Section("Local book text (from an imported EPUB)") {
                Text("When you import an EPUB, Flyleaf reads the real chapter text with a cheap model on OpenRouter to find who, where, and what each chapter is about. Only the current chapter is ever sent, so it stays spoiler-safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasORKey {
                    LabeledContent("OpenRouter") {
                        Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Button("Remove OpenRouter key") {
                        Keychain.delete(account: SecretAccount.openRouterKey)
                        hasORKey = false
                    }
                } else {
                    HStack {
                        SecureField("OpenRouter key (sk-or-…)", text: $orKeyInput)
                        Button("Save") {
                            let trimmed = orKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            Keychain.set(trimmed, account: SecretAccount.openRouterKey)
                            orKeyInput = ""
                            hasORKey = true
                        }
                        .disabled(orKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.caption)
                }
                TextField("Extraction model", text: $prefs.extractModel)
                Text("Default google/gemini-3.7-flash. Any OpenRouter model slug works.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Toggle("Use imported text when available", isOn: $prefs.preferLocalText)
                Button("Import an EPUB…") { importEPUB() }
                if state.hasLocalText {
                    Button("Remove imported text for this book", role: .destructive) {
                        state.removeLocalText()
                    }
                }
            }

            Section("Cache") {
                Button("Rebuild current chapter") {
                    if let chapter = state.currentChapter, let book = state.currentBook {
                        state.store.clearChapter(asin: book.asin, chapter: chapter)
                        state.activePack = nil
                        state.ensurePack(chapter: chapter, display: true)
                    }
                }
                .disabled(state.currentChapter == nil)
                Button(cleared ? "Cleared" : "Clear all cached packs") {
                    state.store.clearPacks()
                    state.activePack = nil
                    state.packStatus = .none
                    cleared = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importEPUB() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the EPUB for the book you're reading"
        if panel.runModal() == .OK, let url = panel.url {
            state.importEPUB(url: url)
            WindowManager.shared.showMain()
        }
    }
}

private struct AccountSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var prefs = Prefs.shared
        Form {
            Section("Amazon") {
                LabeledContent("Status") {
                    switch state.connection {
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .connecting:
                        Label("Connecting…", systemImage: "clock").foregroundStyle(.secondary)
                    case .needsReauth:
                        Label("Needs a fresh sign-in", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .notConnected:
                        Label("Not connected", systemImage: "circle").foregroundStyle(.secondary)
                    }
                }
                Picker("Amazon region", selection: $prefs.region) {
                    ForEach(AmazonRegion.allCases) { Text($0.label).tag($0) }
                }
                if state.connection == .connected {
                    Button("Sign out") {
                        state.disconnectAmazon()
                    }
                } else {
                    Button(state.connection == .needsReauth ? "Re-connect Amazon…" : "Connect Amazon…") {
                        WindowManager.shared.showLogin()
                    }
                }
                Text("Read-only access through Amazon's own sign-in. Flyleaf polls your reading position a few times a minute while you read, nothing more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Emailed & sideloaded books") {
                if state.deviceRegistered && prefs.personalDocSync {
                    LabeledContent("Status") {
                        Label("Following personal documents", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button("Sync a document now") {
                        Task { await state.refreshActivePersonalDoc(force: true) }
                    }
                    Button("Turn off and deregister this Mac", role: .destructive) {
                        state.disablePersonalDocSync()
                    }
                } else {
                    Text("Books you email to your Kindle (Send-to-Kindle) do not appear in the normal reading API. To follow those too, Flyleaf registers this Mac as a Kindle device, the same step a new Kindle app performs, and reads their position through Whispersync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(state.enablingDocSync ? "Registering…" : "Follow my emailed books…") {
                        Task { await state.enablePersonalDocSync() }
                    }
                    .disabled(state.enablingDocSync || state.connection != .connected)
                    Text("This adds a device named “Flyleaf on Mac” to your Amazon account. You can remove it here or at amazon.com anytime.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section("Diagnostics") {
                Button("Open log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([FileLogger.shared.logURL])
                }
                Button("Open data folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDir])
                }
            }
            Section("Testing") {
                Button("Load the demo book") {
                    state.loadDemo()
                    WindowManager.shared.showMain()
                }
                Button("Run onboarding again") {
                    Prefs.shared.onboardingComplete = false
                    WindowManager.shared.showOnboarding()
                }
            }
            Section {
                LabeledContent("Version", value: "0.1.0 (personal build)")
            }
        }
        .formStyle(.grouped)
    }
}

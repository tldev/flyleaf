import SwiftUI
import ServiceManagement

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

    var body: some View {
        @Bindable var prefs = Prefs.shared
        Form {
            Section("Claude account (recommended)") {
                if state.builderAuth == .claudeAccount {
                    LabeledContent("Status") {
                        Label("Using your Claude account", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text("Tokens are minted by the Anthropic CLI profile on this Mac; nothing to paste or rotate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if AntCLI.isInstalled {
                        Text("The Anthropic CLI is installed. Sign in once in Terminal, then check again:")
                            .font(.callout)
                        Text("ant auth login")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("Install the Anthropic CLI and sign in once; Flyleaf then uses your Claude account with no key to manage:")
                            .font(.callout)
                        Text("brew install anthropics/tap/ant\nant auth login")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button("Check again") {
                        Task { await state.refreshBuilderAuth() }
                    }
                }
            }

            Section("Or an Anthropic API key") {
                if hasKey {
                    LabeledContent("Status") {
                        Label(
                            state.builderAuth == .claudeAccount ? "Key saved (Claude account takes priority)" : "Key saved in Keychain",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(state.builderAuth == .apiKey ? .green : .secondary)
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

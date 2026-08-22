import SwiftUI
import ServiceManagement

// Target: under two minutes, one decision. Welcome -> Amazon sign-in ->
// magic moment -> optional prefs.
struct OnboardingView: View {
    @Environment(AppState.self) private var state

    enum Step {
        case welcome, signIn, magic, prefs
    }

    @State private var step: Step = .welcome

    var body: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .signIn: signIn
            case .magic: MagicMomentView(onContinue: { step = .prefs })
            case .prefs: OnboardingPrefsView(onDone: finish)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "book.closed.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("Flyleaf")
                .font(.system(size: 44, weight: .semibold, design: .serif))
            Text("Follows your Kindle as you read, and quietly shows who,\nwhere, and what the chapter is about. At a glance.")
                .font(.system(size: 16, design: .serif))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer().frame(height: 8)
            Button {
                step = .signIn
            } label: {
                Text("Connect Amazon")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 220, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
            HStack(spacing: 24) {
                Button("Use Manual Mode instead") {
                    finish()
                    WindowManager.shared.showManualPicker()
                }
                .buttonStyle(.link)
                Button("Just exploring? Try the demo") {
                    state.loadDemo()
                    finish()
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.bottom, 24)
        }
        .padding(30)
    }

    private var signIn: some View {
        VStack(spacing: 0) {
            AmazonLoginWebView(region: Prefs.shared.region) {
                state.connectKindle()
                step = .magic
            }
            Divider()
            HStack {
                Button {
                    step = .welcome
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Label(
                    "Amazon's own sign-in page. 2FA and passkeys work; Flyleaf never sees your password.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private func finish() {
        Prefs.shared.onboardingComplete = true
        WindowManager.shared.close(id: "onboarding")
        WindowManager.shared.showMain()
        if Prefs.shared.panelVisible {
            PanelController.shared.show()
        }
    }
}

// "You're reading Apple in China, 38%." The first pack builds behind a
// shimmer while this screen is still up.
struct MagicMomentView: View {
    @Environment(AppState.self) private var state
    let onContinue: () -> Void

    @State private var keyInput = ""
    @State private var keySaved = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let book = state.currentBook {
                AsyncImage(url: book.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                            .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 130, height: 195)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 8, y: 4)

                Text("You're reading")
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(.secondary)
                Text(book.title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                if let percent = state.position?.percent {
                    Text("\(Int(percent))% in · chapter \(state.currentChapter.map(String.init) ?? "…")")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                statusLine
            } else {
                ProgressView()
                Text(detectionMessage)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if state.connection == .connected {
                    Button("Pick a book instead") {
                        WindowManager.shared.showManualPicker()
                    }
                    .buttonStyle(.link)
                }
            }

            if !state.hasBuilderKey {
                keyEntry
            }

            Spacer()
            Button {
                onContinue()
            } label: {
                Text("Continue").frame(width: 160, height: 26)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 24)
        }
        .padding(30)
    }

    private var detectionMessage: String {
        switch state.connection {
        case .connecting: return "Checking your Kindle library…"
        case .needsReauth: return "Sign-in did not stick. Go back and try again."
        case .connected: return "Connected. Looking for your most recent book…\nIf nothing appears, open a book on your Kindle and turn a page."
        case .notConnected: return "Waiting for Amazon…"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.packStatus {
        case .building(let phase):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(phase)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Your first cards are ready in the panel", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        case .needsKey, .none:
            EmptyView()
        }
    }

    private var keyEntry: some View {
        VStack(spacing: 8) {
            Text("Developer build: context packs are researched with your own Anthropic API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("sk-ant-…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button(keySaved ? "Saved" : "Save") {
                    let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Keychain.set(trimmed, account: SecretAccount.anthropicKey)
                    keySaved = true
                    state.builderKeyAdded()
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 6)
    }
}

struct OnboardingPrefsView: View {
    let onDone: () -> Void

    @State private var notificationsOn = false
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("A few choices")
                .font(.system(size: 28, weight: .semibold, design: .serif))
            Text("All of this can change later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                Toggle("Also show a small floating panel while reading", isOn: Binding(
                    get: { Prefs.shared.panelVisible },
                    set: { Prefs.shared.panelVisible = $0 }
                ))

                Toggle("Chapter briefing notifications", isOn: $notificationsOn)
                    .onChange(of: notificationsOn) { _, on in
                        Prefs.shared.notificationsEnabled = on
                        if on {
                            Task { _ = await AppNotifications.requestAuthorization() }
                        }
                    }

                Toggle("Launch Flyleaf at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        Prefs.shared.launchAtLogin = on
                        LoginItem.set(enabled: on)
                    }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .scrollContentBackground(.hidden)

            Button {
                onDone()
            } label: {
                Text("Start reading").frame(width: 180, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding(30)
    }
}

enum LoginItem {
    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            log(.app, "Launch at login \(enabled ? "enabled" : "disabled")")
        } catch {
            log(.app, .warn, "Launch at login change failed: \(error.localizedDescription)")
        }
    }
}

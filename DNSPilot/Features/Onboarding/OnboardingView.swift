import SwiftUI

@MainActor
struct OnboardingView: View {
    private enum CustomField: Hashable {
        case name
        case server
        case port
        case endpoint
        case bootstrap
    }

    fileprivate enum Template: String, CaseIterable, Identifiable {
        case cloudflareDoH
        case cloudflarePlain
        case googleDoH
        case googlePlain
        case quad9DoH
        case quad9Plain
        case custom

        var id: Self { self }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage(ProductWindowPolicy.setupProfileIDKey) private var setupProfileID = ""
    @State private var introductionCompleted = false
    @State private var profileStepCompleted = false
    @State private var locationStepCompleted = false
    @State private var selection: Template?
    @State private var selectedExistingProfileID: DNSProfile.ID?
    @State private var revisitingStep: OnboardingStep?
    @State private var isConfiguringCustomProfile = false
    @State private var customDraft = ProfileDraft()
    @State private var dnsEnableFailure: ProductActionFailure?
    @State private var customValidationError: ProfileDraftError?
    @State private var profileSubmissionInProgress = false
    @State private var profileSubmissionFailureMessage: String?
    @State private var locationRequestInProgress = false
    @State private var onboardingPreparationInProgress = true
    @FocusState private var focusedCustomField: CustomField?

    var body: some View {
        HSplitView {
            List(visibleSteps, id: \.self) { step in
                Label(step.title, systemImage: stepSymbol(step))
                    .foregroundStyle(step == displayedStep ? .primary : .secondary)
            }
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 220)

            VStack(alignment: .leading, spacing: 18) {
                stepContent
                Spacer()
                bottomNavigationControls
            }
            .disabled(onboardingPreparationInProgress)
            .overlay {
                if onboardingPreparationInProgress {
                    ProgressView("Preparing Setup")
                        .controlSize(.large)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 620, minHeight: 480)
        .onAppear {
            introductionCompleted = false
            profileStepCompleted = false
            locationStepCompleted = false
            revisitingStep = nil
            isConfiguringCustomProfile = false
            if setupProfileID.isEmpty { setupProfileID = UUID().uuidString }
            if let id = UUID(uuidString: setupProfileID) { customDraft.id = id }
            appState.synchronizeSystemExtension()
        }
        .onChange(of: appState.locationAuthorization) { _, authorization in
            if authorization != .notDetermined {
                locationRequestInProgress = false
            }
            guard displayedStep == .location, authorization == .authorized else { return }
            locationStepCompleted = true
            revisitingStep = nil
        }
        .task { await prepareOnboarding() }
        .alert(
            "Profile Setup Failed",
            isPresented: Binding(
                get: { profileSubmissionFailureMessage != nil },
                set: { if !$0 { profileSubmissionFailureMessage = nil } }
            )
        ) {
            Button("OK") { profileSubmissionFailureMessage = nil }
        } message: {
            Text(profileSubmissionFailureMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch displayedStep {
        case .introduction:
            Text("Set Up DNSPilot").font(.title)
            Text("DNSPilot uses the macOS DNS Proxy to forward system DNS requests. Other DNS Proxy apps may conflict. Normal Quit attempts to restore System DNS.")
                .foregroundStyle(.secondary)
        case .profile:
            Text("Choose a DNS Profile").font(.title2.weight(.semibold))
            if !appState.profiles.isEmpty {
                Picker("Existing Profile", selection: $selectedExistingProfileID) {
                    Text("Choose an Existing Profile").tag(Optional<DNSProfile.ID>.none)
                    ForEach(appState.profiles) { profile in
                        Text(existingProfileNames[profile.id] ?? profile.name)
                            .tag(Optional(profile.id))
                    }
                }
                .disabled(profileSubmissionInProgress)
                .onChange(of: selectedExistingProfileID) { _, profileID in
                    if profileID != nil { selection = nil }
                }
            }
            List(Template.allCases, selection: $selection) { template in
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                    Text(template.summary).font(.caption).foregroundStyle(.secondary)
                }
                .tag(template)
            }
            .frame(minHeight: 260)
            .disabled(profileSubmissionInProgress)
            .onChange(of: selection) { _, template in
                if template != nil { selectedExistingProfileID = nil }
                if template == .custom { appState.beginDraft(.profile) }
                else { appState.endDraft() }
            }
        case .customProfile:
            Text("Configure Custom Profile").font(.title2.weight(.semibold))
            customProfileFields
                .disabled(profileSubmissionInProgress)
        case .location:
            Text("Wi-Fi Network Names").font(.title2.weight(.semibold))
            Text("Location access is used only to read the current Wi-Fi name. Interface, subnet, and Default Profile selection continue to work without it.")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Location Access:")
                Text(locationAuthorizationName)
                    .foregroundStyle(locationAuthorizationColor)
            }
            switch appState.locationAuthorization {
            case .authorized:
                EmptyView()
            case .notDetermined:
                if locationRequestInProgress {
                    Text("Waiting for your response to the system permission request.")
                        .foregroundStyle(.secondary)
                }
            case .denied:
                Text("Location access was denied. You can continue without Wi-Fi name access or allow it in System Settings.")
                    .foregroundStyle(.secondary)
            }
        case .systemExtension:
            Text("Install System Extension").font(.title2.weight(.semibold))
            Text(appState.systemExtensionState.userDescription).foregroundStyle(.secondary)
        case .dnsProxy:
            Text("Enable DNS Proxy").font(.title2.weight(.semibold))
            Text("DNSPilot will enable the selected Profile only after you confirm this step.")
                .foregroundStyle(.secondary)
            if let dnsEnableFailure {
                Text(dnsEnableFailure.message)
                    .foregroundStyle(.red)
            }
        case .complete:
            Text("DNSPilot Is Ready").font(.title2.weight(.semibold))
            Label("DNS Proxy On", systemImage: "checkmark.circle.fill")
            LabeledContent("Active Profile", value: activeProfileName)
            LabeledContent("Mode", value: operatingModeName)
            Text(appState.menuPresentation?.networkText ?? "Network: Checking")
                .foregroundStyle(.secondary)
            LabeledContent("Location", value: locationAuthorizationName)
        }
    }

    private var customProfileFields: some View {
        Form {
            TextField("Name", text: $customDraft.name, prompt: Text("Home DNS"))
                .focused($focusedCustomField, equals: .name)
            customFieldError(.name)
            Picker("Protocol", selection: $customDraft.transport) {
                Text("Plain DNS").tag(ProfileTransport.plain)
                Text("DNS over TLS").tag(ProfileTransport.tls)
                Text("DNS over HTTPS").tag(ProfileTransport.https)
            }
            .pickerStyle(.segmented)
            switch customDraft.transport {
            case .plain:
                TextField(
                    "Server Address",
                    text: $customDraft.plainServerAddress,
                    prompt: Text("1.1.1.1")
                )
                    .focused($focusedCustomField, equals: .server)
                customFieldError(.server)
                TextField(
                    "Port",
                    value: $customDraft.plainPort,
                    format: .number,
                    prompt: Text("53")
                )
                    .focused($focusedCustomField, equals: .port)
                customFieldError(.port)
            case .tls:
                TextField(
                    "Server Name or Address",
                    text: $customDraft.dotServerName,
                    prompt: Text("dns.example.com")
                )
                    .focused($focusedCustomField, equals: .server)
                customFieldError(.server)
                TextField(
                    "Port",
                    value: $customDraft.dotPort,
                    format: .number,
                    prompt: Text("853")
                )
                    .focused($focusedCustomField, equals: .port)
                customFieldError(.port)
                customBootstrapEditor
            case .https:
                TextField(
                    "Endpoint URL",
                    text: $customDraft.endpointURL,
                    prompt: Text("https://dns.example.com/dns-query")
                )
                    .focused($focusedCustomField, equals: .endpoint)
                customFieldError(.endpoint)
                customBootstrapEditor
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var bottomNavigationControls: some View {
        switch displayedStep {
        case .introduction:
            HStack {
                Button("Quit DNSPilot") { appState.quit() }
                Spacer()
                Button("Continue") {
                    introductionCompleted = true
                    revisitingStep = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        case .profile:
            profileNavigationControls
        case .customProfile:
            customProfileNavigationControls
        case .location:
            HStack {
                Button("Back") { goBack() }
                Spacer()
                switch appState.locationAuthorization {
                case .authorized:
                    Button("Continue") {
                        locationStepCompleted = true
                        revisitingStep = nil
                    }
                    .keyboardShortcut(.defaultAction)
                case .denied:
                    Button("Not Now") {
                        locationStepCompleted = true
                        revisitingStep = nil
                    }
                    Button("Open System Settings") { appState.openLocationSettings() }
                    .keyboardShortcut(.defaultAction)
                case .notDetermined:
                    Button("Not Now") {
                        locationStepCompleted = true
                        revisitingStep = nil
                    }
                    Button("Allow Location Access") { requestLocationAuthorization() }
                    .disabled(locationRequestInProgress)
                    .keyboardShortcut(.defaultAction)
                }
            }
        case .systemExtension:
            systemExtensionNavigationControls
        case .dnsProxy:
            dnsProxyNavigationControls
        case .complete:
            HStack {
                Spacer()
                Button("Open DNSPilot") { appState.completeOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var profileNavigationControls: some View {
        HStack {
            Button("Back") { goBack() }
            Spacer()
            if let privacyLink {
                Link(privacyLink.label, destination: privacyLink.url)
                    .font(.caption)
            }
            Button(selection == .custom ? "Configur Profile" : "Test and Continue") {
                if selection == .custom {
                    isConfiguringCustomProfile = true
                    revisitingStep = nil
                } else {
                    saveSelectedProfile()
                }
            }
            .disabled(
                (selection == nil && selectedExistingProfileID == nil)
                    || profileSubmissionInProgress
                    || appState.isPerformingAction
            )
            .keyboardShortcut(.defaultAction)
        }
    }

    private var customProfileNavigationControls: some View {
        HStack {
            Button("Back") { goBack() }
            Spacer()
            Button("Test and Continue") { saveSelectedProfile() }
                .disabled(profileSubmissionInProgress || appState.isPerformingAction)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var systemExtensionNavigationControls: some View {
        HStack {
            Button("Back") { goBack() }
            Spacer()
            if appState.systemExtensionState == .awaitingApproval {
                Button("Open System Settings") { appState.openSystemExtensionSettings() }
                Button("Check Again") { appState.synchronizeSystemExtension() }
            }
            switch appState.systemExtensionState {
            case .active:
                Button("Continue") { revisitingStep = nil }
                    .keyboardShortcut(.defaultAction)
            case .updateRequired, .updateFailed:
                Button("Update Safely") {
                    Task { await appState.updateSystemExtensionSafely() }
                }
                .disabled(appState.systemExtensionRequestInProgress)
            case .downgradeBlocked:
                Button("Check for Updates") { appState.openAppStore() }
            case .checking, .notInstalled, .activating, .awaitingApproval, .deactivating,
                 .inactive, .uninstalling, .restartRequired, .failed:
                Button("Install") { appState.installSystemExtension() }
                    .disabled(
                        appState.systemExtensionRequestInProgress
                            || !appState.systemExtensionState.allowsActivation
                    )
            }
        }
    }

    private var dnsProxyNavigationControls: some View {
        HStack {
            Button("Back") { goBack() }
            Spacer()
            if dnsEnableFailure != nil {
                Button("Restore System DNS") {
                    Task { await appState.restoreSystemDNS() }
                }
                Button("Open Diagnostics") {
                    appState.selectSettingsSection(.diagnostics)
                    openSettings()
                }
                Button("Try Again") { enableDNSProxy() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Enable DNS Proxy") { enableDNSProxy() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(appState.isPerformingAction)
    }

    private var privacyLink: (label: String, url: URL)? {
        switch selection {
        case .cloudflareDoH, .cloudflarePlain:
            ("Cloudflare Privacy", URL(string: "https://www.cloudflare.com/privacypolicy/")!)
        case .googleDoH, .googlePlain:
            ("Google Privacy", URL(string: "https://policies.google.com/privacy")!)
        case .quad9DoH, .quad9Plain:
            ("Quad9 Privacy", URL(string: "https://quad9.net/privacy/policy/")!)
        case .custom, nil:
            nil
        }
    }

    private var progress: OnboardingProgress {
        OnboardingProgress(
            setupProfileID: UUID(uuidString: setupProfileID) ?? UUID(),
            introductionCompleted: introductionCompleted,
            locationStepCompleted: locationStepCompleted
        )
    }

    private var currentStep: OnboardingStep {
        progress.currentStep(
            isSetupProfileConfigured: profileStepCompleted,
            isSystemExtensionInstalled: appState.systemExtensionState == .active,
            isDNSProxyActive: { if case .active = appState.proxy.state { true } else { false } }()
        )
    }

    private var displayedStep: OnboardingStep {
        isConfiguringCustomProfile ? .customProfile : revisitingStep ?? currentStep
    }

    private var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter {
            $0 != .customProfile || selection == .custom || isConfiguringCustomProfile
        }
    }

    private func goBack() {
        if displayedStep == .customProfile {
            isConfiguringCustomProfile = false
            revisitingStep = .profile
            return
        }
        revisitingStep = switch displayedStep {
        case .introduction, .profile: .introduction
        case .customProfile: .profile
        case .location: .profile
        case .systemExtension: .location
        case .dnsProxy: .systemExtension
        case .complete: nil
        }
    }

    private func requestLocationAuthorization() {
        locationRequestInProgress = true
        Task { await appState.requestLocationAuthorization() }
    }

    private func prepareOnboarding() async {
        defer { onboardingPreparationInProgress = false }
        guard !appState.profiles.isEmpty else { return }
        guard profileOperationSucceeded(await appState.resetOnboardingConfiguration()) else {
            return
        }
        let profileID = UUID()
        setupProfileID = profileID.uuidString
        customDraft = ProfileDraft()
        customDraft.id = profileID
        selection = nil
        selectedExistingProfileID = nil
    }

    private func stepSymbol(_ step: OnboardingStep) -> String {
        if step == displayedStep { return "circle.fill" }
        if displayedStep == .customProfile, step == .profile { return "circle.fill" }
        guard let stepIndex = visibleSteps.firstIndex(of: step),
              let currentIndex = visibleSteps.firstIndex(of: currentStep) else {
            return "circle"
        }
        return stepIndex < currentIndex ? "checkmark.circle.fill" : "circle"
    }

    private func saveSelectedProfile() {
        if let profileID = selectedExistingProfileID,
           let profile = appState.profiles.first(where: { $0.id == profileID }) {
            profileSubmissionInProgress = true
            Task {
                defer { profileSubmissionInProgress = false }
                guard profileOperationSucceeded(
                    await appState.preflightProfile(ProfileDraft(profile: profile))
                ) else { return }
                if profileOperationSucceeded(await appState.setDefaultProfile(profileID)) {
                    setupProfileID = profileID.uuidString
                    profileStepCompleted = true
                    revisitingStep = nil
                }
            }
            return
        }
        guard let selection else { return }
        var draft = selection == .custom ? customDraft : selection.draft(id: progress.setupProfileID)
        draft.id = progress.setupProfileID
        if selection == .custom {
            do {
                _ = try draft.profile()
                customValidationError = nil
            } catch let error as ProfileDraftError {
                customValidationError = error
                focusedCustomField = customField(for: error)
                return
            } catch {
                return
            }
        }
        profileSubmissionInProgress = true
        Task {
            defer { profileSubmissionInProgress = false }
            guard profileOperationSucceeded(await appState.preflightProfile(draft)) else { return }
            let outcome = appState.profiles.contains { $0.id == draft.id }
                ? await appState.editProfile(draft)
                : await appState.createProfile(draft)
            guard profileOperationSucceeded(outcome) else { return }
            if profileOperationSucceeded(await appState.setDefaultProfile(draft.id)) {
                profileStepCompleted = true
                isConfiguringCustomProfile = false
                revisitingStep = nil
            }
        }
    }

    private func profileOperationSucceeded(_ outcome: ProductActionOutcome) -> Bool {
        switch outcome {
        case .completed:
            return true
        case let .failed(failure):
            appState.clearActionFailure()
            profileSubmissionFailureMessage = failure.message
            return false
        }
    }

    private var existingProfileNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private var activeProfileName: String {
        guard let profileID = appState.proxy.activeProfileID else { return "System DNS" }
        return existingProfileNames[profileID] ?? "Unknown Profile"
    }

    private var operatingModeName: String {
        switch appState.configuration?.operatingMode {
        case .automatic: "Automatic"
        case .manual: "Manual"
        case nil: "Unavailable"
        }
    }

    private var locationAuthorizationName: String {
        switch appState.locationAuthorization {
        case .authorized: "Allowed"
        case .notDetermined: "Not Requested"
        case .denied: "Denied"
        }
    }

    private func customField(for error: ProfileDraftError) -> CustomField {
        switch error {
        case .emptyName: .name
        case .invalidServerAddress, .invalidServerName: .server
        case .invalidPort: .port
        case .invalidEndpoint: .endpoint
        case .invalidBootstrapServer, .missingBootstrapServers: .bootstrap
        }
    }

    private func normalizeIPAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? IPAddress(trimmed))?.stringValue
    }

    private var customBootstrapEditor: some View {
        Group {
            StringListEditor(
                label: "Bootstrap Servers",
                itemLabel: "Bootstrap Server",
                addLabel: "Add Bootstrap Server",
                values: $customDraft.bootstrapServers,
                normalize: normalizeIPAddress,
                itemPrompt: "1.1.1.1"
            )
            .focused($focusedCustomField, equals: .bootstrap)
            customFieldError(.bootstrap)
        }
    }

    @ViewBuilder
    private func customFieldError(_ field: CustomField) -> some View {
        if let customValidationError, customField(for: customValidationError) == field {
            let message = customValidationError.errorDescription ?? "Invalid value"
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(message)")
        }
    }

    private func enableDNSProxy() {
        dnsEnableFailure = nil
        Task {
            let outcome = await appState.turnOnDNSProxy()
            if case let .failed(failure) = outcome {
                dnsEnableFailure = failure
                appState.clearActionFailure()
            }
        }
    }

    private var locationAuthorizationColor: Color {
        switch appState.locationAuthorization {
        case .authorized: .green
        case .notDetermined: .orange
        case .denied: .red
        }
    }
}

private extension OnboardingStep {
    var title: String {
        switch self {
        case .introduction: "Introduction"
        case .profile: "DNS Profile"
        case .customProfile: "Custom Profile"
        case .location: "Location"
        case .systemExtension: "Extension"
        case .dnsProxy: "DNS Proxy"
        case .complete: "Complete"
        }
    }
}

private extension OnboardingView.Template {
    var name: String {
        switch self {
        case .cloudflareDoH: "Cloudflare - DNS over HTTPS"
        case .cloudflarePlain: "Cloudflare - Plain DNS"
        case .googleDoH: "Google - DNS over HTTPS"
        case .googlePlain: "Google - Plain DNS"
        case .quad9DoH: "Quad9 - DNS over HTTPS"
        case .quad9Plain: "Quad9 - Plain DNS"
        case .custom: "Custom..."
        }
    }

    var summary: String {
        switch self {
        case .cloudflareDoH: "cloudflare-dns.com"
        case .cloudflarePlain: "1.1.1.1"
        case .googleDoH: "dns.google"
        case .googlePlain: "8.8.8.8"
        case .quad9DoH: "dns.quad9.net"
        case .quad9Plain: "9.9.9.9"
        case .custom: "Enter a DNS server or HTTPS endpoint"
        }
    }

    func draft(id: UUID) -> ProfileDraft {
        switch self {
        case .cloudflareDoH:
            ProfileDraft(id: id, name: name, endpointURL: "https://cloudflare-dns.com/dns-query", bootstrapServers: ["1.1.1.1", "1.0.0.1"])
        case .cloudflarePlain:
            ProfileDraft(id: id, name: name, transport: .plain, plainServerAddress: "1.1.1.1")
        case .googleDoH:
            ProfileDraft(id: id, name: name, endpointURL: "https://dns.google/dns-query", bootstrapServers: ["8.8.8.8", "8.8.4.4"])
        case .googlePlain:
            ProfileDraft(id: id, name: name, transport: .plain, plainServerAddress: "8.8.8.8")
        case .quad9DoH:
            ProfileDraft(id: id, name: name, endpointURL: "https://dns.quad9.net/dns-query", bootstrapServers: ["9.9.9.9", "149.112.112.112"])
        case .quad9Plain:
            ProfileDraft(id: id, name: name, transport: .plain, plainServerAddress: "9.9.9.9")
        case .custom:
            ProfileDraft(id: id)
        }
    }
}

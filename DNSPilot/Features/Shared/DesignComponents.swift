import SwiftUI

/// Visual treatment of the confirmed DNS Proxy state. Every state pairs a symbol,
/// a tint, and text so color never carries status alone.
struct ProxyStatusAppearance: Equatable {
    enum Tone: Equatable {
        case positive
        case neutral
        case busy
        case warning
        case critical
    }

    let title: String
    let subtitle: String
    let symbolName: String
    let tone: Tone

    @MainActor
    init(appState: AppState) {
        let presentation = appState.menuPresentation
        title = presentation?.statusText ?? "DNS Proxy Off"
        let names = ProfileDisplayIdentity.displayNames(for: appState.profiles)
        switch appState.proxy.state {
        case .disabled:
            subtitle = "System DNS is active"
            symbolName = "shield.slash"
            tone = .neutral
        case .active:
            if let profile = appState.profiles.first(where: { $0.id == appState.proxy.activeProfileID }) {
                subtitle = "Using \(names[profile.id] ?? profile.name) · \(profile.upstream.transportTitle)"
            } else {
                subtitle = presentation?.profileLines.first ?? ""
            }
            symbolName = "checkmark.shield.fill"
            tone = .positive
        case .preparing, .applying, .repairing, .stopping:
            subtitle = presentation?.profileLines.joined(separator: " · ") ?? ""
            symbolName = "arrow.triangle.2.circlepath"
            tone = .busy
        case .recoveryRequired, .degraded:
            subtitle = presentation?.profileLines.joined(separator: " · ") ?? ""
            symbolName = "exclamationmark.shield.fill"
            tone = .warning
        case .failed:
            subtitle = presentation?.profileLines.joined(separator: " · ") ?? ""
            symbolName = "exclamationmark.shield.fill"
            tone = .critical
        }
    }

    var tint: Color {
        switch tone {
        case .positive: .green
        case .neutral: .secondary
        case .busy: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Status symbol in a tinted circle; shows a spinner while the runtime is changing.
struct ProxyStatusBadge: View {
    let appearance: ProxyStatusAppearance
    var diameter: CGFloat = 48

    var body: some View {
        ZStack {
            Circle().fill(appearance.tint.opacity(appearance.tone == .neutral ? 0.12 : 0.16))
            if appearance.tone == .busy {
                ProgressView()
                    .controlSize(diameter > 32 ? .regular : .small)
            } else {
                Image(systemName: appearance.symbolName)
                    .font(.system(size: diameter * 0.46, weight: .medium))
                    .foregroundStyle(appearance.tint)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// An inline notice row for grouped forms: symbol, headline, explanation, and recovery actions.
struct StatusNotice<Actions: View>: View {
    let title: String
    let message: String
    let symbolName: String
    let tint: Color
    @ViewBuilder let actions: Actions

    init(
        _ title: String,
        message: String,
        symbolName: String,
        tint: Color,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.symbolName = symbolName
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Floating control cluster background: Liquid Glass on macOS 26, material on earlier systems.
    @ViewBuilder
    func floatingControlBackground() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

/// Bottom-of-list action cluster used by Profiles and Rules.
struct ListActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .imageScale(.medium)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .floatingControlBackground()
    }
}

extension DNSUpstream {
    var transportTitle: String {
        switch self {
        case .plain: "Plain DNS"
        case .tls: "DNS over TLS"
        case .https: "DNS over HTTPS"
        }
    }

    var transportSymbolName: String {
        switch self {
        case .plain: "server.rack"
        case .tls: "lock.shield"
        case .https: "globe"
        }
    }
}

extension NetworkInterfaceType {
    var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "Ethernet"
        case .other: "Other"
        }
    }
}

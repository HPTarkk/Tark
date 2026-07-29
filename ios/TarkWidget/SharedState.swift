import SwiftUI

/// Mirror of Dart's `HomeWidgetKeys` (lib/core/home_widget/home_widget_keys.dart).
///
/// A cross-language contract: the app writes these into the App Group's
/// UserDefaults through the home_widget plugin, and the extension reads them
/// back. The Dart file is the source of truth; this is kept in step by hand.
private enum Keys {
    static let session = "wk_session"
    static let callsign = "wk_callsign"
    static let peerCount = "wk_peers"
    static let updatedAt = "wk_updated_at"
    static let modeLabel = "wk_mode_label"
    static let statusLine = "wk_status_line"
    static let actionLabel = "wk_action_label"
    static let peersLabel = "wk_peers_label"
    static let isRtl = "wk_rtl"
    static let isLight = "wk_light"
}

/// Mirror of Dart's `HomeWidgetSession`. Raw values are the Dart enum's
/// `name`, which is what gets published.
enum Session: String {
    case setup
    case idle
    case connecting
    case listening
    case receiving
    case onAir
    case muted
    case reconnecting
    case down

    /// Everything from `connecting` on is a session the app is holding open.
    var isLive: Bool { self != .setup && self != .idle }
}

/// Everything the widget draws, as last published by the app.
///
/// Display strings arrive pre-localized — the app owns the fa/en ARB files and
/// renders them at publish time, so the extension carries no copy of its own
/// and follows the in-app language rather than the system one.
struct TarkState {
    var session: Session
    var callsign: String
    var peerCount: Int
    var modeLabel: String
    var statusLine: String
    var actionLabel: String
    var peersLabel: String
    var isRtl: Bool
    var isLight: Bool
    /// Publish time (epoch ms). Doubles as the launch nonce — see `widgetURL`.
    var updatedAt: Int64

    /// Must match `HomeWidgetIds.appGroup` in Dart, plus both entitlements files.
    static let appGroup = "group.com.b1101.tark"

    /// How long a "live" claim is trusted. The app publishes on every state
    /// change and on a clean exit, but a process killed by the OS never gets
    /// to publish `idle` — without this the home screen would keep offering a
    /// channel that died hours ago.
    static let liveTTL: TimeInterval = 90

    /// What a widget shows before the app has ever published — also the
    /// fallback if the App Group is misconfigured, in which case there is no
    /// state to read and prompting setup is the useful thing to do.
    static let placeholder = TarkState(
        session: .setup,
        callsign: "Tark",
        peerCount: 0,
        modeLabel: "",
        statusLine: "",
        actionLabel: "",
        peersLabel: "",
        isRtl: false,
        isLight: false,
        updatedAt: 0
    )

    static func read(now: Date = Date()) -> TarkState {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let rawSession = defaults.string(forKey: Keys.session)
        else { return placeholder }

        let updatedAt = (defaults.object(forKey: Keys.updatedAt) as? NSNumber)?.int64Value ?? 0
        var session = Session(rawValue: rawSession) ?? .idle

        // Stale "live" state is demoted rather than shown. The timeline is
        // scheduled to refresh right when this expires (see Provider), so a
        // widget corrects itself even if the app never runs again.
        let age = now.timeIntervalSince1970 - Double(updatedAt) / 1000
        if session.isLive && (updatedAt <= 0 || age > liveTTL) {
            session = .idle
        }

        return TarkState(
            session: session,
            callsign: defaults.string(forKey: Keys.callsign) ?? "",
            peerCount: (defaults.object(forKey: Keys.peerCount) as? NSNumber)?.intValue ?? 0,
            modeLabel: defaults.string(forKey: Keys.modeLabel) ?? "",
            statusLine: defaults.string(forKey: Keys.statusLine) ?? "",
            actionLabel: defaults.string(forKey: Keys.actionLabel) ?? "",
            peersLabel: defaults.string(forKey: Keys.peersLabel) ?? "",
            isRtl: defaults.bool(forKey: Keys.isRtl),
            isLight: defaults.bool(forKey: Keys.isLight),
            updatedAt: updatedAt
        )
    }

    /// When this state stops being trustworthy, so the timeline can be told
    /// exactly when to look again instead of polling.
    var staleAt: Date {
        guard session.isLive, updatedAt > 0 else {
            // Nothing time-sensitive about a resting widget; check back
            // occasionally purely as a backstop.
            return Date().addingTimeInterval(3600)
        }
        return Date(timeIntervalSince1970: Double(updatedAt) / 1000 + TarkState.liveTTL)
    }
}

/// The app's two palettes, duplicated for the extension.
///
/// Same values as `AppPalette` in lib/core/theme/app_colors.dart. The widget
/// follows the *app's* theme setting rather than the system's, so this can't
/// use asset-catalog appearance variants either.
struct Palette {
    let background: Color
    let surface: Color
    let card: Color
    let cardEdge: Color
    let border: Color
    /// Unlit dial ticks. Not `border`: that tone is tuned for hairlines against
    /// a card, and on the light palette it all but vanished on the instrument
    /// face. Mirrors `WidgetPalette.tickIdle` on Android.
    let tickIdle: Color
    let amber: Color
    let amberDim: Color
    let red: Color
    let green: Color
    let textPrimary: Color
    let textSecondary: Color

    /// "Night radio" — gunmetal slate against a hot orange accent.
    static let dark = Palette(
        background: Color(hex: 0x0B0E11),
        surface: Color(hex: 0x13171C),
        card: Color(hex: 0x1A2027),
        cardEdge: Color(hex: 0x0F1317),
        border: Color(hex: 0x2D343D),
        tickIdle: Color(hex: 0x3E4753),
        amber: Color(hex: 0xF5853F),
        amberDim: Color(hex: 0xD9661F),
        red: Color(hex: 0xEF5350),
        green: Color(hex: 0x4CAF50),
        textPrimary: Color(hex: 0xE9EDF1),
        textSecondary: Color(hex: 0x8B939D)
    )

    /// "Field radio" — warm paper and brass.
    static let light = Palette(
        background: Color(hex: 0xF6F1E7),
        surface: Color(hex: 0xEFE8D8),
        card: Color(hex: 0xFFFDF7),
        cardEdge: Color(hex: 0xEFE8D8),
        border: Color(hex: 0xE0D5BD),
        tickIdle: Color(hex: 0xB9A987),
        amber: Color(hex: 0xB26B00),
        amberDim: Color(hex: 0x8A5200),
        red: Color(hex: 0xC62828),
        green: Color(hex: 0x2E7D32),
        textPrimary: Color(hex: 0x2A2418),
        textSecondary: Color(hex: 0x857A64)
    )

    static func of(_ isLight: Bool) -> Palette { isLight ? .light : .dark }

    /// The accent representing `session` — drives the dial and status text.
    func accent(for session: Session) -> Color {
        switch session {
        case .onAir, .down: return red
        case .receiving: return green
        case .muted: return textSecondary
        case .reconnecting: return amberDim
        case .connecting, .listening, .idle, .setup: return amber
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

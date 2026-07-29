import Foundation
import SwiftUI
import WidgetKit

/// Vazirmatn, the family the app itself uses, bundled with the extension.
///
/// The names are PostScript names (read out of the TTFs' name tables), which
/// is what `Font.custom` matches on — the family name alone silently falls
/// back to the system font for the non-regular weights. The system default
/// would otherwise render the widget in a different typeface from every
/// screen it launches into, and has no Persian weights at all.
enum Vazir {
    static func bold(_ size: CGFloat) -> Font { .custom("Vazirmatn-Bold", size: size) }
    static func extraBold(_ size: CGFloat) -> Font { .custom("Vazirmatn-ExtraBold", size: size) }
    static func medium(_ size: CGFloat) -> Font { .custom("Vazirmatn-Medium", size: size) }
}

// MARK: - Timeline

struct TarkEntry: TimelineEntry {
    let date: Date
    let state: TarkState
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> TarkEntry {
        TarkEntry(date: Date(), state: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TarkEntry) -> Void) {
        completion(TarkEntry(date: Date(), state: TarkState.read()))
    }

    /// A single entry, refreshed when the app pushes an update
    /// (`WidgetCenter.reloadTimelines`, driven by `HomeWidgetService.publish`).
    ///
    /// The scheduled reload exists only as a backstop: it fires exactly when
    /// the current state goes stale, so a session whose app was killed stops
    /// claiming to be live without needing the app to run again. Nothing here
    /// polls — an idle widget schedules an hour out.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TarkEntry>) -> Void) {
        let state = TarkState.read()
        // Never ask for a reload in the past, or sooner than WidgetKit will
        // honour anyway.
        let next = max(state.staleAt, Date().addingTimeInterval(60))
        completion(
            Timeline(
                entries: [TarkEntry(date: Date(), state: state)],
                policy: .after(next)
            )
        )
    }
}

// MARK: - Dial

/// The hero graphic: a radio dial that reads as a signal scope.
///
/// Kept to few layers on purpose, matching DialRenderer.kt. An earlier pass
/// also drew a needle and sonar rings; at the size this renders at, the needle
/// crossed the gauge arc and read as a rendering glitch, and the rings were
/// invisible clutter. A gauge is legible at a glance because it has one
/// moving part.
///
/// Nothing animates — a home-screen widget is a static snapshot the system
/// re-renders only on a timeline reload — so "live" is carried by weight,
/// bloom and how far the gauge swings rather than by motion.
struct Dial: View {
    let state: TarkState
    let palette: Palette

    /// Arc the gauge sweeps through, leaving a gap at the top like a VU meter.
    private static let sweepDegrees = 320.0
    private static let ticks = 40

    private var accent: Color { palette.accent(for: state.session) }

    private var bloom: Double {
        switch state.session {
        case .onAir: return 0.55
        case .receiving: return 0.44
        case .listening: return 0.26
        case .connecting: return 0.22
        case .reconnecting, .down: return 0.18
        case .muted: return 0.10
        case .idle, .setup: return 0.16
        }
    }

    /// How far round the dial this state sits, 0..1.
    private var level: Double {
        switch state.session {
        case .onAir: return 1
        case .receiving: return 0.78
        case .listening: return 0.52
        case .muted: return 0.34
        case .connecting, .reconnecting: return 0.24
        case .down: return 0.12
        case .idle, .setup: return 0.08
        }
    }

    /// Lit rim ticks, tracking the roster. Capped at two-thirds so the dial
    /// keeps reading as an instrument rather than a full ring.
    private var litTicks: Int {
        guard state.session.isLive else { return 0 }
        return min(Dial.ticks * 2 / 3, 5 + state.peerCount * 5)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Blurred disc rather than a gradient approximation of one —
                // the falloff is what stops the dial looking like flat vector.
                Circle()
                    .fill(accent.opacity(bloom))
                    .frame(width: size * 0.62)
                    .blur(radius: size * 0.13)

                // Recessed instrument face.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [palette.surface, palette.background]),
                            center: UnitPoint(x: 0.5, y: 0.43),
                            startRadius: 0,
                            endRadius: size * 0.5
                        )
                    )
                    .frame(width: size * 0.88)

                // Machined bezel: bright through the top-left, falling away
                // opposite, so the ring catches light like turned metal.
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                palette.tickIdle.opacity(0.35),
                                state.session.isLive ? accent.opacity(0.55) : palette.tickIdle,
                                palette.tickIdle.opacity(0.9),
                                palette.tickIdle.opacity(0.25),
                                palette.tickIdle.opacity(0.35),
                            ]),
                            center: .center
                        ),
                        lineWidth: size * 0.027
                    )
                    .frame(width: size * 0.94)

                // Rim ticks, longer every fourth.
                ForEach(0..<Dial.ticks, id: \.self) { i in
                    let major = i % 4 == 0
                    Capsule()
                        .fill(i < litTicks ? accent : palette.tickIdle)
                        .opacity(i < litTicks ? 1 : (major ? 0.92 : 0.71))
                        .frame(
                            width: major ? size * 0.0125 : size * 0.007,
                            height: major ? size * 0.061 : size * 0.035
                        )
                        .offset(y: -size * 0.395)
                        .rotationEffect(.degrees(Double(i) * (360.0 / Double(Dial.ticks))))
                }

                // Gauge track + lit arc. The track is what stops a short
                // reading looking like a broken ring, and gives idle a shape.
                Group {
                    Circle()
                        .trim(from: 0, to: Dial.sweepDegrees / 360)
                        .stroke(
                            accent.opacity(state.session.isLive ? 0.16 : 0.12),
                            style: StrokeStyle(lineWidth: size * 0.04, lineCap: .round)
                        )
                    if state.session.isLive {
                        Circle()
                            .trim(from: 0, to: Dial.sweepDegrees * level / 360)
                            .stroke(
                                accent.opacity(0.5),
                                style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round)
                            )
                            .blur(radius: size * 0.022)
                    }
                    Circle()
                        .trim(from: 0, to: Dial.sweepDegrees * level / 360)
                        .stroke(
                            state.session.isLive ? accent : accent.opacity(0.55),
                            style: StrokeStyle(lineWidth: size * 0.04, lineCap: .round)
                        )
                }
                .frame(width: size * 0.59)
                .rotationEffect(.degrees(-90))

                // Center puck.
                Circle().fill(palette.card).frame(width: size * 0.28)
                Circle()
                    .stroke(accent.opacity(0.45), lineWidth: size * 0.0085)
                    .frame(width: size * 0.28)
                Circle()
                    .fill(accent)
                    .opacity(state.session.isLive ? 1 : 0.59)
                    .frame(width: size * 0.147)

                if state.session == .muted {
                    Capsule()
                        .fill(palette.red)
                        .frame(width: size * 0.02, height: size * 0.32)
                        .rotationEffect(.degrees(45))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The slim bar strip under the status line — a voice-level readout.
///
/// Deterministic by design (mirrors WaveformRenderer.kt): the envelope is a
/// fixed sum of sines, not random, so consecutive reloads redraw identically.
/// A widget repaints at unpredictable moments, and a randomized waveform would
/// visibly reshuffle for no reason, which reads as broken rather than lively.
struct LevelStrip: View {
    let state: TarkState
    let palette: Palette

    private static let bars = 13

    private var amplitude: Double {
        switch state.session {
        case .onAir: return 1
        case .receiving: return 0.82
        case .listening: return 0.34
        case .connecting, .reconnecting: return 0.22
        case .muted: return 0.14
        case .down: return 0.10
        case .idle, .setup: return 0.16
        }
    }

    var body: some View {
        GeometryReader { geo in
            let accent = palette.accent(for: state.session)
            let live = state.session.isLive
            let barWidth = geo.size.width / (Double(LevelStrip.bars) * 1.75 - 0.75)
            HStack(spacing: barWidth * 0.75) {
                ForEach(0..<LevelStrip.bars, id: \.self) { i in
                    let t = Double(i) / Double(LevelStrip.bars - 1)
                    let shape = abs(sin(t * 9.4) * 0.6 + sin(t * 3.1 + 1.7) * 0.4)
                    let envelope = 0.45 + 0.55 * sin(t * .pi)
                    // Amplitude scales the bar *range*, not a fixed one, so the
                    // envelope still shows when the channel is quiet.
                    let h = geo.size.height * (0.20 + 0.72 * amplitude) * shape * envelope
                        + geo.size.height * 0.09
                    RoundedRectangle(cornerRadius: barWidth * 0.3, style: .continuous)
                        .fill((live ? accent : palette.tickIdle).opacity(envelope * (live ? 1 : 0.8)))
                        .frame(width: barWidth, height: min(h, geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Faces

/// Small: the dial carries the message, with one line of status under it.
struct SmallFace: View {
    let state: TarkState
    let palette: Palette

    var body: some View {
        VStack(spacing: 5) {
            Dial(state: state, palette: palette)
                .frame(maxHeight: .infinity)
            Text(state.statusLine)
                .font(Vazir.extraBold(13))
                .tracking(0.5)
                .foregroundColor(palette.accent(for: state.session))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !state.modeLabel.isEmpty {
                Text(state.modeLabel)
                    .font(Vazir.bold(9))
                    .tracking(1.1)
                    .foregroundColor(palette.textSecondary)
                    .lineLimit(1)
            }
        }
        // Modest, because iOS 17+ adds its own content margins on top (see
        // TarkWidget.body) — enough to breathe on iOS 14-16 without looking
        // over-inset on 17.
        .padding(10)
    }
}

/// Medium: the full console — dial, callsign, status, peers, action pill.
///
/// No mute/end here. Unlike Android, an iOS widget can't reach into a
/// backgrounded app to change a running session; an interactive button could
/// only deep-link, and a control that opens the app to mute is worse than the
/// honest "open the app" the whole tile already does.
struct MediumFace: View {
    let state: TarkState
    let palette: Palette

    private var accent: Color { palette.accent(for: state.session) }

    var body: some View {
        HStack(spacing: 14) {
            Dial(state: state, palette: palette)
                .frame(width: 78, height: 78)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.callsign.isEmpty ? "Tark" : state.callsign)
                        .font(Vazir.bold(15))
                        .foregroundColor(palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !state.modeLabel.isEmpty {
                        Text(state.modeLabel)
                            .font(Vazir.bold(9))
                            .tracking(1.1)
                            .foregroundColor(palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(palette.surface)
                                    .overlay(Capsule().stroke(palette.border, lineWidth: 1))
                            )
                    }
                }

                Text(state.statusLine)
                    .font(Vazir.extraBold(16))
                    .tracking(0.6)
                    .foregroundColor(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                LevelStrip(state: state, palette: palette)
                    .frame(height: 18)
                    .padding(.top, 4)

                if !state.peersLabel.isEmpty {
                    Text(state.peersLabel)
                        .font(Vazir.medium(11))
                        .foregroundColor(palette.textSecondary)
                        .lineLimit(1)
                        .padding(.top, 3)
                }

                Spacer(minLength: 4)

                Text(state.actionLabel)
                    .font(Vazir.extraBold(12))
                    .tracking(1.2)
                    .foregroundColor(palette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [palette.amber, palette.amberDim],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            }
        }
        .padding(12)
    }
}

// MARK: - Entry view

struct TarkWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TarkEntry

    private var palette: Palette { Palette.of(entry.state.isLight) }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallFace(state: entry.state, palette: palette)
            default:
                MediumFace(state: entry.state, palette: palette)
            }
        }
        // The app publishes an explicit RTL flag rather than letting the
        // extension guess from the system locale — in-app language is a
        // setting, and the two can disagree.
        .environment(\.layoutDirection, entry.state.isRtl ? .rightToLeft : .leftToRight)
        .widgetURL(WidgetLink.url(for: entry.state))
        .tarkContainerBackground(palette: palette)
    }
}

/// The deep link a tap fires.
enum WidgetLink {
    /// Must stay in step with `HomeWidgetLaunch.uriFor` in Dart.
    ///
    /// The `homeWidget` query item is not ours — it is how the home_widget
    /// plugin's iOS side recognises a URL as a widget launch at all
    /// (`isWidgetUrl`); without it the tap opens the app but Dart never hears
    /// about it. The `n` nonce is the app's last publish timestamp, which
    /// Dart consumes once so a replayed launch can't reopen the mic.
    static func url(for state: TarkState) -> URL? {
        let intent = state.session == .setup ? "setup" : "goLive"
        return URL(string: "tark://widget/\(intent)?n=\(state.updatedAt)&homeWidget=true")
    }
}

/// iOS 17 requires widget backgrounds to go through `containerBackground`;
/// earlier versions have no such API and need a plain background.
extension View {
    @ViewBuilder
    func tarkContainerBackground(palette: Palette) -> some View {
        let gradient = LinearGradient(
            colors: [palette.card, palette.cardEdge],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { gradient }
        } else {
            self.background(gradient)
        }
    }
}

// MARK: - Widget

struct TarkWidget: Widget {
    /// Must match `HomeWidgetIds.iOSWidgetKind` in Dart — it's what
    /// `HomeWidget.updateWidget(iOSName:)` reloads.
    let kind = "TarkWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            TarkWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Tark Channel")
        .description("Jump straight into your channel, and see who's on air.")
        .supportedFamilies([.systemSmall, .systemMedium])
        // Content margins are deliberately left at their defaults. Turning
        // them off needs iOS 17's contentMarginsDisabled(), and a
        // WidgetConfiguration can't be branched on availability the way a
        // View can (the two paths are different opaque types, and there is no
        // AnyWidgetConfiguration to erase them into). The faces keep their own
        // modest padding instead, and the card itself still reaches the tile
        // edges because it is painted by the container background.
    }
}

@main
struct TarkWidgetBundle: WidgetBundle {
    var body: some Widget {
        TarkWidget()
    }
}

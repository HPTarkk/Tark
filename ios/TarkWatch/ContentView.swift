import SwiftUI

private let tarkOrange = Color(red: 1.0, green: 0.47, blue: 0.19)
private let tarkCard = Color(red: 0.09, green: 0.11, blue: 0.15)
private let tarkBackground = Color(red: 0.025, green: 0.035, blue: 0.05)
private let tarkGreen = Color(red: 0.34, green: 0.83, blue: 0.42)
private let tarkRed = Color(red: 1.0, green: 0.30, blue: 0.36)

struct ContentView: View {
  @EnvironmentObject private var model: WatchSessionModel

  var body: some View {
    TabView {
      RoomControlView()
      RoomStatusView()
    }
    .tabViewStyle(.verticalPage)
    .background(tarkBackground)
    .environment(\.layoutDirection, .rightToLeft)
  }
}

private struct RoomControlView: View {
  @EnvironmentObject private var model: WatchSessionModel
  @State private var confirmLeave = false

  var body: some View {
    VStack(spacing: 6) {
      VStack(spacing: 1) {
        Text("اتاق ترک").font(.headline).fontWeight(.bold)
        Text(statusText)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(statusColor)
      }

      Button {
        if model.room.isLive { model.send("toggle_mute") }
        else { model.requestState() }
      } label: {
        ZStack {
          TarkRadar(active: model.room.isLive && !model.room.isMuted)
          VStack(spacing: 2) {
            Image(systemName: model.room.isMuted ? "mic.slash.fill" : "mic.fill")
              .font(.system(size: 34, weight: .medium))
              .foregroundStyle(model.room.isMuted ? .secondary : tarkOrange)
            Text(model.room.isLive ? (model.room.isMuted ? "میکروفن ساکت" : "آماده صحبت") : "اتاق فعال نیست")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 126, height: 126)
      }
      .buttonStyle(.plain)

      HStack(spacing: 13) {
        WatchActionButton(
          title: model.room.isMuted ? "باز کن" : "ساکت",
          systemName: model.room.isMuted ? "mic.fill" : "mic.slash.fill",
          tint: model.room.isMuted ? tarkGreen : .white
        ) { model.send("toggle_mute") }

        WatchActionButton(title: "اتصال", systemName: "arrow.clockwise", tint: tarkOrange) {
          model.send("reconnect")
        }

        WatchActionButton(title: "خروج", systemName: "rectangle.portrait.and.arrow.right", tint: tarkRed) {
          confirmLeave = true
        }
      }
    }
    .padding(.horizontal, 8)
    .alert("داری میری؟", isPresented: $confirmLeave) {
      Button("بیخیال", role: .cancel) {}
      Button("خروج", role: .destructive) { model.send("leave") }
    } message: {
      Text("اگه بری، ارتباطت با بچه‌های این کانال قطع میشه.")
    }
  }

  private var statusText: String {
    if !model.phoneReachable { return "گوشی در دسترس نیست" }
    if model.room.isReconnecting { return "در حال اتصال مجدد" }
    return model.room.statusLine.isEmpty ? (model.room.isLive ? "متصل" : "گوشی را باز کن") : model.room.statusLine
  }

  private var statusColor: Color {
    if !model.phoneReachable { return .secondary }
    if model.room.isReconnecting { return tarkOrange }
    return model.room.isLive ? tarkGreen : .secondary
  }
}

private struct RoomStatusView: View {
  @EnvironmentObject private var model: WatchSessionModel

  var body: some View {
    ScrollView {
      VStack(spacing: 7) {
        Text("وضعیت اتاق").font(.headline).fontWeight(.bold)
        StatusRow(
          title: model.room.callsign.isEmpty ? "تَرک" : model.room.callsign,
          subtitle: model.room.isMuted ? "میکروفن ساکت" : "میکروفن روشن",
          color: model.room.isMuted ? .secondary : tarkGreen
        )
        StatusRow(
          title: model.room.talker.isEmpty ? "کانال آرام است" : model.room.talker,
          subtitle: model.room.talker.isEmpty ? "در حال گوش دادن" : "در حال صحبت",
          color: model.room.talker.isEmpty ? .secondary : tarkOrange
        )
        StatusRow(
          title: "\(model.room.peerCount) عضو",
          subtitle: model.room.modeLabel.isEmpty ? "گوشی متصل" : model.room.modeLabel,
          color: model.room.isLive ? tarkGreen : .secondary
        )
        Button { model.requestState() } label: {
          Label("تازه‌سازی", systemImage: "arrow.clockwise")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tarkOrange)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 6)
    }
  }
}

private struct TarkRadar: View {
  let active: Bool

  var body: some View {
    TimelineView(.animation) { timeline in
      let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
      ZStack {
        Circle().fill(tarkOrange.opacity(active ? 0.06 + phase * 0.06 : 0.035))
        Circle().stroke(tarkOrange.opacity(0.32), lineWidth: 1)
        Circle().stroke(tarkOrange.opacity(0.45), style: StrokeStyle(lineWidth: 5, dash: [1.2, 4]))
          .padding(18)
        ForEach(0..<8, id: \.self) { index in
          Capsule()
            .fill(tarkOrange.opacity(0.26))
            .frame(width: 1, height: 9)
            .offset(y: -55)
            .rotationEffect(.degrees(Double(index) * 45))
        }
      }
    }
  }
}

private struct WatchActionButton: View {
  let title: String
  let systemName: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 2) {
        ZStack {
          Circle().fill(tarkCard)
          Circle().stroke(tint.opacity(0.45), lineWidth: 1)
          Image(systemName: systemName).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
        }
        .frame(width: 40, height: 40)
        Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(tint)
      }
    }
    .buttonStyle(.plain)
  }
}

private struct StatusRow: View {
  let title: String
  let subtitle: String
  let color: Color

  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(color).frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 12, weight: .bold)).lineLimit(1)
        Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(tarkCard, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.24), lineWidth: 1))
  }
}

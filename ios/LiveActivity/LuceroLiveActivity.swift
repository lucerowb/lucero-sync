import ActivityKit
import SwiftUI
import WidgetKit

private let amber = Color(red: 1, green: 0.635, blue: 0.29)
private let ink = Color(red: 0.063, green: 0.051, blue: 0.039)
private let paper = Color(red: 0.949, green: 0.910, blue: 0.847)
private let dim = Color(red: 0.788, green: 0.733, blue: 0.647)
private let green = Color(red: 0.435, green: 0.812, blue: 0.486)

@main
struct LuceroWidgets: WidgetBundle {
  var body: some Widget {
    LuceroLiveActivity()
  }
}

struct LuceroLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LuceroActivityAttributes.self) { context in
      LockScreenView(state: context.state)
        .activityBackgroundTint(ink)
        .activitySystemActionForegroundColor(amber)
    } dynamicIsland: { context in
      let s = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          DirectionIcon(state: s).font(.title2).padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(s.percentText).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(amber)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(s.headline).font(.headline).foregroundStyle(paper).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            ProgressBar(state: s)
            Text(s.detail).font(.caption).foregroundStyle(dim).lineLimit(1)
          }
          .padding(.horizontal, 4)
        }
      } compactLeading: {
        DirectionIcon(state: s)
      } compactTrailing: {
        if s.fraction >= 0 {
          Text(s.percentText).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(amber)
        } else {
          Text("\(s.count)").font(.caption2.weight(.semibold)).foregroundStyle(amber)
        }
      } minimal: {
        if s.fraction >= 0 {
          ProgressView(value: s.fraction).progressViewStyle(.circular).tint(amber)
        } else {
          DirectionIcon(state: s)
        }
      }
      .keylineTint(amber)
    }
  }
}

private struct LockScreenView: View {
  let state: LuceroActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Star().frame(width: 22, height: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.headline).font(.headline).foregroundStyle(paper).lineLimit(1)
          Text(state.detail).font(.subheadline).foregroundStyle(dim).lineLimit(1)
        }
        Spacer()
        Text(state.finished ? "Done" : state.percentText)
          .font(.title3.monospacedDigit().weight(.semibold))
          .foregroundStyle(state.finished ? green : amber)
      }
      ProgressBar(state: state)
    }
    .padding(16)
  }
}

private struct ProgressBar: View {
  let state: LuceroActivityAttributes.ContentState
  var body: some View {
    if state.fraction >= 0 || state.finished {
      ProgressView(value: state.finished ? 1 : state.fraction).tint(state.finished ? green : amber)
    } else {
      ProgressView().progressViewStyle(.linear).tint(amber)
    }
  }
}

private struct DirectionIcon: View {
  let state: LuceroActivityAttributes.ContentState
  var body: some View {
    Image(systemName: state.finished ? "checkmark.circle.fill" : (state.sending ? "arrow.up.circle.fill" : "arrow.down.circle.fill"))
      .foregroundStyle(state.finished ? green : amber)
  }
}

/// The Lucero four-pointed star.
private struct Star: View {
  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = g.size.height
      ZStack {
        Path { p in
          let pts: [(CGFloat, CGFloat)] = [(32, 6), (36.6, 27.4), (58, 32), (36.6, 36.6), (32, 58), (27.4, 36.6), (6, 32), (27.4, 27.4)]
          for (i, pt) in pts.enumerated() {
            let c = CGPoint(x: pt.0 / 64 * w, y: pt.1 / 64 * h)
            i == 0 ? p.move(to: c) : p.addLine(to: c)
          }
          p.closeSubpath()
        }
        .fill(amber)
        Circle().fill(Color(red: 1, green: 0.957, blue: 0.894)).frame(width: w * 0.12, height: h * 0.12)
      }
    }
  }
}

extension LuceroActivityAttributes.ContentState {
  var percentText: String { fraction >= 0 ? "\(Int((fraction * 100).rounded()))%" : "…" }
}

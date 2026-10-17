import HeadroomCore
import SwiftUI

/// The agents' total over the last 60 minutes: an ordered-dither area in ink under a 1 px ink line, the warning and
/// critical lines as hair rules labelled in titanium in a gutter, and the current value as one GT blue dot.
/// This is the window's one material.
struct HistoryChart: View {
    var points: [HistoryPoint]
    var warning: Double
    var critical: Double
    var now: Date
    var width: CGFloat

    @Environment(\.colorScheme) private var scheme

    static let plotHeight: CGFloat = 84
    static let gutter: CGFloat = 100

    var plotWidth: CGFloat { width - HistoryChart.gutter }

    var body: some View {
        let w = Int(plotWidth), h = Int(HistoryChart.plotHeight)
        let start = now.timeIntervalSince1970 - History.window
        let peak = points.map(\.agents).max() ?? 0
        let top = max(critical * 1.15, peak * 1.08, 1)
        func y(_ gb: Double) -> CGFloat { CGFloat(h) * CGFloat(1 - min(gb, top) / top) }
        // The value under each column: the last sample at or before the column's time.
        var tops = [CGFloat?](repeating: nil, count: w)
        var j = 0
        for x in 0..<w {
            let t = start + (Double(x) + 0.5) / Double(w) * History.window
            while j + 1 < points.count, points[j + 1].t <= t { j += 1 }
            if let first = points.first, t >= first.t, j < points.count { tops[x] = y(points[j].agents) }
        }
        let columnTops = tops
        let mask = Bayer.mask(width: w, height: h) { x, yy in
            guard let ty = columnTops[x], CGFloat(yy) >= ty else { return 0 }
            let depth = (CGFloat(yy) - ty) / max(1, CGFloat(h) - ty)
            return Double(0.55 - 0.4 * depth)
        }
        let yWarn = y(warning), yCrit = y(critical)
        let last = points.last.map { (x: min(plotWidth, CGFloat(($0.t - start) / History.window) * plotWidth), y: y($0.agents)) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if let mask {
                        Rectangle()
                            .fill(Tok.ink.opacity(scheme == .dark ? 0.62 : 0.7))
                            .mask(Image(decorative: mask, scale: 1).resizable().interpolation(.none))
                    }
                    Canvas { ctx, _ in
                        // Each line cuts through the dither in paper, so it stays visible over the area.
                        for ly in [yWarn, yCrit] {
                            let r = CGRect(x: 0, y: ly.rounded(.down), width: plotWidth, height: 1)
                            ctx.fill(Path(r.insetBy(dx: 0, dy: -1)), with: .color(Tok.paper))
                            ctx.fill(Path(r), with: .color(Tok.hair))
                        }
                        var line = Path()
                        var started = false
                        for x in 0..<w {
                            guard let ty = columnTops[x] else { started = false; continue }
                            let p = CGPoint(x: CGFloat(x), y: ty + 0.5)
                            if started { line.addLine(to: p) } else { line.move(to: p) }
                            started = true
                        }
                        ctx.stroke(line, with: .color(Tok.ink), lineWidth: 1)
                        if let last {
                            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3, width: 7, height: 7)), with: .color(Tok.blue))
                        }
                    }
                    if points.count < 2 {
                        Text("The chart fills in as Headroom samples.").ty(.small).foregroundStyle(Tok.titanium)
                            .padding(.top, HistoryChart.plotHeight - 18)
                    }
                }
                .frame(width: plotWidth, height: HistoryChart.plotHeight)
                ZStack(alignment: .topLeading) {
                    lineLabel("Critical \(Format.gb(critical))", y: yCrit)
                    lineLabel("Warning \(Format.gb(warning))", y: max(yWarn, yCrit + 15))
                }
                .frame(width: HistoryChart.gutter, height: HistoryChart.plotHeight, alignment: .topLeading)
            }
            // The axis labels sit at their times: 60 minutes ago at the left edge, 30 minutes at the middle with a
            // tick on the baseline, and now at the right edge.
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Tok.hair).frame(width: 1, height: 3).position(x: (plotWidth / 2).rounded(.down) + 0.5, y: -4.5)
                Text("60 min ago").fixedSize().frame(width: plotWidth, alignment: .leading)
                Text("30 min").fixedSize().position(x: plotWidth / 2, y: 7)
                Text("now").fixedSize().frame(width: plotWidth, alignment: .trailing)
            }
            .font(Ty.small.font)
            .foregroundStyle(Tok.titanium)
            .frame(width: plotWidth, height: 14, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agents' memory over the last 60 minutes, now \(Format.gb(points.last?.agents ?? 0)), peak \(Format.gb(peak)).")
    }

    func lineLabel(_ text: String, y: CGFloat) -> some View {
        Text(text).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
            .offset(x: 12, y: max(-2, y - 8))
    }
}

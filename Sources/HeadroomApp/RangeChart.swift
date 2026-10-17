import HeadroomCore
import SwiftUI

/// One bucket of the chart, placed on the plot.
struct ChartPoint {
    var x: CGFloat
    var rollup: Rollup
    var value: Double
    var average: Double
}

/// The history chart: the average as an ordered-dither area, the peak as a 1 px ink line, the warning and critical
/// lines as hair rules labelled in a gutter, and under the plot a strip that marks where the record has samples
/// and, in amber and red, the time spent at warning and critical. Gaps, such as sleep, stay empty.
struct RangeChart: View {
    var data: HistoryData
    var series: ChartSeries
    var thresholds: Thresholds
    var width: CGFloat
    var height: CGFloat = 220
    var rendering = false

    @Environment(\.colorScheme) private var scheme

    static let gutter: CGFloat = 112
    static let strip: CGFloat = 4

    var plotWidth: CGFloat { max(80, width - RangeChart.gutter) }
    var span: Double { max(60, data.to - data.from) }

    func x(_ t: Double) -> CGFloat { CGFloat((t - data.from) / span) * plotWidth }

    var points: [ChartPoint] {
        data.series.map { r in
            let s = series.span(r)
            return ChartPoint(x: x(r.t + r.seconds / 2), rollup: r, value: s.max, average: s.avg)
        }
    }

    /// The top of the scale: room above the peak and the critical line; the Mac's memory for memory in use.
    func top(_ pts: [ChartPoint]) -> Double {
        let peak = pts.map(\.value).max() ?? 0
        var top = max(peak * 1.1, 1)
        if let l = series.lines(thresholds, totalGB: data.summary?.total ?? 0) { top = max(top, l.critical * 1.12) }
        if series == .used, let total = data.summary?.total, total > 0 { top = max(total * 1.04, peak * 1.04) }
        return top
    }

    /// The value under each pixel column, interpolated between bucket centres. Neighbours further apart than
    /// two and a half buckets are not joined, so gaps stay gaps.
    static func columns(_ pts: [ChartPoint], width: Int, bucketPx: CGFloat, value: (ChartPoint) -> Double) -> [Double?] {
        var out = [Double?](repeating: nil, count: max(0, width))
        guard !pts.isEmpty, width > 0 else { return out }
        let half = max(0.75, bucketPx / 2)
        let join = max(2, bucketPx * 2.5)
        var j = -1
        for c in 0..<width {
            let cx = CGFloat(c) + 0.5
            while j + 1 < pts.count, pts[j + 1].x <= cx { j += 1 }
            if j < 0 {
                if pts[0].x - cx <= half { out[c] = value(pts[0]) }
            } else if j == pts.count - 1 {
                if cx - pts[j].x <= half { out[c] = value(pts[j]) }
            } else {
                let a = pts[j], b = pts[j + 1]
                if b.x - a.x <= join {
                    let f = Double((cx - a.x) / max(0.001, b.x - a.x))
                    out[c] = value(a) + (value(b) - value(a)) * f
                } else if cx - a.x <= half {
                    out[c] = value(a)
                } else if b.x - cx <= half {
                    out[c] = value(b)
                }
            }
        }
        return out
    }

    var body: some View {
        let pts = points
        let top = self.top(pts)
        let h = height
        let w = Int(plotWidth)
        func y(_ v: Double) -> CGFloat { h * CGFloat(1 - min(max(v, 0), top) / top) }
        let bucketPx = data.series.first.map { CGFloat($0.seconds / span) * plotWidth } ?? 1
        let peaks = RangeChart.columns(pts, width: w, bucketPx: bucketPx) { $0.value }.map { $0.map(y) }
        let avgs = RangeChart.columns(pts, width: w, bucketPx: bucketPx) { $0.average }.map { $0.map(y) }
        let mask = Bayer.mask(width: w, height: Int(h)) { cx, cy in
            guard let ty = avgs[cx], CGFloat(cy) >= ty else { return 0 }
            let depth = (CGFloat(cy) - ty) / max(1, h - ty)
            return Double(0.5 - 0.36 * depth)
        }
        let lines = series.lines(thresholds, totalGB: data.summary?.total ?? 0)
        let live = data.series.last.map { data.to - $0.end < 180 } ?? false

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    // The plot's floor, so an empty range still reads as a chart.
                    Rectangle().fill(Tok.hairSoft).frame(height: 1).offset(y: h - 1)
                    if let mask {
                        Rectangle()
                            .fill(Tok.ink.opacity(scheme == .dark ? 0.62 : 0.7))
                            .mask(Image(decorative: mask, scale: 1).resizable().interpolation(.none))
                    }
                    Canvas { ctx, _ in
                        var rules: [CGFloat] = []
                        if let lines { rules += [y(lines.warning), y(lines.critical)] }
                        if series == .used, let total = data.summary?.total { rules.append(y(total)) }
                        for ly in rules {
                            let r = CGRect(x: 0, y: ly.rounded(.down), width: plotWidth, height: 1)
                            ctx.fill(Path(r.insetBy(dx: 0, dy: -1)), with: .color(Tok.paper))
                            ctx.fill(Path(r), with: .color(Tok.hair))
                        }
                        var line = Path()
                        var started = false
                        for c in 0..<w {
                            guard let ty = peaks[c] else { started = false; continue }
                            let p = CGPoint(x: CGFloat(c) + 0.5, y: ty + 0.5)
                            if started { line.addLine(to: p) } else { line.move(to: p) }
                            started = true
                        }
                        ctx.stroke(line, with: .color(Tok.ink), lineWidth: 1)
                        if live, let last = pts.last {
                            let lx = min(plotWidth - 3.5, last.x)
                            ctx.fill(Path(ellipseIn: CGRect(x: lx - 3.5, y: y(last.value) - 3, width: 7, height: 7)), with: .color(Tok.blue))
                        }
                    }
                    if !rendering, !pts.isEmpty {
                        ChartHover(points: pts, series: series, height: h, width: plotWidth, y: y)
                    }
                    if pts.isEmpty {
                        Text("No record in \(data.range.phrase) yet. Headroom writes one line a minute while it runs.")
                            .ty(.small).foregroundStyle(Tok.titanium)
                            .padding(.top, h / 2 - 8)
                            .frame(width: plotWidth)
                    }
                }
                .frame(width: plotWidth, height: h)
                ZStack(alignment: .topLeading) {
                    if let lines {
                        gutterLabel("Critical \(Format.gb(lines.critical))", y: y(lines.critical))
                        gutterLabel("Warning \(Format.gb(lines.warning))", y: max(y(lines.warning), y(lines.critical) + 15))
                    }
                    if series == .used, let total = data.summary?.total {
                        gutterLabel("Mac \(Format.gb(total))", y: min(y(total), (lines.map { y($0.critical) } ?? h) - 15))
                    }
                    if lines == nil, series != .used, let peak = pts.map(\.value).max(), peak > 0 {
                        gutterLabel("Peak \(Format.gb(peak))", y: y(peak))
                    }
                }
                .frame(width: RangeChart.gutter, height: h, alignment: .topLeading)
            }
            levelStrip.padding(.top, 6)
            axis.padding(.top, 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    var accessibilityText: String {
        guard let s = data.summary else { return "No record in \(data.range.phrase)." }
        let sp = series.span(s)
        return "\(series.rawValue) over \(data.range.phrase): peak \(Format.gb(sp.max)), average \(Format.gb(sp.avg)). \(s.warningMinutes) minutes at warning, \(s.criticalMinutes) at critical."
    }

    func gutterLabel(_ text: String, y: CGFloat) -> some View {
        Text(text).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
            .offset(x: 12, y: max(-2, y - 8))
    }

    /// Where the record has samples, in hair, and the minutes at warning and critical, in amber and red.
    var levelStrip: some View {
        Canvas { ctx, size in
            for r in data.series {
                let x0 = max(0, x(r.t)), x1 = min(plotWidth, x(r.end))
                guard x1 > x0 else { continue }
                let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
                ctx.fill(Path(rect), with: .color(Tok.hairSoft))
                let raised = r.warningMinutes + r.criticalMinutes
                guard raised > 0 || r.level != .ok else { continue }
                // A bucket longer than a minute is coloured in proportion to its raised minutes, worst first.
                let share = r.seconds <= 60 ? 1 : min(1, Double(max(1, raised)) * 60 / r.seconds)
                let colour: Color = r.criticalMinutes > 0 || (r.seconds <= 60 && r.level == .critical) ? Tok.red : Tok.amber
                let fill = CGRect(x: x0, y: 0, width: max(1, (x1 - x0) * CGFloat(max(share, 0.15))), height: size.height)
                ctx.fill(Path(fill), with: .color(colour))
            }
        }
        .frame(width: plotWidth, height: RangeChart.strip)
        .accessibilityHidden(true)
    }

    var axis: some View {
        let ticks = TimeTicks.make(from: data.from, to: data.to, width: plotWidth)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                let tx = x(tick.t)
                Rectangle().fill(Tok.hair).frame(width: 1, height: 3).position(x: tx.rounded(.down) + 0.5, y: -6.5)
                Text(tick.label).fixedSize().position(x: min(max(tx, 24), plotWidth - 24), y: 7)
            }
        }
        .font(Ty.small.font)
        .foregroundStyle(Tok.titanium)
        .frame(width: plotWidth, height: 14, alignment: .topLeading)
    }
}

/// The time axis: ticks on whole local minutes, hours, days or months, about one every 80 points.
enum TimeTicks {
    struct Tick {
        var t: Double
        var label: String
    }

    static func make(from: Double, to: Double, width: CGFloat) -> [Tick] {
        let span = to - from
        guard span > 0, width > 0 else { return [] }
        let want = span / Double(max(3, Int(width / 80)))
        let steps: [Double] = [300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400, 172_800, 259_200, 604_800, 1_209_600]
        let cal = Calendar.current
        let f = DateFormatter()
        var out: [Tick] = []
        if let step = steps.first(where: { $0 >= want }), step < 86_400 {
            let off = Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: from)))
            var t = ((from + off) / step).rounded(.up) * step - off
            while t < to {
                let d = Date(timeIntervalSince1970: t)
                let midnight = cal.startOfDay(for: d) == d && span > 86_400
                f.dateFormat = midnight ? "EEE d" : "HH:mm"
                out.append(Tick(t: t, label: f.string(from: d)))
                t += step
            }
        } else if let step = steps.first(where: { $0 >= want }) {
            let days = Int(step / 86_400)
            var d = cal.startOfDay(for: Date(timeIntervalSince1970: from))
            if d.timeIntervalSince1970 < from, let next = cal.date(byAdding: .day, value: 1, to: d) { d = next }
            f.dateFormat = days >= 7 ? "MMM d" : "EEE d"
            while d.timeIntervalSince1970 < to {
                out.append(Tick(t: d.timeIntervalSince1970, label: f.string(from: d)))
                guard let next = cal.date(byAdding: .day, value: days, to: d) else { break }
                d = next
            }
        } else {
            // Months, for a record longer than a few months.
            var c = cal.dateComponents([.year, .month], from: Date(timeIntervalSince1970: from))
            c.month = (c.month ?? 1) + 1
            var d = cal.date(from: c) ?? Date(timeIntervalSince1970: to)
            let every = max(1, Int((want / (30 * 86_400)).rounded(.up)))
            f.dateFormat = "MMM"
            while d.timeIntervalSince1970 < to {
                let month = cal.component(.month, from: d)
                f.dateFormat = month == 1 ? "MMM yyyy" : "MMM"
                out.append(Tick(t: d.timeIntervalSince1970, label: f.string(from: d)))
                guard let next = cal.date(byAdding: .month, value: every, to: d) else { break }
                d = next
            }
        }
        return out
    }
}

/// The hover layer: a hair at the nearest bucket and a card with its time, values, level and largest sessions.
struct ChartHover: View {
    var points: [ChartPoint]
    var series: ChartSeries
    var height: CGFloat
    var width: CGFloat
    var y: (Double) -> CGFloat
    @State private var hoverX: CGFloat?

    static let cardWidth: CGFloat = 236

    var nearest: ChartPoint? {
        guard let hx = hoverX else { return nil }
        var best: ChartPoint?
        var dist = CGFloat.infinity
        for p in points {
            let d = abs(p.x - hx)
            if d < dist {
                dist = d
                best = p
            }
        }
        return dist <= 24 ? best : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverX = p.x
                    case .ended: hoverX = nil
                    }
                }
            if let p = nearest {
                Rectangle().fill(Tok.ink2).frame(width: 1, height: height).offset(x: p.x.rounded(.down))
                    .allowsHitTesting(false)
                Circle().fill(Tok.ink).frame(width: 7, height: 7).offset(x: p.x - 3.5, y: y(p.value) - 3.5)
                    .allowsHitTesting(false)
                // The card sits right of the hair, or left of it near the right edge.
                card(p)
                    .frame(width: ChartHover.cardWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: p.x + 12 + ChartHover.cardWidth > width ? p.x - 12 - ChartHover.cardWidth : p.x + 12, y: 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
    }

    func card(_ p: ChartPoint) -> some View {
        let r = p.rollup
        let f = DateFormatter()
        f.dateFormat = r.seconds >= 86_400 ? "EEE MMM d" : "MMM d, HH:mm"
        let end = DateFormatter()
        end.dateFormat = "HH:mm"
        let when = r.seconds <= 60 ? f.string(from: r.time)
            : r.seconds >= 86_400 ? f.string(from: r.time) : "\(f.string(from: r.time))\u{2013}\(end.string(from: Date(timeIntervalSince1970: r.end)))"
        return VStack(alignment: .leading, spacing: 4) {
            Text(when).ty(.small).foregroundStyle(Tok.titanium)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.gb(p.value)).ty(.figure).foregroundStyle(Tok.ink)
                Text(r.seconds > 60 ? "\(series.rawValue) peak, \(Format.gb(p.average)) average" : series.rawValue)
                    .ty(.small).foregroundStyle(Tok.ink2)
            }
            if r.level != .ok || r.warningMinutes + r.criticalMinutes > 0 {
                HStack(spacing: 6) {
                    Dot(level: r.level, size: 6)
                    Text(levelPhrase(r)).ty(.small).foregroundStyle(Tok.ink2)
                }
            }
            ForEach(Array(r.sessions.prefix(3).enumerated()), id: \.offset) { _, h in
                HStack(spacing: 6) {
                    if let app = h.app { AppMark(app: app, size: 12) }
                    Text(h.name).ty(.small).foregroundStyle(Tok.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.gb(h.gb)).ty(.smallNumber).foregroundStyle(Tok.ink2)
                }
            }
            if r.seconds > 60, !r.sessions.isEmpty {
                Text("Largest sessions at the agents' peak, \(end.string(from: r.peakTime))").ty(.small).foregroundStyle(Tok.titanium)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: ChartHover.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tok.paper))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tok.hair, lineWidth: 1))
    }

    func levelPhrase(_ r: Rollup) -> String {
        if r.seconds <= 60 { return r.level.title }
        var parts: [String] = []
        if r.criticalMinutes > 0 { parts.append("\(Duration.text(minutes: r.criticalMinutes)) critical") }
        if r.warningMinutes > 0 { parts.append("\(Duration.text(minutes: r.warningMinutes)) at warning") }
        return parts.isEmpty ? r.level.title : parts.joined(separator: ", ")
    }
}

enum Duration {
    /// "3 d 4 h", "2 h 5 min", "45 min", "0 min".
    static func text(minutes m: Int) -> String {
        if m >= 48 * 60 { return (m / 60) % 24 == 0 ? "\(m / 1440) d" : "\(m / 1440) d \((m / 60) % 24) h" }
        if m >= 60 { return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min" }
        return "\(m) min"
    }
}

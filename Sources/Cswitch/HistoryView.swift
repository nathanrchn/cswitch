import CswitchCore
import SwiftUI

struct HistoryView: View {
    let report: HistoryReport
    let loading: Bool
    @State private var period: HistoryPeriod = .week
    @State private var hoveredDate: Date?

    var body: some View {
        let totals = report.totals(period)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token history").font(.system(size: 11, weight: .medium))
                if loading { ProgressView().controlSize(.mini) }
                Spacer()
                Picker("History period", selection: $period) {
                    ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.mini)
            }
            if report.loaded {
                if period == .all { activityGrid }
                else { dailyChart(days: period == .week ? 7 : 30) }
                Text(chartCaption).font(.system(size: 8)).foregroundStyle(.tertiary)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.tokens(totals.total)).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("total tokens, including cache").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.help("Input \(Self.tokens(totals.input)) · Output \(Self.tokens(totals.output))\nCache read \(Self.tokens(totals.cacheRead)) · Cache write \(Self.tokens(totals.cacheWrite))\n\(totals.requests) unique requests")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(cost(totals)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        Text(totals.unknownModels.isEmpty ? "estimated API cost" : "partial API estimate")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }.help(costExplanation(totals))
                }
                tokenBreakdown(totals)
            } else {
                Text(loading ? "Reading saved Claude Code activity…" : "History is unavailable. Refresh to try again.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("All accounts · \(report.deviceCount) devices")
                if !report.staleDevices.isEmpty { Text("· cached / incomplete").help("History unavailable or stale on: " + report.staleDevices.joined(separator: ", ")) }
                if report.unreadable > 0 { Image(systemName: "exclamationmark.triangle").help("Some history records or files could not be read. Totals may be incomplete.") }
                if report.cacheFailure { Image(systemName: "externaldrive.badge.exclamationmark").help("History was read but its cache could not be saved.") }
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .overlayPreferenceValue(HistoryHoverPreference.self) { target in
                GeometryReader { geometry in
                    if let target, target.date == hoveredDate {
                        let bounds = geometry[target.bounds]
                        let width: CGFloat = 260, height: CGFloat = 160
                        let x = min(max(8, bounds.midX - width / 2), max(8, geometry.size.width - width - 8))
                        let y = min(bounds.maxY + 8, max(8, geometry.size.height - height - 8))
                        dayDetails(target.date)
                            .frame(width: width, height: height)
                            .nativeHoverSurface()
                            .offset(x: x, y: y)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .onChange(of: period) { _, _ in hoveredDate = nil }
            .onDisappear { hoveredDate = nil }
    }

    private var chartCaption: String {
        guard period != .all else { return "Daily activity · past year" }
        let start = period.start().formatted(.dateTime.month(.abbreviated).day())
        let end = Date().formatted(.dateTime.month(.abbreviated).day())
        return "Daily activity · \(start) – \(end)"
    }

    private func tokenBreakdown(_ totals: TokenTotals) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                tokenMetric("Input", value: totals.input)
                tokenMetric("Output", value: totals.output)
                tokenMetric("Cached", value: totals.cacheRead + totals.cacheWrite)
            }
            HStack(spacing: 5) {
                Text("Cache read \(Self.tokens(totals.cacheRead))")
                Text("·")
                Text("Cache write \(Self.tokens(totals.cacheWrite))")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
                .help("Cached = reads + writes. Total tokens = input + output + cached.")
        }
    }

    private func tokenMetric(_ title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(Self.tokens(value)).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help("\(title): \(value.formatted()) tokens")
    }

    private func dailyChart(days: Int) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dates = (0..<days).map { calendar.date(byAdding: .day, value: $0 - days + 1, to: today)! }
        let maximum = max(1, dates.map { report.days[$0]?.total ?? 0 }.max() ?? 1)
        let spacing: CGFloat = days == 7 ? 8 : 3
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(dates, id: \.self) { date in
                    let total = report.days[date]?.total ?? 0
                    let height = total == 0 ? 2 : max(3, 62 * CGFloat(total) / CGFloat(maximum))
                    RoundedRectangle(cornerRadius: days == 7 ? 3 : 1)
                        .fill(total > 0 ? Color.accentColor : Color.primary.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: days == 7 ? 3 : 1)
                                .strokeBorder(.primary.opacity(hoveredDate == date ? 0.65 : 0), lineWidth: 1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .frame(height: 62, alignment: .bottom)
                        .modifier(HistoryDayHover(date: date, hoveredDate: $hoveredDate))
                        .accessibilityLabel(dayDescription(date))
                }
            }
            HStack(spacing: spacing) {
                ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                    let label = days == 7 ? date.formatted(.dateTime.weekday(.abbreviated)) :
                        (index % 5 == 0 || index == days - 1 ? date.formatted(.dateTime.day()) : "")
                    Text(label).frame(maxWidth: .infinity)
                }
            }.font(.system(size: 8)).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityHidden(true)
        }.frame(maxWidth: .infinity)
    }

    private func dayDescription(_ date: Date) -> String {
        let totals = report.days[date] ?? TokenTotals()
        return "\(date.formatted(date: .abbreviated, time: .omitted)): \(totals.total.formatted()) tokens\n" +
            "Input \(totals.input.formatted()) · Output \(totals.output.formatted())\n" +
            "Cache read \(totals.cacheRead.formatted()) · Cache write \(totals.cacheWrite.formatted())\n" +
            "Estimated API cost \(cost(totals)) · \(totals.requests.formatted()) requests"
    }

    private func dayDetails(_ date: Date) -> some View {
        let totals = report.days[date] ?? TokenTotals()
        return VStack(alignment: .leading, spacing: 5) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                .font(.system(size: 11, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                detailRow("Total tokens", value: totals.total.formatted(), prominent: true)
                detailRow("Input", value: totals.input.formatted())
                detailRow("Output", value: totals.output.formatted())
                detailRow("Cache read", value: totals.cacheRead.formatted())
                detailRow("Cache write", value: totals.cacheWrite.formatted())
                detailRow(totals.unknownModels.isEmpty ? "Est. API cost" : "Partial API estimate", value: cost(totals))
            }.font(.system(size: 10))
            Text("\(totals.requests.formatted()) requests · all devices")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(10)
    }

    private func detailRow(_ label: String, value: String, prominent: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(prominent ? .primary : .secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }.fontWeight(prominent ? .medium : .regular)
    }

    private var activityGrid: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = (calendar.component(.weekday, from: today) + 6) % 7
        let lastSunday = calendar.date(byAdding: .day, value: -weekday, to: today)!
        let start = calendar.date(byAdding: .weekOfYear, value: -52, to: lastSunday)!
        let maximum = max(1, report.days.filter { $0.key >= start && $0.key <= today }.values.map(\.total).max() ?? 1)
        return HStack(alignment: .top, spacing: 1) {
            ForEach(0..<53, id: \.self) { week in
                VStack(spacing: 1) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                        let tokens = report.days[date]?.total ?? 0
                        let level = tokens > 0 ? 0.25 + 0.75 * log1p(Double(tokens)) / log1p(Double(maximum)) : 0
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tokens > 0 ? Color.accentColor.opacity(level) : Color.primary.opacity(0.08))
                            .overlay {
                                RoundedRectangle(cornerRadius: 1)
                                    .strokeBorder(.primary.opacity(hoveredDate == date ? 0.8 : 0), lineWidth: 1)
                            }
                            .frame(width: 5, height: 5)
                            .opacity(date > today ? 0 : 1)
                            .modifier(HistoryDayHover(date: date, hoveredDate: $hoveredDate))
                            .allowsHitTesting(date <= today)
                            .accessibilityLabel(dayDescription(date))
                            .accessibilityHidden(date > today)
                    }
                }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityLabel("Daily Claude Code token activity over the past year.")
    }

    private func cost(_ totals: TokenTotals) -> String {
        if totals.requests > 0 && totals.pricedRequests == 0 { return "—" }
        let low = Self.money(totals.costLow), high = Self.money(totals.costHigh)
        return low == high ? "≈" + low : "≈\(low)–\(high)"
    }

    private func costExplanation(_ totals: TokenTotals) -> String {
        var text = "Value at standard API list prices checked \(ModelPricing.checked), in USD; this is not your subscription bill. Cache writes with unknown TTL use a 5-minute to 1-hour price range. Historical price changes, tools, taxes, regional premiums and negotiated discounts are not reconstructed."
        if !totals.unknownModels.isEmpty { text += "\nUnpriced models: " + totals.unknownModels.sorted().joined(separator: ", ") }
        return text
    }

    static func tokens(_ value: Int64) -> String {
        let number = Double(value)
        for (size, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where number >= size {
            return String(format: number / size >= 100 ? "%.0f%@" : "%.1f%@", number / size, suffix)
        }
        return String(value)
    }

    private static func money(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.1fK", value / 1000) }
        return String(format: "$%.2f", value)
    }
}

private struct HistoryHoverTarget {
    let date: Date
    let bounds: Anchor<CGRect>
}

private struct HistoryHoverPreference: PreferenceKey {
    static var defaultValue: HistoryHoverTarget? { nil }

    static func reduce(value: inout HistoryHoverTarget?, nextValue: () -> HistoryHoverTarget?) {
        value = nextValue() ?? value
    }
}

private struct HistoryDayHover: ViewModifier {
    let date: Date
    @Binding var hoveredDate: Date?

    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredDate = date }
                else if hoveredDate == date { hoveredDate = nil }
            }
            .anchorPreference(key: HistoryHoverPreference.self, value: .bounds) { bounds in
                hoveredDate == date ? HistoryHoverTarget(date: date, bounds: bounds) : nil
            }
    }
}

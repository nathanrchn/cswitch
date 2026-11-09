import CswitchCore
import SwiftUI

struct HistoryView: View {
    let report: HistoryReport
    let loading: Bool
    @AppStorage("historyExpanded") private var expanded = true
    @State private var period: HistoryPeriod = .week
    @State private var hoveredDate: Date?

    var body: some View {
        let totals = report.totals(period)
        Group {
            if expanded { details(totals) } else { collapsed(totals) }
        }
        .card()
    }

    private func collapsed(_ totals: TokenTotals) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { expanded = true } } label: {
            HStack(spacing: 8) {
                Text("Token usage").font(.system(size: 12, weight: .semibold))
                if loading { Spinner() }
                Spacer()
                if report.loaded {
                    Text("\(Self.tokens(totals.total)) · \(period.rawValue)").font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show token usage")
    }

    /// Hovering a day shows its numbers in place of the period's, so nothing covers the chart.
    private func details(_ totals: TokenTotals) -> some View {
        let shown = hoveredDate.map { report.days[$0] ?? TokenTotals() } ?? totals
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.2)) { expanded = false } } label: {
                    HStack(spacing: 6) {
                        Text("Token usage").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Hide token usage")
                if loading { Spinner() }
                Spacer()
                PeriodPicker(selection: $period)
            }
            if report.loaded {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.tokens(shown.total)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        Text(hoveredDate.map { "tokens on " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
                             ?? "tokens · all devices")
                            .font(.system(size: 11, weight: hoveredDate == nil ? .regular : .medium))
                            .foregroundStyle(hoveredDate == nil ? Palette.secondary : Palette.accentText)
                    }
                    .help(exactDescription(shown))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(cost(shown)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        Text(shown.unknownModels.isEmpty ? "estimated API cost" : "partial API estimate")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    .help(costExplanation(shown))
                }
                if period == .all { activityGrid } else { dailyChart(days: period == .week ? 7 : 30) }
                tokenBreakdown(shown)
            } else {
                Text(loading ? "Reading saved Claude Code activity…" : "History is unavailable. Refresh to try again.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 4) {
                if let hoveredDate {
                    Text("\(plural(shown.requests, "request")) · all devices")
                    Spacer()
                    Text(hoveredDate.formatted(.dateTime.day().month(.abbreviated).year()))
                } else {
                    Text("All accounts · \(plural(report.deviceCount, "device"))")
                    if !report.staleDevices.isEmpty { Text("· cached / incomplete").help("History unavailable or stale on: " + report.staleDevices.joined(separator: ", ")) }
                    if report.unreadable > 0 { Image(systemName: "exclamationmark.triangle").help("Some history records or files could not be read. Totals may be incomplete.") }
                    if report.cacheFailure { Image(systemName: "externaldrive.badge.exclamationmark").help("History was read but its cache could not be saved.") }
                    Spacer()
                    if report.loaded { Text(chartCaption) }
                }
            }
            .font(.system(size: 10)).foregroundStyle(Palette.secondary).monospacedDigit()
        }
        .padding(12)
        .onChange(of: period) { _, _ in hoveredDate = nil }
        .onDisappear { hoveredDate = nil }
    }

    private func exactDescription(_ totals: TokenTotals) -> String {
        "Total \(totals.total.formatted()) tokens\nInput \(totals.input.formatted()) · Output \(totals.output.formatted())\n" +
            "Cache read \(totals.cacheRead.formatted()) · Cache write \(totals.cacheWrite.formatted())\n\(plural(totals.requests, "unique request"))"
    }

    private var chartCaption: String {
        guard period != .all else { return "Past year" }
        let start = period.start().formatted(.dateTime.month(.abbreviated).day())
        let end = Date().formatted(.dateTime.month(.abbreviated).day())
        return "\(start) – \(end)"
    }

    private func tokenBreakdown(_ totals: TokenTotals) -> some View {
        HStack(alignment: .top, spacing: 8) {
            tokenMetric("Input", value: totals.input)
            tokenMetric("Output", value: totals.output)
            tokenMetric("Cache read", value: totals.cacheRead)
            tokenMetric("Cache write", value: totals.cacheWrite)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Palette.divider).frame(height: 1) }
        .help("Total tokens = input + output + cache reads + cache writes.")
    }

    private func tokenMetric(_ title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
            Text(Self.tokens(value)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help("\(title): \(value.formatted()) tokens")
    }

    private func dailyChart(days: Int) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dates = (0..<days).map { calendar.date(byAdding: .day, value: $0 - days + 1, to: today)! }
        let maximum = max(1, dates.map { report.days[$0]?.total ?? 0 }.max() ?? 1)
        // Columns touch so the pointer never falls between two days.
        let gap: CGFloat = days == 7 ? 6 : 2
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(dates, id: \.self) { date in
                    let total = report.days[date]?.total ?? 0
                    let height = total == 0 ? 2 : max(3, 48 * CGFloat(total) / CGFloat(maximum))
                    let emphasis = hoveredDate.map { $0 == date } ?? (date == today)
                    RoundedRectangle(cornerRadius: days == 7 ? 3 : 1.5, style: .continuous)
                        .fill(total > 0 ? Palette.accent.opacity(emphasis ? 1 : 0.4) : Palette.track)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .padding(.horizontal, gap / 2)
                        .frame(height: 48, alignment: .bottom)
                        .modifier(HistoryDayHover(date: date, hoveredDate: $hoveredDate))
                        .accessibilityLabel(dayDescription(date))
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                    let label = days == 7 ? (date == today ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))) :
                        (index % 5 == 0 || index == days - 1 ? date.formatted(.dateTime.day()) : "")
                    let selected = hoveredDate.map { $0 == date } ?? (date == today)
                    Text(label).fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.primary : Palette.secondary)
                        .fixedSize().frame(maxWidth: .infinity).padding(.horizontal, gap / 2)
                }
            }.font(.system(size: 10)).monospacedDigit()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, -gap / 2)
        .frame(maxWidth: .infinity)
    }

    private func dayDescription(_ date: Date) -> String {
        let totals = report.days[date] ?? TokenTotals()
        return "\(date.formatted(date: .abbreviated, time: .omitted)): \(totals.total.formatted()) tokens\n" +
            "Input \(totals.input.formatted()) · Output \(totals.output.formatted())\n" +
            "Cache read \(totals.cacheRead.formatted()) · Cache write \(totals.cacheWrite.formatted())\n" +
            "Estimated API cost \(cost(totals)) · \(totals.requests.formatted()) requests"
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
                            .fill(tokens > 0 ? Palette.accent.opacity(level) : Palette.track)
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

private struct HistoryDayHover: ViewModifier {
    let date: Date
    @Binding var hoveredDate: Date?

    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredDate = date }
                else if hoveredDate == date {
                    // Moving to a neighbouring day must not flash the period totals.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { if hoveredDate == date { hoveredDate = nil } }
                }
            }
    }
}

private struct PeriodPicker: View {
    @Binding var selection: HistoryPeriod
    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryPeriod.allCases) { period in
                let selected = period == selection
                Button { selection = period } label: {
                    Text(period.short).font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Palette.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(selected ? Palette.card : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(period.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private extension HistoryPeriod {
    var short: String {
        switch self {
        case .week: return "7D"
        case .month: return "30D"
        case .all: return "All"
        }
    }
}

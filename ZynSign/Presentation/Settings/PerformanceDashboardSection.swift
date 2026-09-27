import SwiftUI

/// Settings → Advanced → Performance: the hidden Performance page.
///
/// The page shows what the Performance Engine reports — library and index
/// counts, cache size by category, the search-index status, the last
/// optimization, memory pressure, background work, the launch timeline,
/// and the benchmark table with the regression verdict — and offers the
/// actions the engine exposes: optimize now, run the benchmarks, accept
/// or clear the baseline, trim memory, and clear caches by category.
/// Every figure is read from a snapshot after the action, never assumed;
/// every destructive-looking action confirms first and says what it will
/// not touch.
struct PerformanceDashboardSection: View {

    @Environment(\.settingsCenter) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: PerformanceDashboardModel

    init(model: PerformanceDashboardModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            if !model.isAvailable {
                unavailableBanner
            } else {
                overviewSection
                actionsSection
                cachesSection
                benchmarksSection
                launchSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.refresh() }
        .alert(item: $model.pendingAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text("Clear")) {
                    Task { await model.perform(action) }
                },
                secondaryButton: .cancel()
            )
        }
        .overlay(alignment: .bottom) {
            if let message = model.message {
                messageBanner(message)
            }
        }
        .animation(ZMotion.fast, value: model.message)
    }

    // MARK: - Sections

    private var unavailableBanner: some View {
        ZSettingsBanner(
            title: "The Performance Engine is not composed in this build",
            message: "Nothing here is measured, so nothing here is shown. The application still works; it simply reads without caches.",
            kind: .warning
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var overviewSection: some View {
        Section {
            ForEach(model.metrics) { metric in
                metricRow(metric)
            }
        } header: {
            Text("Overview")
        } footer: {
            Text("Counts and sizes are read from the engine when this page appears and after every action. Pull down to refresh.")
        }
    }

    private var actionsSection: some View {
        Section {
            ZSettingsButtonRow(
                title: model.isOptimizing ? "Optimizing…" : "Optimize Now",
                subtitle: "Applies every cache policy, trims memory, and flushes the metadata index.",
                symbol: "bolt.badge.clock"
            ) {
                Task { await model.optimize() }
            }
            .disabled(model.isBusy)
            ZSettingsButtonRow(
                title: "Trim Memory",
                subtitle: "Releases decoded thumbnails and in-memory caches, as a memory warning would.",
                symbol: "memorychip"
            ) {
                Task { await model.trimMemory() }
            }
            .disabled(model.isBusy)
        } header: {
            Text("Actions")
        } footer: {
            Text("Optimization never removes an imported application, a signed artifact, or history. It only removes derived data that is rebuilt as needed.")
        }
    }

    private var cachesSection: some View {
        Section {
            ForEach(model.snapshot.cacheStatistics) { statistics in
                HStack(alignment: .firstTextBaseline) {
                    ZSettingsLabel(
                        title: statistics.category.displayName,
                        subtitle: "\(statistics.itemCount) items",
                        symbol: statistics.category.symbolName
                    )
                    Spacer(minLength: ZSpacing.sm)
                    Text(PerformanceDashboardModel.formatted(bytes: statistics.byteCount))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        model.pendingAction = .clearCache(statistics.category)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy || statistics.itemCount == 0)
                    .accessibilityLabel("Clear \(statistics.category.displayName)")
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(PerformanceDashboardModel.formatted(bytes: statistics.byteCount))
            }
            ZSettingsButtonRow(
                title: "Clear All Caches",
                subtitle: "Empties every category above.",
                symbol: "trash",
                isDestructive: true
            ) {
                model.pendingAction = .clearAllCaches
            }
            .disabled(model.isBusy)
        } header: {
            Text("Caches")
        } footer: {
            Text("Each category has its own size and age limit, enforced automatically. Clearing one only removes derived data; imported applications are never a cache.")
        }
    }

    private var benchmarksSection: some View {
        Section {
            if model.benchmarkMetrics.isEmpty {
                ZSettingsValueRow(
                    title: "No Measurements",
                    symbol: "stopwatch",
                    subtitle: "Run the benchmarks to record the first set."
                ) {
                    EmptyView()
                }
            } else {
                ForEach(model.benchmarkMetrics) { metric in
                    metricRow(metric)
                }
            }
            if let progress = model.benchmarkProgress {
                HStack {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Running benchmarks, \(progress.completed) of \(progress.total)")
            }
            ZSettingsButtonRow(
                title: model.isBenchmarking ? "Running…" : "Run Benchmarks",
                subtitle: "Library load, search, import, signing preparation, and store loading.",
                symbol: "stopwatch"
            ) {
                Task { await model.runBenchmarks() }
            }
            .disabled(model.isBusy)
            ZSettingsButtonRow(
                title: "Accept as Baseline",
                subtitle: "Later runs are compared against these measurements.",
                symbol: "flag.checkered"
            ) {
                Task { await model.acceptBaseline() }
            }
            .disabled(model.isBusy || model.benchmarkMetrics.isEmpty)
            if model.snapshot.regressionReport != nil {
                ZSettingsButtonRow(
                    title: "Clear Baseline",
                    symbol: "flag.slash",
                    isDestructive: true
                ) {
                    Task { await model.clearBaseline() }
                }
                .disabled(model.isBusy)
            }
            if !model.benchmarkMetrics.isEmpty {
                ZSettingsButtonRow(
                    title: "Clear History",
                    symbol: "clock.arrow.circlepath",
                    isDestructive: true
                ) {
                    model.pendingAction = .clearBenchmarkHistory
                }
                .disabled(model.isBusy)
            }
        } header: {
            Text("Benchmarks")
        } footer: {
            Text("A regression is a measurement more than a quarter slower per item than the baseline, ignoring differences under two milliseconds. Measurements depend on the device and the library; compare like with like.")
        }
    }

    @ViewBuilder
    private var launchSection: some View {
        if !model.launchMetrics.isEmpty {
            Section {
                ForEach(model.launchMetrics) { metric in
                    metricRow(metric)
                }
            } header: {
                Text("This Launch")
            } footer: {
                Text("Offsets from process start. Home is shown before any deferred work begins.")
            }
        }
    }

    // MARK: - Rows

    private func metricRow(_ metric: PerformanceMetric) -> some View {
        ZSettingsValueRow(title: metric.title, subtitle: metric.detail) {
            Text(metric.value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func messageBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.sm)
            .background(.regularMaterial, in: Capsule())
            .padding(ZSpacing.md)
            .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            .onTapGesture { model.clearMessage() }
            .task(id: message) {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { model.clearMessage() }
            }
            .accessibilityAddTraits(.updatesFrequently)
    }
}

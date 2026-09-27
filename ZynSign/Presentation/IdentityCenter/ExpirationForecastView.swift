import SwiftUI

/// The full expiration forecast: every certificate and profile inside the
/// forecast horizon, sorted most-urgent first.
///
/// The forecast is the center's answer to "what stops working next". Each
/// band — Expired, Critical (≤7 days), Important (≤14 days), Warning
/// (≤30 days), Watch — is its own section, so the order is visible, not
/// merely sorted. Empty bands are omitted.
struct ExpirationForecastView: View {

    let snapshot: IdentityCenterSnapshot

    var body: some View {
        List {
            if snapshot.forecast.isEmpty {
                ContentUnavailableView(
                    "Nothing Expiring",
                    systemImage: "calendar.badge.checkmark",
                    description: Text("No certificate or profile is inside the 30-day forecast window, and none has expired.")
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } else {
                ForEach(ExpirationForecastBand.allCases, id: \.self) { band in
                    let entries = snapshot.forecast.filter { $0.band == band }
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries) { entry in
                                ExpirationForecastRow(entry: entry)
                            }
                        } header: {
                            Text("\(band.displayName) — \(entries.count)")
                        } footer: {
                            if band == ExpirationForecastBand.allCases.first {
                                Text("Sorted by urgency: the next identity to stop working is at the top.")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Expiration Forecast")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
    }
}

/// The full identity timeline: recent identity events grouped by day.
///
/// The timeline reads the same snapshot the dashboard reads — import
/// dates, the signing journal, and the expiration observations — and
/// groups them under "Today", "Yesterday", and the calendar dates, most
/// recent first.
struct IdentityTimelineView: View {

    let snapshot: IdentityCenterSnapshot

    var body: some View {
        Group {
            if days.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Import a certificate or profile, or sign an application, and the timeline records it here — on this device only.")
                )
            } else {
                List {
                    ForEach(days) { day in
                        Section(day.title) {
                            ForEach(day.events) { event in
                                IdentityTimelineRow(event: event)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Identity Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
    }

    /// The grouped days, computed once per render from the snapshot.
    private var days: [IdentityTimelineDay] {
        IdentityTimelineBuilder().groupedByDay(
            snapshot.timeline,
            referenceDate: snapshot.generatedAt
        )
    }
}

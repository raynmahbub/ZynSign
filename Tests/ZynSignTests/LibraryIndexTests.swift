import XCTest
@testable import ZynSign

/// Tests for the library index: search across every searchable field,
/// stacked filters, smart collections, collection scopes, the seven orders,
/// statistics, incremental updates, and behaviour at library scale.
final class LibraryIndexTests: XCTestCase {

    private typealias Fixtures = LibraryOrganizationFixtures
    private let now = LibraryOrganizationFixtures.now

    // MARK: - Search

    func testSearchCoversNameBundleIdentifierVersionAndFileName() {
        let byName = Fixtures.entry(name: "Delta Mail", bundleIdentifier: "com.example.one")
        let byBundle = Fixtures.entry(name: "Other", bundleIdentifier: "com.example.deltamail")
        let byVersion = Fixtures.entry(name: "Versioned", bundleIdentifier: "com.example.two", version: "7.4.2")
        let byFile = Fixtures.entry(name: "Filed", bundleIdentifier: "com.example.three", sourceFileName: "delta-build.ipa")
        let index = LibraryIndex(entries: [byName, byBundle, byVersion, byFile])

        XCTAssertEqual(Set(results(index, "delta")), [byName.record.id, byBundle.record.id, byFile.record.id])
        XCTAssertEqual(results(index, "7.4"), [byVersion.record.id])
    }

    func testSearchCoversDeclaredDeveloperAndTeam() {
        let entry = Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain")
        let other = Fixtures.entry(name: "Other", bundleIdentifier: "com.example.other")
        let provenance = [
            entry.record.artifact.artifactID: ApplicationProvenance(
                developerName: "Acme Studios",
                teamIdentifier: "ABCDE12345",
                teamName: "Acme Team"
            ),
        ]
        let index = LibraryIndex(entries: [entry, other], provenance: provenance)

        XCTAssertEqual(results(index, "acme"), [entry.record.id])
        XCTAssertEqual(results(index, "abcde1"), [entry.record.id])
        XCTAssertEqual(index.matchedFields(for: entry.record.id, foldedTerms: ["abcde1"]), [.teamIdentifier])
    }

    func testSearchCoversCollectionNames() throws {
        let member = Fixtures.entry(name: "Member", bundleIdentifier: "com.example.member")
        let outsider = Fixtures.entry(name: "Outsider", bundleIdentifier: "com.example.outsider")
        var organization = LibraryOrganization.empty
        try organization.createCollection(named: "Weekend Games", containing: [member.record.id], at: now)
        let index = LibraryIndex(entries: [member, outsider], organization: organization)

        XCTAssertEqual(results(index, "weekend"), [member.record.id])
    }

    func testEveryTermMustMatchSomewhere() {
        let both = Fixtures.entry(name: "Delta Mail", bundleIdentifier: "com.example.mail", version: "2.0")
        let nameOnly = Fixtures.entry(name: "Delta Notes", bundleIdentifier: "com.example.notes", version: "1.0")
        let index = LibraryIndex(entries: [both, nameOnly])

        XCTAssertEqual(results(index, "delta 2.0"), [both.record.id])
        XCTAssertEqual(Set(results(index, "  delta  ")), [both.record.id, nameOnly.record.id])
    }

    func testSearchIgnoresCaseDiacriticsAndWidth() {
        let entry = Fixtures.entry(name: "Café Présentation", bundleIdentifier: "com.example.cafe")
        let index = LibraryIndex(entries: [entry])

        XCTAssertEqual(results(index, "CAFE presentation"), [entry.record.id])
        XCTAssertEqual(results(index, "ｃａｆｅ"), [entry.record.id])
    }

    // MARK: - Highlighting

    func testHighlightRunsMarkEveryOccurrenceInTheDisplayedText() {
        let runs = LibraryHighlighter.runs(in: "Café au lait café", terms: ["cafe"])

        XCTAssertEqual(runs.filter(\.isMatch).map(\.text), ["Café", "café"])
        XCTAssertEqual(runs.map(\.text).joined(), "Café au lait café", "Runs must reassemble the original text exactly.")
    }

    func testOverlappingHighlightsMerge() {
        let runs = LibraryHighlighter.runs(in: "deltamail", terms: ["delta", "tama"])

        // "delta" covers d-e-l-t-a and "tama" covers t-a-m-a: one run.
        XCTAssertEqual(runs, [
            LibraryHighlighter.Run(text: "deltama", isMatch: true),
            LibraryHighlighter.Run(text: "il", isMatch: false),
        ])
    }

    func testNoTermsMeansOnePlainRun() {
        XCTAssertEqual(LibraryHighlighter.runs(in: "Plain", terms: []), [LibraryHighlighter.Run(text: "Plain", isMatch: false)])
        XCTAssertEqual(LibraryHighlighter.runs(in: "Plain", terms: ["zzz"]), [LibraryHighlighter.Run(text: "Plain", isMatch: false)])
    }

    // MARK: - Filters

    func testFiltersOnDifferentFacetsMustAllHold() {
        let recent = now.addingTimeInterval(-3_600)
        let old = now.addingTimeInterval(-30 * 86_400)
        let match = Fixtures.entry(name: "Match", bundleIdentifier: "com.example.match", importedAt: recent, isFavorite: true)
        let notFavorite = Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain", importedAt: recent)
        let signedFavorite = Fixtures.entry(name: "Signed", bundleIdentifier: "com.example.signed", importedAt: recent, isFavorite: true)
        let oldFavorite = Fixtures.entry(name: "Old", bundleIdentifier: "com.example.old", importedAt: old, isFavorite: true)
        let facts = LibrarySigningFacts(journal: [Fixtures.signing(of: signedFavorite.record, at: recent)])
        let index = LibraryIndex(entries: [match, notFavorite, signedFavorite, oldFavorite], signingFacts: facts)

        let query = LibraryQuery(filters: [.favorites, .unsigned, .recentlyImported])

        XCTAssertEqual(index.results(for: query, now: now), [match.record.id])
    }

    func testFiltersOnOneFacetAreAlternatives() throws {
        let first = Fixtures.entry(name: "First", bundleIdentifier: "com.example.first")
        let second = Fixtures.entry(name: "Second", bundleIdentifier: "com.example.second")
        let neither = Fixtures.entry(name: "Neither", bundleIdentifier: "com.example.neither")
        var organization = LibraryOrganization.empty
        let games = try organization.createCollection(named: "Games", containing: [first.record.id], at: now)
        let work = try organization.createCollection(named: "Work", containing: [second.record.id], at: now)
        let index = LibraryIndex(entries: [first, second, neither], organization: organization)

        let either = index.results(for: LibraryQuery(filters: [.collection(games.id), .collection(work.id)]), now: now)
        XCTAssertEqual(Set(either), [first.record.id, second.record.id])

        let signedOrUnsigned = index.results(for: LibraryQuery(filters: [.signed, .unsigned]), now: now)
        XCTAssertEqual(signedOrUnsigned.count, 3, "Choosing both sides of one facet constrains nothing.")
    }

    func testVersionFilterSeparatesTheLatestFromOlderVersions() {
        let old = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app", version: "2.0")
        let latest = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app", version: "10.0")
        let latestTwin = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app", version: "10.0")
        let alone = Fixtures.entry(name: "Alone", bundleIdentifier: "com.example.alone", version: nil, build: nil)
        let index = LibraryIndex(entries: [old, latest, latestTwin, alone])

        XCTAssertEqual(
            Set(index.results(for: LibraryQuery(filters: [.version(.latest)]), now: now)),
            [latest.record.id, latestTwin.record.id, alone.record.id]
        )
        XCTAssertEqual(index.results(for: LibraryQuery(filters: [.version(.older)]), now: now), [old.record.id])
    }

    func testTeamFilterUsesTheDeclaredTeam() {
        let acme = Fixtures.entry(name: "Acme", bundleIdentifier: "com.example.acme")
        let other = Fixtures.entry(name: "Other", bundleIdentifier: "com.example.other")
        let index = LibraryIndex(
            entries: [acme, other],
            provenance: [acme.record.artifact.artifactID: ApplicationProvenance(developerName: nil, teamIdentifier: "TEAM123456", teamName: "Acme")]
        )

        XCTAssertEqual(index.results(for: LibraryQuery(filters: [.team("TEAM123456")]), now: now), [acme.record.id])
        XCTAssertEqual(index.teams(), [LibraryTeam(identifier: "TEAM123456", name: "Acme", applicationCount: 1)])
    }

    // MARK: - Smart collections

    func testRecentlyImportedCoversTheLastSevenDays() {
        let inside = Fixtures.entry(name: "Inside", bundleIdentifier: "com.example.inside", importedAt: now.addingTimeInterval(-6 * 86_400))
        let outside = Fixtures.entry(name: "Outside", bundleIdentifier: "com.example.outside", importedAt: now.addingTimeInterval(-8 * 86_400))
        let index = LibraryIndex(entries: [inside, outside])

        XCTAssertEqual(index.results(for: LibraryQuery(), in: .smart(.recentlyImported), now: now), [inside.record.id])
    }

    func testRecentlySignedAndUnsignedFollowTheJournal() {
        let recent = Fixtures.entry(name: "Recent", bundleIdentifier: "com.example.recent")
        let longAgo = Fixtures.entry(name: "Long Ago", bundleIdentifier: "com.example.longago")
        let never = Fixtures.entry(name: "Never", bundleIdentifier: "com.example.never")
        let failed = Fixtures.entry(name: "Failed", bundleIdentifier: "com.example.failed")
        let facts = LibrarySigningFacts(journal: [
            Fixtures.signing(of: recent.record, at: now.addingTimeInterval(-3_600)),
            Fixtures.signing(of: longAgo.record, at: now.addingTimeInterval(-20 * 86_400)),
            Fixtures.failedSigning(of: failed.record, at: now.addingTimeInterval(-60)),
        ])
        let index = LibraryIndex(entries: [recent, longAgo, never, failed], signingFacts: facts)

        XCTAssertEqual(index.results(for: LibraryQuery(), in: .smart(.recentlySigned), now: now), [recent.record.id])
        XCTAssertEqual(
            Set(index.results(for: LibraryQuery(), in: .smart(.unsigned), now: now)),
            [never.record.id, failed.record.id],
            "A failed signing leaves an application unsigned."
        )
    }

    func testExpiringSoonIncludesExpiringAndExpiredButNotValidOrUnknown() {
        let soon = Fixtures.entry(name: "Soon", bundleIdentifier: "com.example.soon")
        let expired = Fixtures.entry(name: "Expired", bundleIdentifier: "com.example.expired")
        let valid = Fixtures.entry(name: "Valid", bundleIdentifier: "com.example.valid")
        let unknown = Fixtures.entry(name: "Unknown", bundleIdentifier: "com.example.unknown")
        let signedAt = now.addingTimeInterval(-86_400)
        let facts = LibrarySigningFacts(journal: [
            Fixtures.signing(of: soon.record, at: signedAt, profileExpiresAt: now.addingTimeInterval(90 * 86_400), certificateExpiresAt: now.addingTimeInterval(5 * 86_400)),
            Fixtures.signing(of: expired.record, at: signedAt, profileExpiresAt: now.addingTimeInterval(-60)),
            Fixtures.signing(of: valid.record, at: signedAt, profileExpiresAt: now.addingTimeInterval(200 * 86_400)),
            Fixtures.signing(of: unknown.record, at: signedAt),
        ])
        let index = LibraryIndex(entries: [soon, expired, valid, unknown], signingFacts: facts)

        XCTAssertEqual(
            Set(index.results(for: LibraryQuery(), in: .smart(.expiringSoon), now: now)),
            [soon.record.id, expired.record.id]
        )
        XCTAssertEqual(index.expiryStatus(for: soon.record.id, now: now), .expiringSoon(on: now.addingTimeInterval(5 * 86_400)))
        XCTAssertEqual(index.expiryStatus(for: unknown.record.id, now: now), .unknown)
    }

    func testFavoritesSmartCollectionAndItsCount() {
        let favorite = Fixtures.entry(name: "Favorite", bundleIdentifier: "com.example.favorite", isFavorite: true)
        let plain = Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain")
        let index = LibraryIndex(entries: [favorite, plain])

        XCTAssertEqual(index.results(for: LibraryQuery(), in: .smart(.favorites), now: now), [favorite.record.id])
        XCTAssertEqual(index.entryCount(in: .smart(.favorites), now: now), 1)
        XCTAssertEqual(index.entryCount(in: .all, now: now), 2)
    }

    // MARK: - Collection scope

    func testACollectionScopeListsOnlyMembersTheLibraryStillHolds() throws {
        let member = Fixtures.entry(name: "Member", bundleIdentifier: "com.example.member")
        let outsider = Fixtures.entry(name: "Outsider", bundleIdentifier: "com.example.outsider")
        let departed = ApplicationRecordIdentifier()
        var organization = LibraryOrganization.empty
        let games = try organization.createCollection(named: "Games", containing: [member.record.id, departed], at: now)
        let index = LibraryIndex(entries: [member, outsider], organization: organization)

        XCTAssertEqual(index.results(for: LibraryQuery(), in: .collection(games.id), now: now), [member.record.id])
        XCTAssertEqual(index.memberCount(of: games.id), 1, "A membership naming a removed record is not counted.")
        XCTAssertEqual(index.results(for: LibraryQuery(), in: .collection(LibraryCollectionIdentifier()), now: now), [])
    }

    func testScopeAndFiltersCombine() throws {
        let favoriteMember = Fixtures.entry(name: "Fav", bundleIdentifier: "com.example.fav", isFavorite: true)
        let plainMember = Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain")
        let favoriteOutsider = Fixtures.entry(name: "Out", bundleIdentifier: "com.example.out", isFavorite: true)
        var organization = LibraryOrganization.empty
        let games = try organization.createCollection(named: "Games", containing: [favoriteMember.record.id, plainMember.record.id], at: now)
        let index = LibraryIndex(entries: [favoriteMember, plainMember, favoriteOutsider], organization: organization)

        XCTAssertEqual(
            index.results(for: LibraryQuery(filters: [.favorites]), in: .collection(games.id), now: now),
            [favoriteMember.record.id]
        )
    }

    // MARK: - Ordering

    func testEveryOrder() {
        let t = now.addingTimeInterval(-10 * 86_400)
        let alpha = Fixtures.entry(name: "Alpha", bundleIdentifier: "com.example.alpha", version: "2.0", byteCount: 300, importedAt: t)
        let bravo = Fixtures.entry(name: "bravo", bundleIdentifier: "com.example.bravo", version: "10.0", byteCount: 100, importedAt: t.addingTimeInterval(60))
        let charlie = Fixtures.entry(name: "Charlie", bundleIdentifier: "com.example.charlie", version: "1.5", byteCount: 200, importedAt: t.addingTimeInterval(120))
        let facts = LibrarySigningFacts(journal: [
            Fixtures.signing(of: alpha.record, at: now.addingTimeInterval(-60)),
            Fixtures.signing(of: bravo.record, at: now.addingTimeInterval(-3_600)),
        ])
        let organization = LibraryOrganization(collections: [], lastOpened: [bravo.record.id: now])
        let index = LibraryIndex(entries: [alpha, bravo, charlie], organization: organization, signingFacts: facts)

        func order(_ mode: LibrarySortMode) -> [String?] {
            index.results(for: LibraryQuery(sort: mode), now: now).map { index.entry(for: $0)?.record.displayName }
        }

        XCTAssertEqual(order(.recentlyImported), ["Charlie", "bravo", "Alpha"])
        XCTAssertEqual(order(.name), ["Alpha", "bravo", "Charlie"])
        XCTAssertEqual(order(.nameDescending), ["Charlie", "bravo", "Alpha"])
        XCTAssertEqual(order(.version), ["bravo", "Alpha", "Charlie"])
        XCTAssertEqual(order(.size), ["Alpha", "Charlie", "bravo"])
        XCTAssertEqual(order(.recentlySigned), ["Alpha", "bravo", "Charlie"], "Unsigned entries follow signed ones.")
        XCTAssertEqual(order(.lastOpened), ["bravo", "Charlie", "Alpha"], "Never-opened entries follow, newest import first.")
    }

    func testUndeclaredVersionsSortLast() {
        let declared = Fixtures.entry(name: "Declared", bundleIdentifier: "com.example.declared", version: "0.1")
        let buildOnly = Fixtures.entry(name: "Build Only", bundleIdentifier: "com.example.build", version: nil, build: "900")
        let index = LibraryIndex(entries: [buildOnly, declared])

        let ordered = index.results(for: LibraryQuery(sort: .version), now: now)

        XCTAssertEqual(ordered, [declared.record.id, buildOnly.record.id])
    }

    // MARK: - Statistics

    func testStatisticsCountEveryDimensionAndStoredBytes() throws {
        let available = Fixtures.entry(name: "A", bundleIdentifier: "com.example.a", byteCount: 1_000, isFavorite: true)
        let missing = Fixtures.entry(name: "B", bundleIdentifier: "com.example.b", byteCount: 5_000, availability: .missing)
        let inconsistent = Fixtures.entry(
            name: "C",
            bundleIdentifier: "com.example.c",
            byteCount: 4_000,
            availability: .inconsistent(recordedByteCount: 4_000, observedByteCount: 700)
        )
        var organization = LibraryOrganization.empty
        try organization.createCollection(named: "One", at: now)
        try organization.createCollection(named: "Two", at: now)
        let facts = LibrarySigningFacts(journal: [Fixtures.signing(of: available.record, at: now)])
        let index = LibraryIndex(entries: [available, missing, inconsistent], organization: organization, signingFacts: facts)

        let statistics = index.statistics()

        XCTAssertEqual(statistics.totalApplications, 3)
        XCTAssertEqual(statistics.favorites, 1)
        XCTAssertEqual(statistics.signed, 1)
        XCTAssertEqual(statistics.unsigned, 2)
        XCTAssertEqual(statistics.collections, 2)
        XCTAssertEqual(statistics.storageBytes, 1_700, "Missing files occupy nothing; inconsistent ones their observed size.")
    }

    // MARK: - Incremental updates

    func testIncrementalUpdatesMatchAFullRebuild() throws {
        let first = Fixtures.entry(name: "First", bundleIdentifier: "com.example.first", version: "1.0")
        let second = Fixtures.entry(name: "Second", bundleIdentifier: "com.example.first", version: "2.0")
        let third = Fixtures.entry(name: "Third", bundleIdentifier: "com.example.third")
        var organization = LibraryOrganization.empty
        let games = try organization.createCollection(named: "Games", containing: [first.record.id, third.record.id], at: now)
        let provenance = [third.record.artifact.artifactID: ApplicationProvenance(developerName: "Acme", teamIdentifier: nil, teamName: nil)]

        var incremental = LibraryIndex(entries: [first, second])
        incremental.setOrganization(organization)
        incremental.update(third)
        incremental.mergeProvenance(provenance)
        let favorited = LibraryEntry(record: first.record.with(isFavorite: true, updatedAt: now), artifactAvailability: .available)
        incremental.update(favorited)
        incremental.remove([second.record.id])

        let rebuilt = LibraryIndex(entries: [favorited, third], organization: organization, provenance: provenance)

        let queries = [
            LibraryQuery(),
            LibraryQuery(searchText: "acme"),
            LibraryQuery(searchText: "games"),
            LibraryQuery(filters: [.favorites]),
            LibraryQuery(filters: [.version(.latest)]),
            LibraryQuery(filters: [.collection(games.id)], sort: .name),
        ]
        for query in queries {
            XCTAssertEqual(incremental.results(for: query, now: now), rebuilt.results(for: query, now: now), "\(query)")
        }
        XCTAssertEqual(incremental.statistics(), rebuilt.statistics())
        XCTAssertEqual(incremental.memberCount(of: games.id), 2)
    }

    func testRenamingACollectionUpdatesCollectionSearch() throws {
        let member = Fixtures.entry(name: "Member", bundleIdentifier: "com.example.member")
        var organization = LibraryOrganization.empty
        let collection = try organization.createCollection(named: "Old Name", containing: [member.record.id], at: now)
        var index = LibraryIndex(entries: [member], organization: organization)

        try organization.renameCollection(collection.id, to: "Fresh", at: now)
        index.setOrganization(organization)

        XCTAssertEqual(results(index, "fresh"), [member.record.id])
        XCTAssertEqual(results(index, "old"), [])
    }

    // MARK: - Scale

    func testAThousandEntryLibraryAnswersQueriesCorrectly() throws {
        let entries = (0..<1_000).map { number in
            Fixtures.entry(
                name: "App \(number)",
                bundleIdentifier: "com.example.app\(number % 400)",
                version: "\(number % 7).\(number % 3)",
                byteCount: 1_000 + number,
                importedAt: now.addingTimeInterval(-Double(number) * 3_600),
                isFavorite: number % 10 == 0
            )
        }
        var organization = LibraryOrganization.empty
        let evens = try organization.createCollection(
            named: "Evens",
            containing: entries.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element.record.id },
            at: now
        )
        let index = LibraryIndex(entries: entries, organization: organization)

        XCTAssertEqual(index.entryCount(in: .all, now: now), 1_000)
        XCTAssertEqual(index.entryCount(in: .smart(.favorites), now: now), 100)
        XCTAssertEqual(index.memberCount(of: evens.id), 500)
        XCTAssertEqual(index.results(for: LibraryQuery(filters: [.favorites, .collection(evens.id)]), now: now).count, 100)
        // Every name containing "99": 99, x99 for x in 1…9, and 990…999
        // (999 counted once) — nineteen entries.
        XCTAssertEqual(index.results(for: LibraryQuery(searchText: "app 99"), now: now).count, 19)
        XCTAssertEqual(index.results(for: LibraryQuery(), in: .smart(.recentlyImported), now: now).count, 169, "Hours 0 through 168.")
    }

    func testQueryPerformanceAtLibraryScale() {
        let entries = (0..<2_000).map { number in
            Fixtures.entry(
                name: "Application \(number)",
                bundleIdentifier: "com.example.bundle\(number)",
                version: "\(number % 9).\(number % 5)",
                importedAt: now.addingTimeInterval(-Double(number) * 600),
                isFavorite: number % 7 == 0
            )
        }
        let index = LibraryIndex(entries: entries)
        let queries = ["a", "ap", "app", "appl", "appli", "applic", "applica", "applicat", "applicati", "applicatio", "application 1"]

        measure(metrics: [XCTClockMetric()]) {
            for text in queries {
                _ = index.results(for: LibraryQuery(searchText: text, filters: [.recentlyImported], sort: .name), now: now)
            }
        }
    }

    // MARK: - Helpers

    private func results(_ index: LibraryIndex, _ text: String) -> [ApplicationRecordIdentifier] {
        index.results(for: LibraryQuery(searchText: text), now: now)
    }
}

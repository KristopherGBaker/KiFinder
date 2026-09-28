import Foundation

/// A single saved photo in the browse UI: the index entry, its resolved on-disk URL
/// (`<libraryRoot>/<entry.path>`), and whether that file is still present. A stale
/// entry whose backing file has been removed out from under us is still enumerable
/// (`fileExists == false`) so the user can prune it rather than have it silently drop.
struct LibraryPhotoItem: Identifiable {
    let entry: KeptEntry
    let url: URL
    let fileExists: Bool

    /// Stable identity = the entry's per-subject content id.
    var id: String {
        entry.id
    }
}

/// One `<YYYY-MM>` month bucket within a person, photos ordered newest-first.
struct LibraryMonthGroup: Identifiable {
    /// `YYYY-MM`, e.g. `2021-07`.
    let month: String
    let items: [LibraryPhotoItem]

    /// Unique within its person group.
    var id: String {
        month
    }
}

/// All of one person's saved photos, split into month buckets (newest month first).
struct LibraryPersonGroup: Identifiable {
    let subjectId: String
    let personName: String
    let months: [LibraryMonthGroup]

    var id: String {
        subjectId
    }

    /// Total saved photos across all of this person's months.
    var photoCount: Int {
        months.reduce(0) { $0 + $1.items.count }
    }
}

/// Pure, side-effect-free grouping of the kept-photo index into person → month groups
/// for the browse UI, with a deterministic order:
///   - people by display name (case-insensitive), then `subjectId` as a tiebreak;
///   - months **descending** (newest first);
///   - photos within a month by `captureDate` descending, then `fileName` ascending.
/// Each leaf item resolves its URL as `<root>/<entry.path>` and records whether that
/// file currently exists (so a stale entry is enumerable rather than dropped).
///
/// - Parameter filter: when non-nil, only that `subjectId`'s entries are grouped;
///   when nil, every person is included.
func groupLibrary(
    entries: [KeptEntry],
    root: URL,
    filter: String? = nil,
    fileManager: FileManager = .default
) -> [LibraryPersonGroup] {
    let scoped = filter.map { id in entries.filter { $0.subjectId == id } } ?? entries

    let bySubject = Dictionary(grouping: scoped, by: \.subjectId)
    var personGroups: [LibraryPersonGroup] = []
    personGroups.reserveCapacity(bySubject.count)

    for (subjectId, subjectEntries) in bySubject {
        // The display name is recorded per entry; use the most recently saved one so a
        // rename shows the current label (entries from the same subject share a name in
        // practice, but newest-wins is the least surprising tiebreak).
        let personName = subjectEntries
            .max { $0.savedAt < $1.savedAt }?
            .personName ?? subjectId

        let byMonth = Dictionary(grouping: subjectEntries) { KeptLibrary.monthFolder(for: $0.captureDate) }
        var monthGroups: [LibraryMonthGroup] = []
        monthGroups.reserveCapacity(byMonth.count)
        for (month, monthEntries) in byMonth {
            let items = monthEntries
                .sorted { lhs, rhs in
                    if lhs.captureDate != rhs.captureDate { return lhs.captureDate > rhs.captureDate }
                    return lhs.fileName < rhs.fileName
                }
                .map { entry -> LibraryPhotoItem in
                    let url = root.appendingPathComponent(entry.path)
                    return LibraryPhotoItem(
                        entry: entry,
                        url: url,
                        fileExists: fileManager.fileExists(atPath: url.path)
                    )
                }
            monthGroups.append(LibraryMonthGroup(month: month, items: items))
        }
        monthGroups.sort { $0.month > $1.month } // newest month first
        personGroups.append(
            LibraryPersonGroup(subjectId: subjectId, personName: personName, months: monthGroups)
        )
    }

    personGroups.sort { lhs, rhs in
        switch lhs.personName.localizedCaseInsensitiveCompare(rhs.personName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.subjectId < rhs.subjectId
        }
    }
    return personGroups
}

/// Returns `groups` with `entry` removed (and any now-empty month / person group
/// pruned). Used to update the exposed browse data optimistically the instant the user
/// confirms a remove, before the off-actor disk + index delete completes.
func prunedLibraryGroups(_ groups: [LibraryPersonGroup], removing entry: KeptEntry) -> [LibraryPersonGroup] {
    groups.compactMap { person -> LibraryPersonGroup? in
        let months = person.months.compactMap { month -> LibraryMonthGroup? in
            let items = month.items.filter { $0.entry.id != entry.id }
            return items.isEmpty ? nil : LibraryMonthGroup(month: month.month, items: items)
        }
        return months.isEmpty
            ? nil
            : LibraryPersonGroup(subjectId: person.subjectId, personName: person.personName, months: months)
    }
}

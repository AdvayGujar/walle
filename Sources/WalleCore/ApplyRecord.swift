import Foundation

/// Records a successful wallpaper change.
///
/// This runs after the desktop has actually changed, so a failure here must never fail the
/// command. It was previously written with try? which silently discarded the error and
/// left no trace that history had not been recorded; now the caller gets the problems back
/// and can report them.
public func walleRecordApplied(path: String, paths: WallePaths, mode: String) -> [String] {
    var warnings: [String] = []

    do {
        try HistoryStore(fileURL: paths.historyFile)
            .append(HistoryEntry(path: path, appliedAt: Date(), screenUUID: nil, mode: mode))
    } catch {
        warnings.append("could not record history: " + String(describing: error))
    }

    let stateStore = StateStore(fileURL: paths.stateFile)
    var state = stateStore.load()
    state.lastAppliedPath = path
    do {
        try stateStore.save(state)
    } catch {
        warnings.append("could not record state: " + String(describing: error))
    }

    return warnings
}

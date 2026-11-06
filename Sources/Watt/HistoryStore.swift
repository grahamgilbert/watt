import Foundation
import CTelemetry

struct HistoryPolicy {
    var retention: TimeInterval = 48 * 3600
    // Payload leaves room for page/index overhead, metadata and bounded WAL growth.
    var payloadBytes: Int64 = 4 * 1024 * 1024 * 1024
    var databaseBytes: Int64 = 8 * 1024 * 1024 * 1024
    var minimumFreeBytes: Int64 = 256 * 1024 * 1024
    var maximumFrameBytes: Int = 4 * 1024 * 1024
}

struct RecordingGap: Codable, Identifiable {
    var id: String
    var start: Date
    var end: Date?
    var reason: String
    func contains(_ date: Date) -> Bool { date.timeIntervalSince(start) > 0.000001 && (end ?? .distantFuture).timeIntervalSince(date) > 0.000001 }
}

enum HistoryError: LocalizedError {
    case sqlite(Int32, String), insufficientSpace, frameTooLarge, budgetExceeded
    var errorDescription: String? {
        switch self {
        case let .sqlite(code, message): return "SQLite \(code): \(message)"
        case .insufficientSpace: return "Disk reserve reached. Recording will retry when space is available."
        case .frameTooLarge: return "A sample exceeds the recording size limit."
        case .budgetExceeded: return "Recording storage budget reached."
        }
    }
}

final class HistoryStore {
    private var db: OpaquePointer?
    let path: String
    let policy: HistoryPolicy
    private let freeBytes: () -> Int64
    private var payload: Int64 = 0
    private var writes = 0
    init(path: String, policy: HistoryPolicy = HistoryPolicy(), freeBytes: (() -> Int64)? = nil) throws {
        self.path = path; self.policy = policy
        self.freeBytes = freeBytes ?? {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else { let error = failure(); sqlite3_close(db); db = nil; throw error }
        do {
            sqlite3_busy_timeout(db, 1000)
            let version = try scalar("PRAGMA user_version")
            guard version <= 3 else { throw HistoryError.sqlite(SQLITE_SCHEMA, "History was created by a newer Watt version.") }
            // Only affects new databases. Existing v1 files remain compatible without a rebuild.
            try execute("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=128; PRAGMA journal_size_limit=1048576;")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS frames(time REAL PRIMARY KEY, data BLOB NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS gaps(id TEXT PRIMARY KEY,start REAL NOT NULL,end REAL,reason TEXT NOT NULL); CREATE INDEX IF NOT EXISTS gaps_start ON gaps(start)")
                if try scalar("SELECT count(*) FROM pragma_table_info('frames') WHERE name='bytes'") == 0 {
                    try execute("ALTER TABLE frames ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0; UPDATE frames SET bytes=length(data)")
                }
                try execute("PRAGMA user_version=3")
            }
            let pages = max(16, policy.databaseBytes / max(1, try scalar("PRAGMA page_size")))
            try execute("PRAGMA max_page_count=\(pages)")
            payload = try scalar("SELECT coalesce(sum(bytes),0) FROM frames")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> HistoryError { .sqlite(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        return result
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(s, 0)
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func bind(_ text: String, to s: OpaquePointer, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(s, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func finish(_ s: OpaquePointer) throws {
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    func append(_ frame: Frame, now: Date = Date()) throws {
        let data = try JSONEncoder().encode(frame)
        guard data.count <= policy.maximumFrameBytes, Int64(data.count) <= policy.payloadBytes else { throw HistoryError.frameTooLarge }
        guard freeBytes() >= policy.minimumFreeBytes + Int64(data.count) * 3 else { throw HistoryError.insufficientSpace }
        // Refresh accounting after pruning; rolled-back inserts never alter it.
        var retained = payload
        try transaction {
            let cutoff = now.addingTimeInterval(-policy.retention).timeIntervalSince1970
            retained -= try scalar("SELECT coalesce(sum(bytes),0) FROM frames WHERE time < \(cutoff)")
            try execute("DELETE FROM frames WHERE time < \(cutoff); DELETE FROM gaps WHERE end IS NOT NULL AND end < \(cutoff)")
            while retained + Int64(data.count) > policy.payloadBytes {
                retained -= try scalar("SELECT coalesce(sum(bytes),0) FROM (SELECT bytes FROM frames ORDER BY time LIMIT 64)")
                try execute("DELETE FROM frames WHERE time IN (SELECT time FROM frames ORDER BY time LIMIT 64)")
            }
            let s = try statement("INSERT INTO frames(time,data,bytes) VALUES(?,?,?)"); defer { sqlite3_finalize(s) }
            sqlite3_bind_double(s, 1, frame.time.timeIntervalSince1970)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_bind_int(s, 3, Int32(data.count))
            try finish(s)
        }
        payload = retained + Int64(data.count)
        writes += 1
        if writes % 12 == 0 { try checkpoint() }
        // Account for all three files, not just live payload. Page reuse normally prevents this trip.
        if diskBytes > policy.databaseBytes { try checkpoint(); if diskBytes > policy.databaseBytes { throw HistoryError.budgetExceeded } }
    }
    var diskBytes: Int64 {
        [path, path + "-wal", path + "-shm"].reduce(0) { total, file in
            total + (((try? FileManager.default.attributesOfItem(atPath: file)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
    }
    var payloadBytes: Int64 { payload }
    func checkpoint() throws {
        let result = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard result == SQLITE_OK else { throw failure() }
        // Reclaim a bounded number of free pages on new incremental-vacuum files.
        try execute("PRAGMA incremental_vacuum(128)")
    }
    func recent(limit: Int = 720) throws -> [Frame] {
        let s = try statement("SELECT data FROM frames ORDER BY time DESC LIMIT ?"); defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(clamping: max(0, limit)))
        var frames: [Frame] = []
        var result = sqlite3_step(s)
        while result == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(s, 0) {
                frames.append(try JSONDecoder().decode(Frame.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))))
            }
            result = sqlite3_step(s)
        }
        guard result == SQLITE_DONE else { throw failure() }
        return frames.reversed()
    }
    func bounds() throws -> DateInterval? {
        let s=try statement("SELECT min(time),max(time) FROM frames");defer {sqlite3_finalize(s)}
        guard sqlite3_step(s)==SQLITE_ROW,sqlite3_column_type(s,0) != SQLITE_NULL else {return nil}
        return DateInterval(start:Date(timeIntervalSince1970:sqlite3_column_double(s,0)),end:Date(timeIntervalSince1970:sqlite3_column_double(s,1)))
    }
    func frames(in range:DateInterval,maximumFrames:Int=1500,maximumBytes:Int64=96*1024*1024) throws -> [Frame] {
        let count=try statement("SELECT count(*),coalesce(sum(bytes),0) FROM frames WHERE time>=? AND time<=?")
        defer {sqlite3_finalize(count)}
        sqlite3_bind_double(count,1,range.start.timeIntervalSince1970);sqlite3_bind_double(count,2,range.end.timeIntervalSince1970)
        guard sqlite3_step(count)==SQLITE_ROW else {throw failure()}
        guard sqlite3_column_int64(count,0)<=maximumFrames,sqlite3_column_int64(count,1)<=maximumBytes else {throw HistoryQueryError.tooBroad}
        let s=try statement("SELECT data FROM frames WHERE time>=? AND time<=? ORDER BY time")
        defer {sqlite3_finalize(s)}
        sqlite3_bind_double(s,1,range.start.timeIntervalSince1970);sqlite3_bind_double(s,2,range.end.timeIntervalSince1970)
        var frames:[Frame]=[];var status=sqlite3_step(s)
        while status==SQLITE_ROW {
            if let bytes=sqlite3_column_blob(s,0) {frames.append(try JSONDecoder().decode(Frame.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(s,0)))))}
            status=sqlite3_step(s)
        }
        guard status==SQLITE_DONE else {throw failure()};return frames
    }
    @discardableResult func beginGap(at start: Date, reason: String) throws -> String {
        let id = UUID().uuidString
        let s = try statement("INSERT INTO gaps VALUES(?,?,NULL,?)"); defer { sqlite3_finalize(s) }
        bind(id, to: s, at: 1); sqlite3_bind_double(s, 2, start.timeIntervalSince1970); bind(reason, to: s, at: 3)
        try finish(s); return id
    }
    func closeGap(_ id: String, at end: Date) throws {
        let s = try statement("UPDATE gaps SET end=max(start,?) WHERE id=?"); defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, end.timeIntervalSince1970); bind(id, to: s, at: 2); try finish(s)
    }
    func gaps(limit: Int = 1000) throws -> [RecordingGap] {
        let s = try statement("SELECT id,start,end,reason FROM gaps ORDER BY start DESC LIMIT ?"); defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(clamping: limit)); var result: [RecordingGap] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            result.append(RecordingGap(id: String(cString: sqlite3_column_text(s,0)), start: Date(timeIntervalSince1970: sqlite3_column_double(s,1)), end: sqlite3_column_type(s,2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s,2)), reason: String(cString: sqlite3_column_text(s,3))))
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw failure() }; return result.reversed()
    }
}

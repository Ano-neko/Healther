import Foundation

/// The user's personal database: memory, conversation, meals, journal.
/// Everything here stays on device.
///
/// Upgrades must keep existing data: append a new `if v < N` step with additive SQL,
/// never edit an earlier step.
public enum UserDatabase {
    public static let currentVersion = 2

    public static func open(at url: URL) throws -> SQLiteDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: url.path)
        try migrate(db)
        return db
    }

    public static func inMemory() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase.inMemory()
        try migrate(db)
        return db
    }

    static func migrate(_ db: SQLiteDatabase) throws {
        let v = db.userVersion
        if v < 1 {
            try db.transaction {
                try db.executeScript(schemaV1)
                try db.setUserVersion(1)
            }
        }
        if v < 2 {
            try db.transaction {
                try db.executeScript(schemaV2)
                try db.setUserVersion(2)
            }
        }
    }

    /// v2: hand-logged weights (no smart scale needed).
    static let schemaV2 = """
    CREATE TABLE weight_entries(
        id INTEGER PRIMARY KEY,
        at REAL NOT NULL,
        kg REAL NOT NULL
    );
    CREATE INDEX weight_entries_at ON weight_entries(at);
    """

    // Times are REAL unix seconds. JSON blobs are TEXT.
    static let schemaV1 = """
    -- L1: user profile, rendered into every prompt
    CREATE TABLE profile(
        section TEXT NOT NULL,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(section, key)
    );

    -- L3: long-term memories
    CREATE TABLE memories(
        id INTEGER PRIMARY KEY,
        kind TEXT NOT NULL,
        content TEXT NOT NULL,
        tags TEXT,
        importance INTEGER NOT NULL DEFAULT 3,
        source TEXT NOT NULL DEFAULT 'agent',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        last_recalled_at REAL,
        recall_count INTEGER NOT NULL DEFAULT 0,
        superseded_by INTEGER  -- newer memory id; -1 = forgotten
    );
    CREATE VIRTUAL TABLE memories_fts USING fts5(tokens, tokenize='unicode61 remove_diacritics 2');

    -- Daily diary written by reflection
    CREATE TABLE episodes(
        day TEXT PRIMARY KEY,
        summary TEXT NOT NULL,
        mood TEXT,
        highlights TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    -- L4: full conversation log (UI history); `compacted` rows are only in the rolling summary
    CREATE TABLE messages(
        id INTEGER PRIMARY KEY,
        turn_id TEXT NOT NULL,
        created_at REAL NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        payload TEXT,
        compacted INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX messages_created ON messages(created_at);

    CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL);

    -- Food
    CREATE TABLE meals(
        id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        meal_type TEXT NOT NULL,
        eaten_at REAL NOT NULL,
        note TEXT,
        items TEXT NOT NULL,
        kcal REAL NOT NULL,
        protein REAL NOT NULL,
        fat REAL NOT NULL,
        carbs REAL NOT NULL,
        photo TEXT,
        synced INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX meals_eaten ON meals(eaten_at);

    CREATE TABLE personal_foods(
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        norm_name TEXT NOT NULL UNIQUE,
        aliases TEXT,
        note TEXT,
        nutrients TEXT NOT NULL,
        typical_grams REAL,
        use_count INTEGER NOT NULL DEFAULT 0,
        source_ref TEXT,
        created_at REAL NOT NULL,
        last_used_at REAL
    );
    CREATE VIRTUAL TABLE personal_foods_fts USING fts5(name_tokens, alias_tokens, tokenize='unicode61 remove_diacritics 2');

    -- Wellbeing & goals
    CREATE TABLE goals(
        kind TEXT PRIMARY KEY,
        target REAL NOT NULL,
        note TEXT,
        updated_at REAL NOT NULL
    );
    CREATE TABLE mood_entries(
        id INTEGER PRIMARY KEY,
        at REAL NOT NULL,
        valence INTEGER NOT NULL,
        labels TEXT,
        note TEXT
    );
    CREATE TABLE water_entries(
        id INTEGER PRIMARY KEY,
        at REAL NOT NULL,
        ml REAL NOT NULL
    );

    -- Used only by MockHealthDataSource (Linux / simulator dev) to persist writes
    CREATE TABLE mock_samples(
        id INTEGER PRIMARY KEY,
        metric TEXT NOT NULL,
        at REAL NOT NULL,
        value REAL NOT NULL,
        value2 REAL
    );
    """
}

/// Small key-value store for app state (rolling summary, cursors, settings).
public final class KeyValueStore: Sendable {
    let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    public func get(_ key: String) -> String? {
        try? db.queryOne("SELECT value FROM kv WHERE key = ?", [key])?.string("value")
    }

    public func set(_ key: String, _ value: String?) throws {
        if let value {
            try db.execute(
                "INSERT INTO kv(key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                [key, value, Date()])
        } else {
            try db.execute("DELETE FROM kv WHERE key = ?", [key])
        }
    }
}

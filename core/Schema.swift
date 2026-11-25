import Foundation

/// The ledger schema and its migrations, kept identical to `tracker/store.py` while both engines exist
/// (tests/test_swift_schema.py fails when they drift).
enum Schema {
    static let focusRules = """
CREATE TABLE IF NOT EXISTS focus_rules (
    id TEXT PRIMARY KEY, field TEXT NOT NULL CHECK(field IN ('app', 'window', 'domain', 'url')),
    keyword TEXT NOT NULL, app_scope TEXT, tag TEXT,
    project TEXT REFERENCES projects(name), chrome_profile TEXT, app_id TEXT
);
"""

    static let tables = """
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS clients (name TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS projects (
    name TEXT PRIMARY KEY, client TEXT,
    kind TEXT NOT NULL CHECK(kind IN ('billable','internal','personal'))
);
CREATE TABLE IF NOT EXISTS folders (
    path TEXT PRIMARY KEY, project TEXT NOT NULL REFERENCES projects(name)
);
CREATE TABLE IF NOT EXISTS rates (
    scope TEXT NOT NULL, name TEXT NOT NULL, meter TEXT NOT NULL, cents INTEGER NOT NULL,
    PRIMARY KEY (scope, name, meter)
);
CREATE TABLE IF NOT EXISTS model_rates (
    provider TEXT NOT NULL, model TEXT NOT NULL,
    input INTEGER NOT NULL, cached INTEGER NOT NULL, cache_write INTEGER NOT NULL,
    output INTEGER NOT NULL, PRIMARY KEY (provider, model)
);
CREATE TABLE IF NOT EXISTS subscriptions (
    name TEXT PRIMARY KEY, monthly_cents INTEGER NOT NULL CHECK(monthly_cents >= 0), provider TEXT
);
CREATE TABLE IF NOT EXISTS toggl_time (
    id INTEGER NOT NULL, account INTEGER NOT NULL, toggl_project INTEGER NOT NULL,
    project TEXT NOT NULL REFERENCES projects(name), started_at INTEGER NOT NULL,
    ended_at INTEGER NOT NULL CHECK(ended_at > started_at), PRIMARY KEY (account, id)
);
CREATE INDEX IF NOT EXISTS toggl_time_ends ON toggl_time(ended_at);
CREATE INDEX IF NOT EXISTS toggl_time_import ON toggl_time(account, toggl_project, started_at);
CREATE TABLE IF NOT EXISTS entries (
    id TEXT PRIMARY KEY, kind TEXT NOT NULL,
    at INTEGER NOT NULL, provider TEXT, model TEXT, session TEXT,
    folder TEXT, branch TEXT, task TEXT, project TEXT REFERENCES projects(name),
    label TEXT, millis INTEGER NOT NULL DEFAULT 0, input INTEGER NOT NULL DEFAULT 0,
    cached INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
    output INTEGER NOT NULL DEFAULT 0, cents INTEGER, reimbursable INTEGER NOT NULL DEFAULT 0,
    prompt_tokens INTEGER, cache_write_1h INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0,
    tier TEXT, recorded_usd TEXT, web_searches INTEGER NOT NULL DEFAULT 0, dedupe_key TEXT,
    replica INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS entries_at ON entries(at);
CREATE TABLE IF NOT EXISTS focus_blocks (
    id TEXT PRIMARY KEY, app_id TEXT NOT NULL, app_name TEXT NOT NULL,
    started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL CHECK (ended_at > started_at),
    closed INTEGER NOT NULL CHECK (closed IN (0, 1)),
    project TEXT REFERENCES projects(name), ignored INTEGER NOT NULL DEFAULT 0 CHECK (ignored IN (0, 1))
);
CREATE INDEX IF NOT EXISTS focus_ends ON focus_blocks(ended_at);

CREATE TABLE IF NOT EXISTS focus_rules (
    id TEXT PRIMARY KEY, field TEXT NOT NULL CHECK(field IN ('app', 'window', 'domain', 'url')),
    keyword TEXT NOT NULL, app_scope TEXT, tag TEXT,
    project TEXT REFERENCES projects(name), chrome_profile TEXT, app_id TEXT
);

CREATE TABLE IF NOT EXISTS focus_matches (
    block_id TEXT PRIMARY KEY REFERENCES focus_blocks(id) ON DELETE CASCADE,
    field TEXT NOT NULL, keyword TEXT NOT NULL, tag TEXT
);
CREATE TABLE IF NOT EXISTS sources (
    path TEXT PRIMARY KEY, signature TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS github_projects (
    project TEXT PRIMARY KEY REFERENCES projects(name), repo TEXT NOT NULL, refreshed_at INTEGER
);
CREATE TABLE IF NOT EXISTS github_prs (
    project TEXT NOT NULL REFERENCES github_projects(project), number INTEGER NOT NULL,
    branch TEXT NOT NULL, title TEXT NOT NULL, state TEXT NOT NULL, url TEXT NOT NULL,
    PRIMARY KEY (project, number)
);
CREATE TABLE IF NOT EXISTS github_pr_routes (
    repo TEXT COLLATE NOCASE NOT NULL, number INTEGER NOT NULL,
    project TEXT NOT NULL REFERENCES github_projects(project),
    PRIMARY KEY (repo, number)
);
CREATE TABLE IF NOT EXISTS billing_terms (
    scope TEXT NOT NULL CHECK(scope IN ('client', 'project')), name TEXT NOT NULL,
    human_cents INTEGER, agent_mode TEXT CHECK(agent_mode IS NULL OR agent_mode IN ('none', 'time', 'usage', 'hybrid')),
    agent_cents INTEGER, usage_markup TEXT, monthly_cap_cents INTEGER,
    PRIMARY KEY (scope, name)
);
CREATE TABLE IF NOT EXISTS appearance (
    scope TEXT NOT NULL CHECK(scope IN ('client', 'project')), name TEXT NOT NULL,
    color TEXT, icon TEXT, PRIMARY KEY (scope, name)
);
CREATE TABLE IF NOT EXISTS focus_github (
    block_id TEXT PRIMARY KEY REFERENCES focus_blocks(id) ON DELETE CASCADE,
    repo TEXT NOT NULL, number INTEGER
);
CREATE TABLE IF NOT EXISTS chrome_profile_clients (
    profile_id TEXT PRIMARY KEY, client TEXT NOT NULL REFERENCES clients(name) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS focus_clients (
    block_id TEXT PRIMARY KEY REFERENCES focus_blocks(id) ON DELETE CASCADE,
    client TEXT NOT NULL REFERENCES clients(name) ON DELETE CASCADE
);
"""

    /// Entry columns in insert order (Python's `ENTRY_FIELDS`).
    static let entryFields = ["id", "kind", "at", "provider", "model", "session", "folder", "branch", "task", "project", "label", "millis", "input", "cached", "cache_write", "output", "cents", "reimbursable", "prompt_tokens", "cache_write_1h", "reasoning", "tier", "recorded_usd", "web_searches", "dedupe_key", "replica"]

    /// Columns added to `entries` after the first release, with their types (Python's `ENTRY_COLUMNS`).
    static let entryColumns: [(String, String)] = [
        ("prompt_tokens", "INTEGER"),
        ("cache_write_1h", "INTEGER NOT NULL DEFAULT 0"),
        ("reasoning", "INTEGER NOT NULL DEFAULT 0"),
        ("tier", "TEXT"),
        ("recorded_usd", "TEXT"),
        ("web_searches", "INTEGER NOT NULL DEFAULT 0"),
        ("dedupe_key", "TEXT"),
        ("replica", "INTEGER NOT NULL DEFAULT 0"),
    ]

    static let selfClientDefault = "Me"

    /// Opens the ledger, creating it with owner-only permissions, and brings its schema up to date.
    static func open(_ path: String) throws -> Database {
        let manager = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: path) {
            let descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if descriptor >= 0 { close(descriptor) }
        }
        let db = try Database(path: path)
        try db.script("PRAGMA foreign_keys = ON")
        try db.script(tables)
        try migrateFocusRules(db)
        try removeDuplicateFocusRules(db)
        try migrateEntries(db)
        try migrateSettingsData(db)
        try migrateSelfClient(db)
        return db
    }

    private static func columns(_ db: Database, _ table: String) throws -> Set<String> {
        Set(try db.query("PRAGMA table_info(\(table))").compactMap { $0["name"].string })
    }

    static func migrateSelfClient(_ db: Database) throws {
        guard try db.first("SELECT 1 FROM projects WHERE client IS NULL LIMIT 1") != nil else { return }
        try db.transaction {
            let name = try Store.selfClient(db)
            try db.execute("INSERT OR IGNORE INTO clients VALUES (?)", [name])
            try db.execute("UPDATE projects SET client = ? WHERE client IS NULL", [name])
        }
    }

    static func migrateEntries(_ db: Database) throws {
        let existing = try columns(db, "entries")
        let missing = entryColumns.filter { !existing.contains($0.0) }
        if !missing.isEmpty {
            try db.transaction {
                for (name, kind) in missing {
                    try db.execute("ALTER TABLE entries ADD COLUMN \(name) \(kind)")
                }
            }
        }
        try db.execute("CREATE INDEX IF NOT EXISTS entries_dedupe ON entries(dedupe_key) WHERE dedupe_key IS NOT NULL")
    }

    static func migrateFocusRules(_ db: Database) throws {
        func needsMigration() throws -> Bool {
            let sql = try db.first("SELECT sql FROM sqlite_master WHERE name = 'focus_rules'")?["sql"].string ?? ""
            let project = try db.query("PRAGMA table_info(focus_rules)").first { $0["name"].string == "project" }
            return !sql.contains("'domain'") || project?["notnull"].int == 1
        }
        let optional = ["chrome_profile", "app_id"]
        guard try needsMigration() || !Set(optional).isSubset(of: columns(db, "focus_rules")) else { return }
        try db.transaction {
            let existing = try columns(db, "focus_rules")
            if try needsMigration() {
                let columns = (["id", "field", "keyword", "app_scope", "tag", "project"]
                               + optional.filter(existing.contains)).joined(separator: ", ")
                try db.execute("ALTER TABLE focus_rules RENAME TO old_focus_rules")
                try db.script(focusRules)
                try db.execute("INSERT INTO focus_rules (\(columns)) SELECT \(columns) FROM old_focus_rules")
                try db.execute("DROP TABLE old_focus_rules")
            } else {
                for name in optional where !existing.contains(name) {
                    try db.execute("ALTER TABLE focus_rules ADD COLUMN \(name) TEXT")
                }
            }
        }
    }

    /// Keep the same rule ID the matcher used before cleanup. Activity rows carry their own match details.
    private static func removeDuplicateFocusRules(_ db: Database) throws {
        let groups = "field, keyword, app_scope, tag, project, chrome_profile, app_id"
        guard try db.first("SELECT 1 FROM focus_rules GROUP BY \(groups) HAVING COUNT(*) > 1 LIMIT 1") != nil else { return }
        try db.execute("DELETE FROM focus_rules WHERE id NOT IN (SELECT MIN(id) FROM focus_rules GROUP BY \(groups))")
    }

    static func migrateSettingsData(_ db: Database) throws {
        guard try !columns(db, "subscriptions").contains("provider") else { return }
        try db.transaction {
            if try !columns(db, "subscriptions").contains("provider") {
                try db.execute("ALTER TABLE subscriptions ADD COLUMN provider TEXT")
            }
        }
    }
}

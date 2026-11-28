import { DatabaseSync } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";

const migrations = new URL("../../migrations/", import.meta.url);

export function openDatabase(path) {
  const database = new DatabaseSync(path, { enableForeignKeyConstraints: true });
  database.exec("PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;");
  const transaction = (operation) => {
    database.exec("BEGIN IMMEDIATE");
    try {
      const value = operation();
      database.exec("COMMIT");
      return value;
    } catch (error) {
      database.exec("ROLLBACK");
      throw error;
    }
  };
  try {
    database.exec("CREATE TABLE IF NOT EXISTS book_club_migrations (name TEXT PRIMARY KEY)");
    const applied = database.prepare("SELECT 1 FROM book_club_migrations WHERE name = ?");
    const record = database.prepare("INSERT INTO book_club_migrations VALUES (?)");
    for (const name of readdirSync(migrations).filter((name) => /^\d+_[a-z_]+\.sql$/u.test(name)).sort()) {
      transaction(() => {
        if (applied.get(name)) return;
        database.exec(readFileSync(new URL(name, migrations), "utf8"));
        record.run(name);
      });
    }
  } catch (error) {
    database.close();
    throw error;
  }
  return {
    prepare(sql) {
      return {
        bind(...values) {
          const statement = () => database.prepare(sql);
          return {
            first: () => statement().get(...values) ?? null,
            run: () => ({ meta: { changes: statement().run(...values).changes } }),
            all() {
              const query = statement();
              if (query.columns().length) return { results: query.all(...values), meta: { changes: 0 } };
              return { results: [], meta: { changes: query.run(...values).changes } };
            },
          };
        },
      };
    },
    batch: (statements) => transaction(() => statements.map((statement) => statement.all())),
    close: () => database.close(),
  };
}

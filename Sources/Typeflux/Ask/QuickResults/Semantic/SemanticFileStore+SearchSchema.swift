import Foundation
import SQLite3

extension SemanticFileStore {
    // Track dirty pages, not an ever-growing mutation log. Tombstones survive ID reuse and deletions.
    // Compatible Float32 payloads remain on disk; Float16 is only a disposable search representation.
    // swiftlint:disable:next function_body_length
    func prepareSearchSchema() throws {
        try transaction {
            try addColumn("chunks", name: "search_script", declaration: "INTEGER NOT NULL DEFAULT 0")
            try sql("""
            CREATE TABLE IF NOT EXISTS search_revision(value INTEGER NOT NULL);
            INSERT INTO search_revision SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM search_revision);
            CREATE TABLE IF NOT EXISTS vector_pages(page INTEGER PRIMARY KEY,revision INTEGER NOT NULL);
            INSERT OR IGNORE INTO vector_pages SELECT id/256,0 FROM chunks GROUP BY id/256;
            CREATE TRIGGER IF NOT EXISTS vector_insert AFTER INSERT ON chunks BEGIN
                UPDATE search_revision SET value=value+1;
                INSERT OR REPLACE INTO vector_pages VALUES(new.id/256,(SELECT value FROM search_revision));
            END;
            CREATE TRIGGER IF NOT EXISTS vector_delete AFTER DELETE ON chunks BEGIN
                UPDATE search_revision SET value=value+1;
                INSERT OR REPLACE INTO vector_pages VALUES(old.id/256,(SELECT value FROM search_revision));
            END;
            CREATE TRIGGER IF NOT EXISTS vector_update AFTER UPDATE ON chunks BEGIN
                UPDATE search_revision SET value=value+1;
                INSERT OR REPLACE INTO vector_pages VALUES(old.id/256,(SELECT value FROM search_revision));
                INSERT OR REPLACE INTO vector_pages VALUES(new.id/256,(SELECT value FROM search_revision));
            END;
            CREATE TRIGGER IF NOT EXISTS vector_file_update AFTER UPDATE ON files BEGIN
                UPDATE search_revision SET value=value+1;
                INSERT OR REPLACE INTO vector_pages SELECT id/256,(SELECT value FROM search_revision)
                    FROM chunks WHERE path=new.path GROUP BY id/256;
            END;
            CREATE TABLE IF NOT EXISTS search_recipe(value TEXT NOT NULL);
            CREATE TRIGGER IF NOT EXISTS script_insert AFTER INSERT ON chunks
            WHEN new.search_script <> (new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') BEGIN
                UPDATE chunks SET search_script=(new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') WHERE id=new.id;
            END;
            CREATE TRIGGER IF NOT EXISTS script_update AFTER UPDATE OF text ON chunks
            WHEN new.search_script <> (new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') BEGIN
                UPDATE chunks SET search_script=(new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') WHERE id=new.id;
            END;
            """)
            let recipe = try statement("SELECT value FROM search_recipe")
            let current = sqlite3_step(recipe) == SQLITE_ROW ? string(recipe, 0) : ""
            sqlite3_finalize(recipe)
            if current != "unicode-v3-script" {
                try sql("DELETE FROM lexical; DELETE FROM search_recipe")
                let rows = try statement("SELECT id,text FROM chunks")
                defer { sqlite3_finalize(rows) }
                var step = sqlite3_step(rows)
                while step == SQLITE_ROW {
                    try execute("INSERT INTO lexical(rowid,terms) VALUES(?,?)",
                                [sqlite3_column_int64(rows, 0), SemanticFilePolicy.terms(string(rows, 1))])
                    let script = SemanticScoreCalibration.script(string(rows, 1))
                    try execute("UPDATE chunks SET search_script=? WHERE id=? AND search_script<>?",
                                [script, sqlite3_column_int64(rows, 0), script])
                    step = sqlite3_step(rows)
                }
                guard step == SQLITE_DONE else { throw Failure.database }
                try sql("INSERT INTO search_recipe VALUES('unicode-v3-script')")
            }
        }
    }
}

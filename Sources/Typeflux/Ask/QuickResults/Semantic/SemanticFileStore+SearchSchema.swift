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
            DROP TRIGGER IF EXISTS vector_file_update;
            CREATE TRIGGER IF NOT EXISTS vector_file_metadata_v4 AFTER UPDATE OF path,modified,version ON files BEGIN
                UPDATE search_revision SET value=value+1;
                INSERT OR REPLACE INTO vector_pages SELECT id/256,(SELECT value FROM search_revision)
                    FROM chunks WHERE path=new.path OR path=old.path GROUP BY id/256;
            END;
            CREATE TABLE IF NOT EXISTS search_recipe(value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS search_migration(
                id INTEGER PRIMARY KEY CHECK(id=1),page_cursor INTEGER NOT NULL DEFAULT 0,
                page_done INTEGER NOT NULL DEFAULT 0,lexical_cursor INTEGER NOT NULL DEFAULT 0,
                lexical_done INTEGER NOT NULL DEFAULT 0);
            INSERT OR IGNORE INTO search_migration(id,page_done,lexical_done)
                SELECT 1,NOT EXISTS(SELECT 1 FROM chunks LIMIT 1),NOT EXISTS(SELECT 1 FROM chunks LIMIT 1);
            CREATE VIRTUAL TABLE IF NOT EXISTS lexical_v4 USING fts5(terms);
            CREATE TABLE IF NOT EXISTS search_dirty(id INTEGER PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS vector_pending(id INTEGER PRIMARY KEY,path TEXT NOT NULL,generation TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS vector_pending_job ON vector_pending(path,generation,id);
            CREATE TRIGGER IF NOT EXISTS pending_insert AFTER INSERT ON chunks WHEN length(new.vector)=0 BEGIN
                INSERT OR REPLACE INTO vector_pending VALUES(new.id,new.path,COALESCE(new.generation,''));
            END;
            CREATE TRIGGER IF NOT EXISTS pending_update AFTER UPDATE OF vector,path,generation,id ON chunks BEGIN
                DELETE FROM vector_pending WHERE id=old.id;
                INSERT OR REPLACE INTO vector_pending SELECT new.id,new.path,COALESCE(new.generation,'') WHERE length(new.vector)=0;
            END;
            CREATE TRIGGER IF NOT EXISTS pending_delete AFTER DELETE ON chunks BEGIN
                DELETE FROM vector_pending WHERE id=old.id;
            END;
            CREATE TRIGGER IF NOT EXISTS search_insert_v4 AFTER INSERT ON chunks BEGIN
                INSERT OR IGNORE INTO search_dirty VALUES(new.id);
            END;
            CREATE TRIGGER IF NOT EXISTS search_text_v4 AFTER UPDATE OF text ON chunks BEGIN
                INSERT OR IGNORE INTO search_dirty VALUES(new.id);
            END;
            CREATE TRIGGER IF NOT EXISTS search_metadata_v4 AFTER UPDATE OF search_script ON chunks
            WHEN new.search_script <> (new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') BEGIN
                INSERT OR IGNORE INTO search_dirty VALUES(new.id);
            END;
            CREATE TRIGGER IF NOT EXISTS search_delete_v4 AFTER DELETE ON chunks BEGIN
                DELETE FROM search_dirty WHERE id=old.id;
                DELETE FROM lexical_v4 WHERE rowid=old.id;
            END;
            CREATE TRIGGER IF NOT EXISTS script_insert AFTER INSERT ON chunks
            WHEN new.search_script <> (new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') BEGIN
                UPDATE chunks SET search_script=(new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') WHERE id=new.id;
            END;
            CREATE TRIGGER IF NOT EXISTS script_update AFTER UPDATE OF text ON chunks
            WHEN new.search_script <> (new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') BEGIN
                UPDATE chunks SET search_script=(new.text GLOB '*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*[ぁ-ヿ㐀-鿿가-힯𠀀-𯨟]*') WHERE id=new.id;
            END;
            """)
        }
    }

    func writeLexical(_ id: Int64, text: String) throws {
        try execute("INSERT OR REPLACE INTO lexical(rowid,terms) VALUES(?,?)", [id, SemanticFilePolicy.terms(text)])
        try writeSearchGeneration(id, text: text)
    }

    func writeSearchGeneration(_ id: Int64, text: String?) throws {
        try execute("DELETE FROM lexical_v4 WHERE rowid=?", [id])
        if let text {
            let terms = SemanticFilePolicy.terms(text)
            if !terms.isEmpty {
                try execute("INSERT INTO lexical_v4(rowid,terms) VALUES(?,?)", [id, terms])
            }
            let script = SemanticScoreCalibration.script(text)
            try execute("UPDATE chunks SET search_script=? WHERE id=? AND search_script<>?", [script, id, script])
        }
        try execute("DELETE FROM search_dirty WHERE id=?", [id])
    }
}

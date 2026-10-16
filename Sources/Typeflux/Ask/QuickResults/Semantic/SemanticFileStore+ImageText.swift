import Foundation
import SQLite3

extension SemanticFileStore {
    static var imageRecipe: String {
        documentProvenance + ";" + SemanticImageText.recipe
    }

    static func mediaRecipe(_ path: String) -> String {
        ["png", "jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased())
            ? mediaProvenance + ";" + SemanticImageText.recipe : mediaProvenance
    }

    func hasMediaText(path: String, generation: String, chunks: [SemanticChunk]) throws -> Bool {
        try lock.withLock {
            for chunk in chunks {
                let row = try statement("""
                SELECT 1 FROM media_text t JOIN media_jobs j ON j.path=t.path
                WHERE t.path=? AND j.generation=? AND t.start_offset=? AND t.end_offset=? AND t.text=?
                """)
                defer { sqlite3_finalize(row) }
                bind(row, [path, generation, chunk.startOffset as Any, chunk.endOffset as Any, chunk.text])
                if sqlite3_step(row) != SQLITE_ROW {
                    return false
                }
            }
            return true
        }
    }

    func saveMediaText(path: String, generation: String, chunks: [SemanticChunk], vectors: [[Float]]) throws {
        guard vectors.count == chunks.count, vectors.allSatisfy(Self.valid) else { throw Failure.invalidVector }
        try lock.withLock {
            try transaction {
                for (chunk, vector) in zip(chunks, vectors) {
                    try execute("""
                    INSERT OR REPLACE INTO media_text(path,start_offset,end_offset,text,vector)
                    SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM media_jobs WHERE path=? AND generation=?)
                    """, [path, chunk.startOffset as Any, chunk.endOffset as Any, chunk.text,
                          vector.withUnsafeBytes { Data($0) }, path, generation])
                }
            }
        }
    }
}

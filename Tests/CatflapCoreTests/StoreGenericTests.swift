import CatflapCore
import Foundation
import Testing

extension StoreTests {
    @Test func testGenericStatementsBindTypesAndRollBack() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let store = try Store(paths: paths)
        try await store.execute("CREATE TABLE typed_values (id INTEGER PRIMARY KEY, n, i, r, t, b, empty_blob)")
        let blob = Data([0x42, 0, 0xff, 0x43])
        let text = "quote' and zero\0byte"
        try await store.execute("INSERT INTO typed_values VALUES (?,?,?,?,?,?,?)", bindings: [
            .integer(1), .null, .integer(9_007_199_254_740_993), .real(1.25), .text(text), .blob(blob), .blob(Data())
        ])
        let rows = try await store.query("SELECT *, typeof(n) AS nt, typeof(i) AS it, typeof(r) AS rt, typeof(t) AS tt, typeof(b) AS bt, typeof(empty_blob) AS et FROM typed_values WHERE id=?", bindings: [.integer(1)])
        let row = try #require(rows.first)
        #expect(row["n"] == .null)
        #expect(row["i"] == .integer(9_007_199_254_740_993))
        #expect(row["r"] == .real(1.25))
        #expect(row["t"] == .text(text))
        #expect(row["b"] == .blob(blob))
        #expect(row["empty_blob"] == .blob(Data()))
        #expect([row["nt"], row["it"], row["rt"], row["tt"], row["bt"], row["et"]] == [
            .text("null"), .text("integer"), .text("real"), .text("text"), .text("blob"), .text("blob")
        ])
        enum Rollback: Error { case requested }
        do {
            try await store.transaction { transaction in
                try transaction.execute("INSERT INTO typed_values (id,b) VALUES (?,?)", bindings: [.integer(2), .blob(blob)])
                #expect(try transaction.query("SELECT id FROM typed_values WHERE id=?", bindings: [.integer(2)]).count == 1)
                try transaction.execute("UPDATE typed_values SET t=? WHERE id=?", bindings: [.text("changed"), .integer(1)])
                throw Rollback.requested
            }
            Issue.record("Throwing transaction unexpectedly committed")
        } catch Rollback.requested {}
        #expect(try await store.query("SELECT id FROM typed_values WHERE id=?", bindings: [.integer(2)]).isEmpty)
        #expect(try await store.query("SELECT t FROM typed_values WHERE id=?", bindings: [.integer(1)]).first?["t"] == .text(text))
        try await store.transaction { transaction in
            try transaction.execute("INSERT INTO typed_values (id,b) VALUES (?,?)", bindings: [.integer(3), .blob(blob)])
            try transaction.execute("UPDATE typed_values SET t=? WHERE id=?", bindings: [.text("committed"), .integer(3)])
        }
        #expect(try await store.query("SELECT t FROM typed_values WHERE id=?", bindings: [.integer(3)]).first?["t"] == .text("committed"))
        do {
            try await store.transaction { transaction in
                try transaction.execute("INSERT INTO typed_values (id) VALUES (?)", bindings: [.integer(4)])
                try transaction.execute("/* cannot escape the transaction */ COMMIT")
            }
            Issue.record("Transaction-control SQL was accepted")
        } catch AgentError.storage {}
        #expect(try await store.query("SELECT id FROM typed_values WHERE id=?", bindings: [.integer(4)]).isEmpty)
    }
}

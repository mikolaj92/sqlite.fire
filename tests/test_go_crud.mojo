from sqlite_fire.sqlite import Connection, SQLITE_CONSTRAINT, SQLITE_INTEGER

def main() raises:
    var db = Connection(":memory:")
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, qty INTEGER NOT NULL)")

    # Prepared INSERTs report changes and advance last_insert_rowid.
    var insert = db.query("INSERT INTO items(key, qty) VALUES (?, ?)")
    insert.bind_text(1, "alpha")
    insert.bind_int(2, 10)
    assert not insert.step()
    assert db.changes() == 1
    assert db.last_insert_rowid() == 1
    insert.reset()
    insert.bind_text(1, "beta")
    insert.bind_int(2, 20)
    assert not insert.step()
    assert db.changes() == 1
    assert db.last_insert_rowid() == 2
    insert.close()

    # INSERT OR IGNORE leaves both the row and last-insert-rowid unchanged.
    var ignored = db.query("INSERT OR IGNORE INTO items(key, qty) VALUES (?, ?)")
    ignored.bind_text(1, "alpha")
    ignored.bind_int(2, 999)
    assert not ignored.step()
    assert db.changes() == 0
    assert db.last_insert_rowid() == 2
    ignored.close()

    # REPLACE deletes the conflicting row and inserts a new rowid.
    var replaced = db.query("INSERT OR REPLACE INTO items(key, qty) VALUES (?, ?)")
    replaced.bind_text(1, "alpha")
    replaced.bind_int(2, 30)
    assert not replaced.step()
    assert db.changes() == 1
    assert db.last_insert_rowid() == 3
    replaced.close()

    var replacement_row = db.query("SELECT id, qty FROM items WHERE key = ?")
    replacement_row.bind_text(1, "alpha")
    assert replacement_row.step()
    assert replacement_row.column_type(0) == Int(SQLITE_INTEGER)
    assert replacement_row.column_int(0) == 3
    assert replacement_row.column_int(1) == 30
    assert not replacement_row.step()
    replacement_row.close()

    # UPDATE changes a row without changing last_insert_rowid.
    var update = db.query("UPDATE items SET qty = ? WHERE key = ?")
    update.bind_int(1, 31)
    update.bind_text(2, "alpha")
    assert not update.step()
    assert db.changes() == 1
    assert db.last_insert_rowid() == 3
    update.close()

    # An upsert taking its UPDATE arm has the same rowid invariant.
    var upsert = db.query("INSERT INTO items(key, qty) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET qty = excluded.qty")
    upsert.bind_text(1, "alpha")
    upsert.bind_int(2, 32)
    assert not upsert.step()
    assert db.changes() == 1
    assert db.last_insert_rowid() == 3
    upsert.close()

    # DELETE reports one changed row and does not alter last_insert_rowid.
    var delete_stmt = db.query("DELETE FROM items WHERE key = ?")
    delete_stmt.bind_text(1, "beta")
    assert not delete_stmt.step()
    assert db.changes() == 1
    assert db.last_insert_rowid() == 3
    delete_stmt.close()

    # A failed uniqueness conflict preserves the previous successful rowid.
    var failed = db.query("INSERT INTO items(key, qty) VALUES (?, ?)")
    failed.bind_text(1, "alpha")
    failed.bind_int(2, 100)
    assert failed.step_code() == Int(SQLITE_CONSTRAINT)
    assert db.last_insert_rowid() == 3
    try:
        failed.close()
        assert False
    except e:
        assert e.code == Int(SQLITE_CONSTRAINT)

    var final_row = db.query("SELECT count(*), qty FROM items WHERE key = ?")
    final_row.bind_text(1, "alpha")
    assert final_row.step()
    assert final_row.column_int(0) == 1
    assert final_row.column_int(1) == 32
    assert not final_row.step()
    final_row.close()
    db.close()

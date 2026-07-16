from sqlite_fire.sqlite import Connection, SQLITE_CONSTRAINT, SQLITE_ERROR, SQLITE_INTEGER

def main() raises:
    var db = Connection(":memory:")
    db.execute("CREATE TABLE conflicts (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, item_value INTEGER NOT NULL)")

    # Seed one committed row using a prepared statement and record its identity.
    var seed = db.query("INSERT INTO conflicts(key, item_value) VALUES (?, ?)")
    seed.bind_text(1, "stable")
    seed.bind_int(2, 10)
    assert not seed.step()
    assert db.changes() == 1
    assert db.last_insert_rowid() == 1
    seed.close()
    var original_rowid = db.last_insert_rowid()

    # IGNORE keeps the original value, change count, and last-insert rowid.
    var ignored = db.query("INSERT OR IGNORE INTO conflicts(key, item_value) VALUES (?, ?)")
    ignored.bind_text(1, "stable")
    ignored.bind_int(2, 99)
    assert not ignored.step()
    assert db.changes() == 0
    assert db.last_insert_rowid() == original_rowid
    ignored.close()

    var ignored_row = db.query("SELECT id, item_value FROM conflicts WHERE key = ?")
    ignored_row.bind_text(1, "stable")
    assert ignored_row.step()
    assert ignored_row.column_type(0) == Int(SQLITE_INTEGER)
    assert ignored_row.column_int(0) == original_rowid
    assert ignored_row.column_int(1) == 10
    assert not ignored_row.step()
    ignored_row.close()

    # REPLACE updates the value by deleting the conflict and inserting a new row.
    var replaced = db.query("INSERT OR REPLACE INTO conflicts(key, item_value) VALUES (?, ?)")
    replaced.bind_text(1, "stable")
    replaced.bind_int(2, 20)
    assert not replaced.step()
    assert db.changes() == 1
    var replacement_rowid = db.last_insert_rowid()
    assert replacement_rowid != original_rowid
    replaced.close()

    var replacement = db.query("SELECT id, item_value FROM conflicts WHERE key = ?")
    replacement.bind_text(1, "stable")
    assert replacement.step()
    assert replacement.column_int(0) == replacement_rowid
    assert replacement.column_int(1) == 20
    assert not replacement.step()
    replacement.close()

    # ABORT reports CONSTRAINT and leaves the conflicting row unchanged.
    var aborted = db.query("INSERT OR ABORT INTO conflicts(key, item_value) VALUES (?, ?)")
    aborted.bind_text(1, "stable")
    aborted.bind_int(2, 30)
    assert aborted.step_code() == Int(SQLITE_CONSTRAINT)
    try:
        aborted.close()
    except e:
        assert e.code == Int(SQLITE_CONSTRAINT)

    var after_abort = db.query("SELECT count(*), item_value FROM conflicts WHERE key = ?")
    after_abort.bind_text(1, "stable")
    assert after_abort.step()
    assert after_abort.column_int(0) == 1
    assert after_abort.column_int(1) == 20
    assert not after_abort.step()
    after_abort.close()

    # FAIL reports CONSTRAINT but preserves rows inserted earlier in that statement.
    var failed = db.query("INSERT OR FAIL INTO conflicts(key, item_value) VALUES (?, ?), (?, ?)")
    failed.bind_text(1, "survivor")
    failed.bind_int(2, 40)
    failed.bind_text(3, "stable")
    failed.bind_int(4, 50)
    assert failed.step_code() == Int(SQLITE_CONSTRAINT)
    try:
        failed.close()
    except e:
        assert e.code == Int(SQLITE_CONSTRAINT)

    var after_fail = db.query("SELECT count(*) FROM conflicts")
    assert after_fail.step()
    assert after_fail.column_int(0) == 2
    assert not after_fail.step()
    after_fail.close()

    var survivor = db.query("SELECT item_value FROM conflicts WHERE key = ?")
    survivor.bind_text(1, "survivor")
    assert survivor.step()
    assert survivor.column_int(0) == 40
    assert not survivor.step()
    survivor.close()

    # OR ROLLBACK aborts the explicit transaction, including its earlier insert.
    db.begin()
    assert db.in_transaction()
    var pending = db.query("INSERT INTO conflicts(key, item_value) VALUES (?, ?)")
    pending.bind_text(1, "pending")
    pending.bind_int(2, 60)
    assert not pending.step()
    pending.close()
    assert db.in_transaction()

    var rolled_back = db.query("INSERT OR ROLLBACK INTO conflicts(key, item_value) VALUES (?, ?)")
    rolled_back.bind_text(1, "stable")
    rolled_back.bind_int(2, 70)
    assert rolled_back.step_code() == Int(SQLITE_CONSTRAINT)
    try:
        rolled_back.close()
    except e:
        assert e.code == Int(SQLITE_CONSTRAINT)
    assert not db.in_transaction()

    var after_rollback = db.query("SELECT count(*) FROM conflicts")
    assert after_rollback.step()
    assert after_rollback.column_int(0) == 2
    assert not after_rollback.step()
    after_rollback.close()

    var pending_rows = db.query("SELECT count(*) FROM conflicts WHERE key = ?")
    pending_rows.bind_text(1, "pending")
    assert pending_rows.step()
    assert pending_rows.column_int(0) == 0
    assert not pending_rows.step()
    pending_rows.close()

    var stable_after_rollback = db.query("SELECT item_value FROM conflicts WHERE key = ?")
    stable_after_rollback.bind_text(1, "stable")
    assert stable_after_rollback.step()
    assert stable_after_rollback.column_int(0) == 20
    assert not stable_after_rollback.step()
    stable_after_rollback.close()

    # The conflict already rolled back the transaction; a second rollback is an error.
    var second_rollback = False
    try:
        db.rollback()
    except e:
        second_rollback = True
        assert e.code == Int(SQLITE_ERROR)
    assert second_rollback
    assert not db.in_transaction()

    db.close()

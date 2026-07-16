from sqlite_fire.sqlite import Connection, SQLITE_CANTOPEN, SQLITE_ERROR, SQLITE_INTEGER, SQLITE_MISUSE

def main() raises:
    # CPython sqlite3 treats commit()/rollback() as harmless in autocommit mode.
    var db = Connection(":memory:")
    db.commit()
    db.commit()
    assert not db.in_transaction()
    db.rollback()
    db.rollback()
    assert not db.in_transaction()

    # A missing parent directory is a deterministic SQLITE_CANTOPEN failure.
    var cant_open = False
    try:
        var inaccessible = Connection("/tmp/sqlite_fire_cpython_missing_directory_8f4c2e/db.sqlite")
        inaccessible.close()
    except e:
        cant_open = True
        assert e.code == Int(SQLITE_CANTOPEN)
    assert cant_open

    # Every connection operation reports typed misuse after close.
    db.close()
    var execute_misuse = False
    try:
        db.execute("SELECT 1")
    except e:
        execute_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert execute_misuse

    var query_misuse = False
    try:
        var after_close_query = db.query("SELECT 1")
        after_close_query.close()
    except e:
        query_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert query_misuse

    var begin_misuse = False
    try:
        db.begin()
    except e:
        begin_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert begin_misuse

    var commit_misuse = False
    try:
        db.commit()
    except e:
        commit_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert commit_misuse

    var rollback_misuse = False
    try:
        db.rollback()
    except e:
        rollback_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert rollback_misuse

    var changes_misuse = False
    try:
        _ = db.changes()
    except e:
        changes_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert changes_misuse

    var rowid_misuse = False
    try:
        _ = db.last_insert_rowid()
    except e:
        rowid_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert rowid_misuse

    var error_code_misuse = False
    try:
        _ = db.error_code()
    except e:
        error_code_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert error_code_misuse

    var extended_error_code_misuse = False
    try:
        _ = db.extended_error_code()
    except e:
        extended_error_code_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert extended_error_code_misuse

    var busy_timeout_misuse = False
    try:
        db.busy_timeout(1)
    except e:
        busy_timeout_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert busy_timeout_misuse

    # Prepared INSERT transitions transaction state and updates rowid/changes.
    var tx = Connection(":memory:")
    tx.execute("CREATE TABLE records (id INTEGER PRIMARY KEY, value INTEGER)")
    tx.begin()
    assert tx.in_transaction()
    var insert = tx.query("INSERT INTO records(value) VALUES (?)")
    insert.bind_int(1, 73)
    assert not insert.step()
    insert.close()
    assert tx.in_transaction()
    assert tx.last_insert_rowid() == 1
    assert tx.changes() == 1
    tx.commit()
    assert not tx.in_transaction()

    # UPDATE and DELETE with no matching rows report zero changes.
    var zero_update = tx.query("UPDATE records SET value = ? WHERE id = ?")
    zero_update.bind_int(1, 99)
    zero_update.bind_int(2, 999)
    assert not zero_update.step()
    zero_update.close()
    assert tx.changes() == 0
    var zero_delete = tx.query("DELETE FROM records WHERE id = ?")
    zero_delete.bind_int(1, 999)
    assert not zero_delete.step()
    zero_delete.close()
    assert tx.changes() == 0

    # A prepared query accepts a trailing SQL comment.
    var comments = tx.query("SELECT 42 AS answer; -- trailing comment")
    assert comments.step()
    assert comments.column_int(0) == 42
    assert not comments.step()
    comments.close()

    # Malformed prepared SQL raises SQLITE_ERROR.
    var malformed = False
    try:
        var bad_query = tx.query("SELEC FROM records")
        bad_query.close()
    except e:
        malformed = True
        assert e.code == Int(SQLITE_ERROR)
    assert malformed

    # Numbered parameters bind by index even when referenced out of order.
    var indexed = tx.query("SELECT ?2 AS second, ?1 AS first")
    indexed.bind_int(1, 11)
    indexed.bind_int(2, 22)
    assert indexed.step()
    assert indexed.column_int(0) == 22
    assert indexed.column_int(1) == 11
    assert not indexed.step()
    indexed.close()

    # SQLite preserves a value well beyond the 32-bit integer range.
    var large_value = 9000000000000000000
    var large_insert = tx.query("INSERT INTO records(value) VALUES (?)")
    large_insert.bind_int(1, large_value)
    assert not large_insert.step()
    large_insert.close()
    var large_read = tx.query("SELECT value FROM records WHERE id = 2")
    assert large_read.step()
    assert large_read.column_int(0) == large_value
    assert not large_read.step()
    large_read.close()

    # Zero-row expression/CTE results retain their aliased metadata.
    var metadata = tx.query("WITH source(x) AS (SELECT 1 WHERE 0) SELECT x AS answer, x + 1 AS next_value FROM source")
    assert metadata.column_count() == 2
    assert metadata.column_name(0) == "answer"
    assert metadata.column_name(1) == "next_value"
    assert not metadata.step()
    metadata.close()

    tx.close()

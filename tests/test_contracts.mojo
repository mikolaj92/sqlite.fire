from sqlite_fire.sqlite import Connection, SQLITE_CONSTRAINT, SQLITE_MISUSE, SQLITE_RANGE, SQLITE_ROW, SQLITE_DONE

def main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL UNIQUE)\0")

    # transactions, autocommit, changes
    assert not db.in_transaction()
    db.begin()
    assert db.in_transaction()
    db.execute("INSERT INTO t(v) VALUES (1)\0")
    assert db.changes() == 1
    db.commit()
    assert not db.in_transaction()
    assert db.changes() == 1

    db.begin()
    db.execute("INSERT INTO t(v) VALUES (2)\0")
    assert db.in_transaction()
    db.rollback()
    assert not db.in_transaction()
    var after_rollback = db.query("SELECT count(*) FROM t\0")
    assert after_rollback.step()
    assert after_rollback.column_int(0) == 1
    assert not after_rollback.step()
    after_rollback.close()

    # ROW/DONE via step/step_code
    var rows = db.query("SELECT id, v FROM t ORDER BY id\0")
    assert rows.step_code() == Int(SQLITE_ROW)
    assert rows.column_int(0) == 1
    assert rows.step_code() == Int(SQLITE_DONE)
    rows.close()

    # range errors on parameters and columns
    var bad_param = db.query("SELECT ?\0")
    var param_range = False
    try:
        bad_param.bind_int(0, 42)
    except e:
        param_range = True
        assert e.code == Int(SQLITE_RANGE)
    assert param_range
    bad_param.close()

    var bad_col = db.query("SELECT 1\0")
    assert bad_col.step()
    var col_range = False
    try:
        _ = bad_col.column_int(1)
    except e:
        col_range = True
        assert e.code == Int(SQLITE_RANGE)
    assert col_range
    bad_col.close()

    # constraint violation surfaces on step and on close
    var dup = db.query("INSERT INTO t(v) VALUES (1)\0")
    assert dup.step_code() == Int(SQLITE_CONSTRAINT)
    try:
        dup.close()
        assert False
    except e:
        assert e.code == Int(SQLITE_CONSTRAINT)

    # idempotent close and misuse after close
    var stmt = db.query("SELECT 1\0")
    stmt.close()
    stmt.close()
    var misuse = False
    try:
        _ = stmt.step()
    except e:
        misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert misuse
    stmt.close()

    db.close()
    db.close()

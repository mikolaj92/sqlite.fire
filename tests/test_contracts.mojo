from sqlite_fire.sqlite import Connection, SQLiteValue, SQLITE_CONSTRAINT, SQLITE_MISUSE, SQLITE_NOTFOUND, SQLITE_RANGE, SQLITE_ROW, SQLITE_DONE

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


    var fetched = db.fetch_all("SELECT id, v FROM t ORDER BY id\0")
    assert len(fetched) == 1
    assert fetched[0].value_by_name("v").integer_value == 1
    var one = db.fetch_one("SELECT v FROM t WHERE id = 1\0")
    assert one.value(0).integer_value == 1
    assert db.fetch_value("SELECT count(*) FROM t\0").integer_value == 1
    var no_row = False
    try:
        _ = db.fetch_one("SELECT v FROM t WHERE id = 99\0")
    except e:
        no_row = True
        assert e.code == Int(SQLITE_NOTFOUND)
    assert no_row
    # Owned row snapshots and validated savepoint lifecycle.
    var row_stmt = db.query("SELECT id, v FROM t ORDER BY id\0")
    assert row_stmt.step()
    var snapshot = row_stmt.row()
    assert row_stmt.column_index("v") == 1
    assert row_stmt.column_decltype(0) == "INTEGER"
    assert snapshot.count() == 2
    assert snapshot.name(0) == "id"
    assert snapshot.value(0).integer_value == 1
    assert snapshot.value_by_name("v").integer_value == 1
    var missing_name = False
    try:
        _ = snapshot.value_by_name("missing")
    except:
        missing_name = True
    assert missing_name
    row_stmt.close()
    assert snapshot.value(1).integer_value == 1

    var point = db.savepoint("nested_point")
    var point_insert = db.query("INSERT INTO t(v) VALUES (?)\0")
    point_insert.bind_int(1, 3)
    assert not point_insert.step()
    point_insert.close()
    db.rollback_to(point)
    db.release(point)
    var released = False
    try:
        db.rollback_to(point)
    except:
        released = True
    assert released
    var after_savepoint = db.query("SELECT count(*) FROM t\0")
    assert after_savepoint.step()
    assert after_savepoint.column_int(0) == 1
    after_savepoint.close()

    var invalid_name = False
    try:
        _ = db.savepoint("bad-name")
    except:
        invalid_name = True
    assert invalid_name
    var nul_name = False
    try:
        _ = db.savepoint("bad\0name")
    except:
        nul_name = True
    assert nul_name
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

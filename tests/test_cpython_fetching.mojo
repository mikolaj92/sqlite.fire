from sqlite_fire.sqlite import Connection, SQLITE_INTEGER, SQLITE_NULL, SQLITE_RANGE, SQLITE_ROW, SQLITE_DONE

def main() raises:
    var db = Connection(":memory:")
    db.execute("CREATE TABLE people (id INTEGER, name TEXT, score INTEGER)")
    db.execute("INSERT INTO people VALUES (1, 'Ada', 10)")
    db.execute("INSERT INTO people VALUES (2, 'Grace', 20)")

    # A prepared SELECT exposes column metadata before its first row.
    var rows = db.query("SELECT id, name, score FROM people ORDER BY id")
    assert rows.column_count() == 3
    assert rows.column_name(0) == "id"
    assert rows.column_name(1) == "name"
    assert rows.column_name(2) == "score"

    # sqlite3_step returns ROW for each record and DONE at exhaustion.
    assert rows.step_code() == Int(SQLITE_ROW)
    assert rows.column_type(0) == Int(SQLITE_INTEGER)
    assert rows.column_int(0) == 1
    assert rows.column_text(1) == "Ada"
    assert rows.column_int(2) == 10
    assert rows.step()
    assert rows.column_int(0) == 2
    assert rows.column_text(1) == "Grace"
    assert rows.column_int(2) == 20
    assert rows.step_code() == Int(SQLITE_DONE)
    rows.close()

    # A zero-row result still carries metadata and immediately returns DONE.
    var empty = db.query("SELECT id, name, score FROM people WHERE id < 0")
    assert empty.column_count() == 3
    assert empty.column_name(0) == "id"
    assert empty.step_code() == Int(SQLITE_DONE)
    empty.close()

    # Independent statements can be active and stepped without sharing state.
    var first = db.query("SELECT name FROM people WHERE id = 1")
    var second = db.query("SELECT name FROM people WHERE id = 2")
    assert first.step()
    assert second.step()
    assert first.column_text(0) == "Ada"
    assert second.column_text(0) == "Grace"
    assert not first.step()
    assert not second.step()
    first.close()
    second.close()

    # NULL is observable through both its type and text conversion contract.
    var nullable = db.query("SELECT NULL, name FROM people WHERE id = 1")
    assert nullable.step()
    assert nullable.column_type(0) == Int(SQLITE_NULL)
    assert nullable.column_text(0) == ""
    assert nullable.column_text(1) == "Ada"
    assert not nullable.step()
    nullable.close()

    # Parameter count and bindings select exactly one row.
    var parameterized = db.query("SELECT name FROM people WHERE id = ?")
    assert parameterized.parameter_count() == 1
    parameterized.bind_int(1, 2)
    assert parameterized.step()
    assert parameterized.column_text(0) == "Grace"
    assert not parameterized.step()
    parameterized.close()

    # Invalid parameter and column indexes raise SQLITE_RANGE.
    var bad_parameter = db.query("SELECT ?")
    var parameter_failed = False
    try:
        bad_parameter.bind_int(0, 9)
    except e:
        parameter_failed = True
        assert e.code == Int(SQLITE_RANGE)
    assert parameter_failed
    bad_parameter.close()

    var bad_column = db.query("SELECT id FROM people LIMIT 1")
    var column_failed = False
    try:
        _ = bad_column.column_name(1)
    except e:
        column_failed = True
        assert e.code == Int(SQLITE_RANGE)
    assert column_failed
    bad_column.close()

    # Reset makes a statement reusable for a second observable result.
    var reusable = db.query("SELECT name FROM people WHERE id = ?")
    reusable.bind_int(1, 1)
    assert reusable.step()
    assert reusable.column_text(0) == "Ada"
    assert not reusable.step()
    reusable.reset()
    reusable.bind_int(1, 2)
    assert reusable.step()
    assert reusable.column_text(0) == "Grace"
    assert not reusable.step()
    reusable.close()

    # Expressions have metadata and deterministic scalar values.
    var expression = db.query("SELECT 2 + 3 AS total")
    assert expression.column_count() == 1
    assert expression.column_name(0) == "total"
    assert expression.step()
    assert expression.column_int(0) == 5
    assert expression.step_code() == Int(SQLITE_DONE)
    expression.close()

    db.close()

from sqlite_fire.sqlite import Connection

def main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE stress (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)\0")

    # Reuse one prepared INSERT for 1000 rows, resetting between executions.
    var insert = db.query("INSERT INTO stress(value) VALUES (?)\0")
    var i = 0
    while i < 1000:
        insert.bind_int(1, i)
        assert not insert.step()
        insert.reset()
        i += 1
    insert.close()

    var rows = db.query("SELECT count(*), sum(value) FROM stress\0")
    assert rows.step()
    assert rows.column_int(0) == 1000
    assert rows.column_int(1) == 499500
    assert not rows.step()
    rows.close()

    # A second pass confirms reset/reuse remains valid after all rows are read.
    var update = db.query("UPDATE stress SET value = value + 1 WHERE id = ?\0")
    i = 1
    while i <= 1000:
        update.bind_int(1, i)
        assert not update.step()
        update.reset()
        i += 1
    update.close()

    var check = db.query("SELECT min(value), max(value), sum(value) FROM stress\0")
    assert check.step()
    assert check.column_int(0) == 1
    assert check.column_int(1) == 1000
    assert check.column_int(2) == 500500
    assert not check.step()
    check.close()
    db.close()

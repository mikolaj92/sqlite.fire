from sqlite_fire.sqlite import Connection, SQLITE_DONE, SQLITE_ROW

def main() raises:
    var db = Connection(":memory:")
    db.execute("CREATE TABLE repeated (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")

    # Insert the single row through a prepared binding and check write metadata.
    var insert = db.query("INSERT INTO repeated(value) VALUES (?)")
    insert.bind_int(1, 4242)
    assert insert.step_code() == Int(SQLITE_DONE)
    assert db.changes() == 1
    assert db.last_insert_rowid() == 1
    insert.close()

    # Vary an arithmetic binding on every pass so stale result state is observable.
    var select = db.query("SELECT value + ? FROM repeated WHERE id = ?")
    var iteration = 0
    while iteration < 2000:
        select.bind_int(1, iteration)
        select.bind_int(2, 1)
        assert select.step_code() == Int(SQLITE_ROW)
        assert select.column_int(0) == 4242 + iteration
        assert select.step_code() == Int(SQLITE_DONE)
        select.reset()
        iteration += 1
    select.close()
    db.close()

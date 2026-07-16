from sqlite_fire.sqlite import Connection, SQLITE_CONSTRAINT

def main() raises:
    var db = Connection(":memory:\0")
    db.execute("PRAGMA foreign_keys=ON\0")

    var fk_state = db.query("PRAGMA foreign_keys\0")
    assert fk_state.step()
    assert fk_state.column_int(0) == 1
    assert not fk_state.step()
    fk_state.close()

    db.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)\0")
    db.execute("CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES parent(id))\0")

    # Parent and child values are supplied through prepared bindings.
    var parent_insert = db.query("INSERT INTO parent(id) VALUES (?)\0")
    parent_insert.bind_int(1, 7)
    assert not parent_insert.step()
    parent_insert.close()

    # Foreign-key enforcement rejects a child whose parent does not exist.
    var invalid_child = db.query("INSERT INTO child(id, parent_id) VALUES (?, ?)\0")
    invalid_child.bind_int(1, 1)
    invalid_child.bind_int(2, 999)
    assert invalid_child.step_code() == Int(SQLITE_CONSTRAINT)
    var invalid_close_constraint = False
    try:
        invalid_child.close()
    except e:
        invalid_close_constraint = True
        assert e.code == Int(SQLITE_CONSTRAINT)
    assert invalid_close_constraint

    # A child referencing the existing parent succeeds.
    var valid_child = db.query("INSERT INTO child(id, parent_id) VALUES (?, ?)\0")
    valid_child.bind_int(1, 2)
    valid_child.bind_int(2, 7)
    assert not valid_child.step()
    valid_child.close()

    var count = db.query("SELECT count(*) FROM child\0")
    assert count.step()
    assert count.column_int(0) == 1
    assert not count.step()
    count.close()

    db.close()

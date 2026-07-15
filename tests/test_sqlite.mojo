from sqlite_fire.sqlite import Connection, SQLITE_INTEGER, SQLITE_NULL, SQLITE_TEXT

fn main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE items (id INTEGER, label TEXT, missing TEXT)\0")
    db.execute("INSERT INTO items VALUES (7, 'ok', NULL)\0")

    var rows = db.query("SELECT id, label, missing FROM items\0")
    assert rows.column_count() == 3
    assert rows.column_name(0) == "id"
    assert rows.step()
    assert rows.column_type(0) == Int(SQLITE_INTEGER)
    assert rows.column_type(1) == Int(SQLITE_TEXT)
    assert rows.column_type(2) == Int(SQLITE_NULL)
    assert rows.column_int(0) == 7
    assert rows.column_text(1) == "ok"
    assert rows.column_text(2) == ""
    assert not rows.step()
    db.close()


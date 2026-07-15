from sqlite_fire.sqlite import Connection, SQLITE_INTEGER, SQLITE_TEXT

fn main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE items (id INTEGER, label TEXT)\0")
    db.execute("INSERT INTO items VALUES (7, 'ok')\0")

    var rows = db.query("SELECT id, label FROM items\0")
    assert rows.column_count() == 2
    assert rows.step()
    assert rows.column_type(0) == Int(SQLITE_INTEGER)
    assert rows.column_type(1) == Int(SQLITE_TEXT)
    assert rows.column_int(0) == 7
    assert rows.column_text(1) == "ok"
    assert not rows.step()

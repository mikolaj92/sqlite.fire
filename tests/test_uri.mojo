from sqlite_fire.sqlite import Connection, SQLITE_READONLY, error_code

def main() raises:
    var path = "file:/tmp/sqlite_fire_uri.db?mode=rwc\0"
    var db = Connection(path)
    db.execute("DROP TABLE IF EXISTS uri_values\0")
    db.execute("CREATE TABLE uri_values (id INTEGER PRIMARY KEY, value TEXT)\0")
    db.execute("INSERT INTO uri_values(value) VALUES ('created')\0")
    db.close()

    var read_only = Connection("file:/tmp/sqlite_fire_uri.db?mode=ro\0")
    var rows = read_only.query("SELECT value FROM uri_values WHERE id = 1\0")
    assert rows.step()
    assert rows.column_text(0) == "created"
    assert not rows.step()
    rows.close()

    try:
        read_only.execute("INSERT INTO uri_values(value) VALUES ('blocked')\0")
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_READONLY)
    read_only.close()

    var cleanup = Connection(path)
    cleanup.execute("DROP TABLE uri_values\0")
    cleanup.close()

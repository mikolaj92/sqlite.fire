from sqlite_fire.sqlite import Connection, SQLITE_BUSY, SQLITE_READONLY

def main() raises:
    var path = "file:/tmp/sqlite_fire_go_uri_locking.db?mode=rwc\0"
    var db = Connection(path)
    db.execute("DROP TABLE IF EXISTS go_uri_locking\0")
    db.execute("CREATE TABLE go_uri_locking (id INTEGER PRIMARY KEY, value TEXT)\0")
    db.execute("INSERT INTO go_uri_locking(value) VALUES ('seed')\0")

    var wal = db.query("PRAGMA journal_mode=WAL\0")
    assert wal.step()
    assert wal.column_text(0) == "wal"
    assert not wal.step()
    wal.close()
    db.close()

    var read_only = Connection("file:/tmp/sqlite_fire_go_uri_locking.db?mode=ro\0")
    var read_row = read_only.query("SELECT value FROM go_uri_locking WHERE id = 1\0")
    assert read_row.step()
    assert read_row.column_text(0) == "seed"
    assert not read_row.step()
    read_row.close()
    try:
        read_only.execute("INSERT INTO go_uri_locking(value) VALUES ('ro-write')\0")
        assert False
    except e:
        assert e.code == Int(SQLITE_READONLY)
    read_only.close()

    var read_write = Connection("file:/tmp/sqlite_fire_go_uri_locking.db?mode=rw\0")
    read_write.execute("INSERT INTO go_uri_locking(value) VALUES ('rw-write')\0")
    var rw_row = read_write.query("SELECT count(*) FROM go_uri_locking\0")
    assert rw_row.step()
    assert rw_row.column_int(0) == 2
    assert not rw_row.step()
    rw_row.close()

    read_write.busy_timeout(25)
    read_write.begin_immediate()
    var contender = Connection("file:/tmp/sqlite_fire_go_uri_locking.db?mode=rw\0")
    contender.busy_timeout(25)
    try:
        contender.execute("INSERT INTO go_uri_locking(value) VALUES ('blocked')\0")
        assert False
    except e:
        assert e.code == Int(SQLITE_BUSY)
    read_write.rollback()
    contender.execute("INSERT INTO go_uri_locking(value) VALUES ('after-lock')\0")
    contender.close()
    read_write.close()

    var i = 0
    while i < 4:
        var repeated = Connection("file:/tmp/sqlite_fire_go_uri_locking.db?mode=rw\0")
        var count = repeated.query("SELECT count(*) FROM go_uri_locking\0")
        assert count.step()
        assert count.column_int(0) == 3
        assert not count.step()
        count.close()
        repeated.close()
        i += 1

    var cleanup = Connection(path)
    cleanup.execute("DROP TABLE go_uri_locking\0")
    cleanup.close()

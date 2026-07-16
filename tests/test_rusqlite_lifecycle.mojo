from sqlite_fire.sqlite import Connection, SQLITE_CONSTRAINT, SQLITE_INTEGER, SQLITE_MISUSE, SQLITE_NULL

def main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT NOT NULL UNIQUE)\0")
    db.execute("INSERT INTO items(value) VALUES ('seed')\0")

    # reset preserves bindings; clear_bindings restores SQLite's unbound NULL.
    var reusable = db.query("SELECT ?\0")
    reusable.bind_int(1, 41)
    assert reusable.step()
    assert reusable.column_type(0) == Int(SQLITE_INTEGER)
    assert reusable.column_int(0) == 41
    reusable.reset()
    assert reusable.step()
    assert reusable.column_int(0) == 41
    reusable.reset()
    reusable.bind_int(1, 42)
    assert reusable.step()
    assert reusable.column_int(0) == 42
    reusable.reset()
    reusable.clear_bindings()
    assert reusable.step()
    assert reusable.column_type(0) == Int(SQLITE_NULL)
    assert reusable.column_text(0) == ""
    assert not reusable.step()
    reusable.close()

    # Empty, comment-only, and semicolon-only SQL are valid empty statements.
    var empty = db.query("\0")
    assert empty.column_count() == 0
    assert not empty.step()
    empty.close()
    empty.close()
    var comment = db.query("-- comment only\n\0")
    assert comment.column_count() == 0
    comment.close()
    var semicolon = db.query(";\0")
    assert semicolon.column_count() == 0
    semicolon.close()

    # Independent prepared statements keep independent cursors and bindings.
    var first = db.query("SELECT value FROM items WHERE id = ?\0")
    var second = db.query("SELECT value FROM items WHERE id = ?\0")
    first.bind_int(1, 1)
    second.bind_int(1, 1)
    assert first.step()
    assert second.step()
    assert first.column_text(0) == "seed"
    assert second.column_text(0) == "seed"
    first.close()
    second.close()

    # A constraint appears during step and is returned again by finalize.
    var duplicate = db.query("INSERT INTO items(value) VALUES ('seed')\0")
    assert duplicate.step_code() == Int(SQLITE_CONSTRAINT)
    try:
        duplicate.close()
        assert False
    except e:
        assert e.code == Int(SQLITE_CONSTRAINT)

    # Statement close is idempotent and all use-after-close calls are typed misuse.
    var closed = db.query("SELECT 1\0")
    closed.close()
    closed.close()
    try:
        _ = closed.step()
        assert False
    except e:
        assert e.code == Int(SQLITE_MISUSE)
    try:
        closed.reset()
        assert False
    except e:
        assert e.code == Int(SQLITE_MISUSE)
    try:
        closed.bind_int(1, 1)
        assert False
    except e:
        assert e.code == Int(SQLITE_MISUSE)

    # close_v2 lets an active statement finish before its handle is finalized.
    var active = db.query("SELECT value FROM items\0")
    assert active.step()
    db.close()
    assert active.column_text(0) == "seed"
    active.close()

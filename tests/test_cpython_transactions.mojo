from sqlite_fire.sqlite import Connection, SQLITE_ERROR, SQLITE_INTEGER

def main() raises:
    var db = Connection(":memory:")

    # A new connection is in autocommit mode; an empty transaction can commit.
    assert not db.in_transaction()
    db.execute("CREATE TABLE ledger (id INTEGER PRIMARY KEY, note TEXT NOT NULL)")
    db.begin()
    assert db.in_transaction()
    db.commit()
    assert not db.in_transaction()

    # Rolling back an empty transaction also returns to autocommit.
    db.begin()
    assert db.in_transaction()
    db.rollback()
    assert not db.in_transaction()

    # Committed DML survives and reports one changed row.
    db.begin()
    db.execute("INSERT INTO ledger(note) VALUES ('committed')")
    assert db.in_transaction()
    db.commit()
    assert not db.in_transaction()
    assert db.changes() == 1
    var committed = db.query("SELECT count(*) FROM ledger WHERE note = 'committed'")
    assert committed.step()
    assert committed.column_type(0) == Int(SQLITE_INTEGER)
    assert committed.column_int(0) == 1
    assert not committed.step()
    committed.close()

    # DML in a rolled-back transaction is not visible afterwards.
    db.begin()
    db.execute("INSERT INTO ledger(note) VALUES ('discarded')")
    assert db.in_transaction()
    db.rollback()
    assert not db.in_transaction()
    var discarded = db.query("SELECT count(*) FROM ledger WHERE note = 'discarded'")
    assert discarded.step()
    assert discarded.column_int(0) == 0
    assert not discarded.step()
    discarded.close()

    # DDL and its DML are transactional together.
    db.begin()
    db.execute("CREATE TABLE transient (value INTEGER)")
    db.execute("INSERT INTO transient VALUES (7)")
    assert db.in_transaction()
    db.rollback()
    assert not db.in_transaction()
    var ddl_was_rolled_back = False
    try:
        var missing = db.query("SELECT * FROM transient")
        missing.close()
    except e:
        ddl_was_rolled_back = True
        assert e.code == Int(SQLITE_ERROR)
    assert ddl_was_rolled_back

    # BEGIN IMMEDIATE and BEGIN EXCLUSIVE expose the same autocommit transition.
    db.begin_immediate()
    assert db.in_transaction()
    db.rollback()
    assert not db.in_transaction()
    db.begin_exclusive()
    assert db.in_transaction()
    db.commit()
    assert not db.in_transaction()

    # Multiple independent execute calls can be committed as one transaction.
    db.begin()
    db.execute("INSERT INTO ledger(note) VALUES ('first')")
    db.execute("INSERT INTO ledger(note) VALUES ('second')")
    db.commit()
    var pair = db.query("SELECT count(*) FROM ledger WHERE note IN ('first', 'second')")
    assert pair.step()
    assert pair.column_int(0) == 2
    assert not pair.step()
    pair.close()

    # SQLite rejects malformed SQL with the typed SQLITE_ERROR code.
    var malformed = False
    try:
        db.execute("INSRT INTO ledger(note) VALUES ('bad')")
    except e:
        malformed = True
        assert e.code == Int(SQLITE_ERROR)
    assert malformed

    # sqlite3_exec accepts a trailing SQL comment.
    db.execute("INSERT INTO ledger(note) VALUES ('commented'); -- trailing comment")
    var comments = db.query("SELECT count(*) FROM ledger WHERE note = 'commented'; -- trailing comment")
    assert comments.step()
    assert comments.column_int(0) == 1
    assert not comments.step()
    comments.close()

    db.close()

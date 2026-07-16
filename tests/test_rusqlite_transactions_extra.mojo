from sqlite_fire.sqlite import Connection, SQLITE_ERROR

def main() raises:
    # A savepoint can roll back only its nested writes, then release and commit
    # the surrounding transaction.
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE ledger (id INTEGER PRIMARY KEY, note TEXT NOT NULL)\0")
    db.begin()
    assert db.in_transaction()

    var insert = db.query("INSERT INTO ledger(note) VALUES (?)\0")
    insert.bind_text(1, "before")
    assert not insert.step()
    insert.reset()
    insert.bind_text(1, "before-two")
    assert not insert.step()
    insert.close()

    db.execute("SAVEPOINT nested\0")
    var nested_insert = db.query("INSERT INTO ledger(note) VALUES (?)\0")
    nested_insert.bind_text(1, "discarded")
    assert not nested_insert.step()
    nested_insert.close()
    db.execute("ROLLBACK TO nested\0")

    var after_rollback_to = db.query("SELECT count(*) FROM ledger\0")
    assert after_rollback_to.step()
    assert after_rollback_to.column_int(0) == 2
    assert not after_rollback_to.step()
    after_rollback_to.close()

    var retained_insert = db.query("INSERT INTO ledger(note) VALUES (?)\0")
    retained_insert.bind_text(1, "retained")
    assert not retained_insert.step()
    retained_insert.close()
    db.execute("RELEASE nested\0")
    db.commit()
    assert not db.in_transaction()

    var committed = db.query("SELECT count(*) FROM ledger\0")
    assert committed.step()
    assert committed.column_int(0) == 3
    assert not committed.step()
    committed.close()
    db.close()

    # A second BEGIN is an error, but rollback restores autocommit so a later
    # transaction can proceed normally.
    var recovered_db = Connection(":memory:\0")
    recovered_db.execute("CREATE TABLE events (note TEXT NOT NULL)\0")
    recovered_db.begin()
    assert recovered_db.in_transaction()
    var second_begin_failed = False
    try:
        recovered_db.begin()
        assert False
    except e:
        second_begin_failed = True
        assert e.code == Int(SQLITE_ERROR)
    assert second_begin_failed
    assert recovered_db.in_transaction()
    recovered_db.rollback()
    assert not recovered_db.in_transaction()

    recovered_db.begin()
    var recovered_insert = recovered_db.query("INSERT INTO events(note) VALUES (?)\0")
    recovered_insert.bind_text(1, "after-rollback")
    assert not recovered_insert.step()
    recovered_insert.close()
    recovered_db.commit()
    assert not recovered_db.in_transaction()

    var recovered_count = recovered_db.query("SELECT count(*) FROM events\0")
    assert recovered_count.step()
    assert recovered_count.column_int(0) == 1
    assert not recovered_count.step()
    recovered_count.close()
    recovered_db.close()

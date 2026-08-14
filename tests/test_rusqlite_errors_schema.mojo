from sqlite_fire.sqlite import Connection, SQLITE_ERROR, error_code

def main() raises:
    var db = Connection(":memory:\0")

    # A malformed statement reports SQLITE_ERROR, while connection diagnostics remain readable.
    var malformed = False
    try:
        db.execute("CREAT TABLE malformed (id INTEGER)\0")
        assert False
    except e:
        malformed = True
        assert error_code(e) == Int(SQLITE_ERROR)
    assert malformed
    assert db.error_code() == Int(SQLITE_ERROR)
    assert db.extended_error_code() == Int(SQLITE_ERROR)

    # The same connection recovers and can create/query schema after the failure.
    db.execute("CREATE TABLE observed (id INTEGER PRIMARY KEY, value INTEGER)\0")
    var schema = db.query(
        "SELECT name, type FROM sqlite_master WHERE type = ? AND name = ?\0"
    )
    schema.bind_text(1, "table")
    schema.bind_text(2, "observed")
    assert schema.step()
    assert schema.column_text(0) == "observed"
    assert schema.column_text(1) == "table"
    assert not schema.step()
    schema.close()

    # DDL is transactional: rolling back removes the table from sqlite_master.
    db.begin()
    db.execute("CREATE TABLE transient (value INTEGER)\0")
    var visible = db.query(
        "SELECT name FROM sqlite_master WHERE type = ? AND name = ?\0"
    )
    visible.bind_text(1, "table")
    visible.bind_text(2, "transient")
    assert visible.step()
    assert visible.column_text(0) == "transient"
    assert not visible.step()
    visible.close()
    db.rollback()
    assert not db.in_transaction()

    var absent = db.query(
        "SELECT name FROM sqlite_master WHERE type = ? AND name = ?\0"
    )
    absent.bind_text(1, "table")
    absent.bind_text(2, "transient")
    assert not absent.step()
    absent.close()

    # changes(): zero-row UPDATE, two-row UPDATE, and one-row DELETE.
    db.execute("CREATE TABLE changes_demo (id INTEGER PRIMARY KEY, value INTEGER)\0")
    var insert = db.query("INSERT INTO changes_demo(value) VALUES (?)\0")
    insert.bind_int(1, 10)
    assert not insert.step()
    insert.close()
    assert db.changes() == 1
    var insert_two = db.query("INSERT INTO changes_demo(value) VALUES (?)\0")
    insert_two.bind_int(1, 20)
    assert not insert_two.step()
    insert_two.close()
    assert db.changes() == 1
    var insert_three = db.query("INSERT INTO changes_demo(value) VALUES (?)\0")
    insert_three.bind_int(1, 30)
    assert not insert_three.step()
    insert_three.close()
    assert db.changes() == 1

    var update_none = db.query(
        "UPDATE changes_demo SET value = ? WHERE id = ?\0"
    )
    update_none.bind_int(1, 99)
    update_none.bind_int(2, 999)
    assert not update_none.step()
    update_none.close()
    assert db.changes() == 0

    var update_two = db.query(
        "UPDATE changes_demo SET value = ? WHERE id <= ?\0"
    )
    update_two.bind_int(1, 77)
    update_two.bind_int(2, 2)
    assert not update_two.step()
    update_two.close()
    assert db.changes() == 2

    var delete_one = db.query("DELETE FROM changes_demo WHERE id = ?\0")
    delete_one.bind_int(1, 1)
    assert not delete_one.step()
    delete_one.close()
    assert db.changes() == 1

    db.close()

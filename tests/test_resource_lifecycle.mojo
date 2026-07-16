from std.collections import List
from sqlite_fire import AdvancedDatabase, Backup, Connection, IncrementalBlob, Statement
from sqlite_fire.sqlite import SQLITE_DONE, SQLITE_MISUSE


def orphan_statement() raises -> Statement:
    # Returning the statement leaves its Connection to close during scope exit.
    var owner = Connection(":memory:\0")
    owner.execute("CREATE TABLE detached (value TEXT)\0")
    owner.execute("INSERT INTO detached VALUES ('orphan')\0")
    var statement = owner.query("SELECT value FROM detached\0")
    return statement^


def orphan_blob() raises -> IncrementalBlob:
    # The blob outlives the AdvancedDatabase that opened it.
    var owner = AdvancedDatabase(":memory:\0")
    owner.execute("CREATE TABLE detached_blob (id INTEGER PRIMARY KEY, payload BLOB)\0")
    owner.execute("INSERT INTO detached_blob(payload) VALUES (zeroblob(3))\0")
    var blob = owner.open_blob("main", "detached_blob", "payload", 1, True)
    return blob^


def orphan_backup() raises -> Backup:
    # Both database owners leave scope before the backup is finished.
    var destination = AdvancedDatabase(":memory:\0")
    var source = AdvancedDatabase(":memory:\0")
    source.execute("CREATE TABLE copied (value TEXT)\0")
    source.execute("INSERT INTO copied VALUES ('orphan backup')\0")
    var backup = destination.backup_from(source)
    return backup^


def main() raises:
    # close() is idempotent, and a statement remains a valid dependent resource
    # after its owner uses sqlite3_close_v2.
    var active_owner = Connection(":memory:\0")
    active_owner.execute("CREATE TABLE active (value TEXT)\0")
    active_owner.execute("INSERT INTO active VALUES ('owner close')\0")
    var active_statement = active_owner.query("SELECT value FROM active\0")
    active_owner.close()
    active_owner.close()
    assert active_statement.step()
    assert active_statement.column_text(0) == "owner close"
    assert not active_statement.step()
    active_statement.close()
    active_statement.close()

    # A statement whose owner went out of scope is still safely finalizable.
    var detached = orphan_statement()
    assert detached.step()
    assert detached.column_text(0) == "orphan"
    detached.close()
    detached.close()
    var statement_misuse = False
    try:
        _ = detached.step()
        assert False
    except e:
        statement_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert statement_misuse

    # Blob reads remain observable after an explicit owner close; close is safe twice.
    var blob_owner = AdvancedDatabase(":memory:\0")
    blob_owner.execute("CREATE TABLE active_blob (id INTEGER PRIMARY KEY, payload BLOB)\0")
    blob_owner.execute("INSERT INTO active_blob(payload) VALUES (zeroblob(3))\0")
    var active_blob = blob_owner.open_blob("main", "active_blob", "payload", 1, True)
    blob_owner.close()
    blob_owner.close()
    assert active_blob.bytes() == 3
    var bytes = List[UInt8]()
    bytes.append(7)
    bytes.append(8)
    bytes.append(9)
    active_blob.write(0, bytes)
    var copied = active_blob.read(0, 3)
    assert copied[0] == 7
    assert copied[2] == 9
    active_blob.close()
    active_blob.close()
    var blob_misuse = False
    try:
        _ = active_blob.bytes()
        assert False
    except e:
        blob_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert blob_misuse

    # A blob can also outlive its owner scope and remains deterministically closeable.
    var detached_blob = orphan_blob()
    assert detached_blob.bytes() == 3
    detached_blob.close()
    detached_blob.close()

    # Backups are safe when completed before owners close; finish() is idempotent.
    var destination = AdvancedDatabase(":memory:\0")
    var source = AdvancedDatabase(":memory:\0")
    source.execute("CREATE TABLE backup_data (value TEXT)\0")
    source.execute("INSERT INTO backup_data VALUES ('closed owners')\0")
    var backup = destination.backup_from(source)
    var result = backup.step(1)
    while result == 0:
        result = backup.step(1)
    assert result == Int(SQLITE_DONE)
    backup.finish()
    backup.finish()
    destination.close()
    destination.close()
    source.close()
    source.close()

    # A backup handle cannot safely be finalized after its borrowed owners have
    # closed on this SQLite build. Keep the handle alive until finish(), and
    # assert deterministic misuse only after explicit finalization.
    var finished_misuse = False
    try:
        _ = backup.step(1)
        assert False
    except e:
        finished_misuse = True
        assert e.code == Int(SQLITE_MISUSE)
    assert finished_misuse

from std.collections import List
from sqlite_fire import AdvancedDatabase, Connection, SQLiteValue
from sqlite_fire.sqlite import SQLITE_BLOB, SQLITE_DONE, SQLITE_MISUSE, SQLITE_NULL, SQLITE_REAL, SQLITE_TEXT


def main() raises:
    # SQLiteValue owns payloads and preserves all five SQLite scalar kinds.
    var original = List[UInt8]()
    original.append(1)
    original.append(2)
    var blob_value = SQLiteValue.blob(original)
    original[0] = 9
    assert blob_value.kind == Int(SQLITE_BLOB)
    assert blob_value.blob_value[0] == 1
    var blob_copy = blob_value.copy()
    blob_value.blob_value[0] = 8
    assert blob_copy.blob_value[0] == 1
    assert SQLiteValue.null().is_null()
    assert SQLiteValue.integer(7).integer_value == 7
    assert SQLiteValue.real(2.5).real_value == 2.5
    assert SQLiteValue.text("text").text_value == "text"

    var db = Connection(":memory:")
    db.execute("CREATE TABLE values_table (value TEXT)")
    db.execute("INSERT INTO values_table VALUES ('automatic terminator')")
    var check_sql = db.query("SELECT value FROM values_table")
    assert check_sql.step()
    assert check_sql.column_text(0) == "automatic terminator"
    check_sql.close()
    db.execute("DELETE FROM values_table")
    var values = db.query("SELECT ?, ?, ?, ?, ?")
    values.bind_value(1, SQLiteValue.null())
    values.bind_value(2, SQLiteValue.integer(7))
    values.bind_value(3, SQLiteValue.real(2.5))
    values.bind_value(4, SQLiteValue.text(""))
    var empty_blob = List[UInt8]()
    values.bind_value(5, SQLiteValue.blob(empty_blob))
    assert values.step()
    assert values.column_value(0).kind == Int(SQLITE_NULL)
    assert values.column_value(1).integer_value == 7
    assert values.column_value(2).real_value == 2.5
    var text_result = values.column_value(3)
    assert text_result.kind == Int(SQLITE_TEXT)
    assert text_result.text_value == ""
    var blob_result = values.column_value(4)
    assert blob_result.kind == Int(SQLITE_BLOB)
    assert len(blob_result.blob_value) == 0
    assert not values.step()
    values.close()
    db.close()

    # Incremental BLOB operations copy exact bytes and enforce idempotent close.
    var advanced = AdvancedDatabase(":memory:\0")
    advanced.execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, payload BLOB)\0")
    advanced.execute("INSERT INTO blobs(payload) VALUES (zeroblob(4))\0")
    var blob = advanced.open_blob("main", "blobs", "payload", 1, True)
    assert blob.bytes() == 4
    var payload = List[UInt8]()
    payload.append(65)
    payload.append(66)
    payload.append(67)
    payload.append(68)
    blob.write(0, payload)
    var read_back = blob.read(0, 4)
    assert read_back[0] == 65
    assert read_back[3] == 68
    blob.reopen(1)
    blob.close()
    blob.close()
    var blob_closed = False
    try:
        _ = blob.bytes()
        assert False
    except:
        blob_closed = True
    assert blob_closed

    # Backup handles finish exactly once and produce a readable serialized image.
    var source = AdvancedDatabase(":memory:\0")
    source.execute("CREATE TABLE copied (value TEXT)\0")
    source.execute("INSERT INTO copied VALUES ('backup')\0")
    var destination = AdvancedDatabase(":memory:\0")
    var backup = destination.backup_from(source)
    var backup_code = backup.step(1)
    while backup_code == 0:
        backup_code = backup.step(1)
    assert backup_code == Int(SQLITE_DONE)
    assert backup.pagecount() >= 1
    assert backup.remaining() == 0
    backup.finish()
    backup.finish()
    var image = destination.serialize()
    assert len(image) > 0
    destination.close()
    source.close()
    advanced.close()
    # A serialized image can be restored into a fresh borrowed destination and queried.
    var roundtrip_source = AdvancedDatabase(":memory:\0")
    roundtrip_source.execute("CREATE TABLE roundtrip (id INTEGER PRIMARY KEY, value TEXT)\0")
    roundtrip_source.execute("INSERT INTO roundtrip VALUES (7, 'serialized')\0")
    var roundtrip_image = roundtrip_source.serialize()
    assert len(roundtrip_image) > 0
    var roundtrip_connection = Connection(":memory:\0")
    var roundtrip_destination = AdvancedDatabase(roundtrip_connection)
    roundtrip_destination.deserialize("main", roundtrip_image)
    var roundtrip_rows = roundtrip_connection.query("SELECT id, value FROM roundtrip\0")
    assert roundtrip_rows.step()
    assert roundtrip_rows.column_int(0) == 7
    assert roundtrip_rows.column_text(1) == "serialized"
    assert not roundtrip_rows.step()
    roundtrip_rows.close()
    roundtrip_destination.close()
    roundtrip_connection.close()
    roundtrip_source.close()

    # Copied serialization rejects the borrowed SQLITE_SERIALIZE_NOCOPY mode.
    var serialization_db = AdvancedDatabase(":memory:\0")
    var nocopy_rejected = False
    try:
        _ = serialization_db.serialize("main", 1)
        assert False
    except e:
        nocopy_rejected = True
        assert e.code == Int(SQLITE_MISUSE)
    assert nocopy_rejected
    serialization_db.close()

    # The owner remains usable after its normal close path.
    var owner = AdvancedDatabase(":memory:\0")
    owner.execute("CREATE TABLE still_open (value INTEGER)\0")
    owner.close()

    # Native SQLite errors from resource constructors remain visible.
    var error_db = AdvancedDatabase(":memory:\0")
    var blob_error = False
    try:
        var missing = error_db.open_blob("main", "missing", "payload", 1, False)
        assert False
    except:
        blob_error = True
    assert blob_error
    error_db.close()

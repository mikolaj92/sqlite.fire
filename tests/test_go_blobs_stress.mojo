from std.collections import List
from sqlite_fire.sqlite import Connection, SQLITE_BLOB, SQLITE_NULL

def main() raises:
    var db = Connection("file:/tmp/sqlite_fire_go_blobs_stress.db?mode=rwc\0")
    db.execute("DROP TABLE IF EXISTS go_blob_stress\0")
    db.execute("CREATE TABLE go_blob_stress (id INTEGER PRIMARY KEY, payload BLOB)\0")

    var insert = db.query("INSERT INTO go_blob_stress(payload) VALUES (?)\0")
    var empty = List[UInt8]()
    insert.bind_blob(1, empty)
    assert not insert.step()
    insert.reset()

    var one = List[UInt8]()
    one.append(0)
    insert.bind_blob(1, one)
    assert not insert.step()
    insert.reset()

    var medium = List[UInt8]()
    var i = 0
    while i < 257:
        medium.append(UInt8(i % 256))
        i += 1
    insert.bind_blob(1, medium)
    assert not insert.step()
    insert.reset()

    var large = List[UInt8]()
    i = 0
    while i < 65536:
        large.append(UInt8((i * 17 + 3) % 256))
        i += 1
    insert.bind_blob(1, large)
    assert not insert.step()
    insert.reset()

    insert.bind_null(1)
    assert not insert.step()
    insert.close()

    var rows = db.query("SELECT id, payload FROM go_blob_stress ORDER BY id\0")
    assert rows.step()
    assert rows.column_int(0) == 1
    assert rows.column_type(1) == Int(SQLITE_BLOB)
    assert len(rows.column_blob(1)) == 0

    assert rows.step()
    assert rows.column_int(0) == 2
    var one_read = rows.column_blob(1)
    assert rows.column_type(1) == Int(SQLITE_BLOB)
    assert len(one_read) == 1
    assert one_read[0] == 0

    assert rows.step()
    assert rows.column_int(0) == 3
    var medium_read = rows.column_blob(1)
    assert rows.column_type(1) == Int(SQLITE_BLOB)
    assert len(medium_read) == 257
    assert medium_read[0] == 0
    assert medium_read[1] == 1
    assert medium_read[256] == 0

    assert rows.step()
    assert rows.column_int(0) == 4
    var large_read = rows.column_blob(1)
    assert rows.column_type(1) == Int(SQLITE_BLOB)
    assert len(large_read) == 65536
    assert large_read[0] == 3
    assert large_read[1] == 20
    assert large_read[65535] == UInt8((65535 * 17 + 3) % 256)

    assert rows.step()
    assert rows.column_int(0) == 5
    assert rows.column_type(1) == Int(SQLITE_NULL)
    assert len(rows.column_blob(1)) == 0
    assert not rows.step()
    rows.close()
    db.close()

    var round = 0
    while round < 3:
        var reopened = Connection("file:/tmp/sqlite_fire_go_blobs_stress.db?mode=rw\0")
        var check = reopened.query("SELECT count(*), sum(length(payload)) FROM go_blob_stress\0")
        assert check.step()
        assert check.column_int(0) == 5
        assert check.column_int(1) == 65794
        assert not check.step()
        check.close()
        reopened.close()
        round += 1

    var cleanup = Connection("file:/tmp/sqlite_fire_go_blobs_stress.db?mode=rw\0")
    cleanup.execute("DROP TABLE go_blob_stress\0")
    cleanup.close()

from std.collections import List
from sqlite_fire.sqlite import Connection, SQLITE_BLOB, SQLITE_INTEGER, SQLITE_NULL, SQLITE_REAL, SQLITE_TEXT

def main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE typed (i INTEGER, r REAL, t TEXT, n TEXT, b BLOB)\0")

    var insert = db.query("INSERT INTO typed VALUES (?, ?, ?, ?, ?)\0")
    var payload = List[UInt8]()
    payload.append(0)
    payload.append(1)
    payload.append(255)
    insert.bind_int(1, -922337203685477580)
    insert.bind_real(2, 3.125)
    insert.bind_text(3, "utf8-zażółć-日本語")
    insert.bind_text(4, "left\0right")
    insert.bind_blob(5, payload)
    assert not insert.step()
    insert.close()

    var rows = db.query("SELECT i, r, t, n, b FROM typed\0")
    assert rows.column_count() == 5
    assert rows.column_name(0) == "i"
    assert rows.column_name(1) == "r"
    assert rows.column_name(2) == "t"
    assert rows.column_name(3) == "n"
    assert rows.column_name(4) == "b"
    assert rows.step()

    assert rows.column_type(0) == Int(SQLITE_INTEGER)
    assert rows.column_int(0) == -922337203685477580
    assert rows.column_type(1) == Int(SQLITE_REAL)
    assert rows.column_real(1) == 3.125
    assert rows.column_type(2) == Int(SQLITE_TEXT)
    assert rows.column_text(2) == "utf8-zażółć-日本語"
    assert rows.column_type(3) == Int(SQLITE_TEXT)
    assert rows.column_text(3) == "left"
    assert rows.column_type(4) == Int(SQLITE_BLOB)
    var read_blob = rows.column_blob(4)
    assert len(read_blob) == 3
    assert read_blob[0] == 0
    assert read_blob[1] == 1
    assert read_blob[2] == 255
    assert not rows.step()
    rows.close()
    var embedded = db.query("SELECT hex(n) FROM typed\0")
    assert embedded.step()
    assert embedded.column_text(0) == "6C656674007269676874"
    assert not embedded.step()
    embedded.close()

    # SQL NULL is distinct from empty text and has a stable NULL type code.
    var nulls = db.query("SELECT NULL, '', CAST(NULL AS BLOB), x'00FF'\0")
    assert nulls.column_count() == 4
    assert nulls.step()
    assert nulls.column_type(0) == Int(SQLITE_NULL)
    assert nulls.column_null(0)
    assert nulls.column_text(0) == ""
    assert nulls.column_type(1) == Int(SQLITE_TEXT)
    assert nulls.column_text(1) == ""
    assert nulls.column_type(2) == Int(SQLITE_NULL)
    assert len(nulls.column_blob(2)) == 0
    assert nulls.column_type(3) == Int(SQLITE_BLOB)
    var literal_blob = nulls.column_blob(3)
    assert len(literal_blob) == 2
    assert literal_blob[0] == 0
    assert literal_blob[1] == 255
    assert not nulls.step()
    nulls.close()

    # Type codes remain deterministic for expressions and integer affinity.
    var expressions = db.query("SELECT typeof(1), typeof(1.5), typeof('x'), typeof(NULL), typeof(x'00')\0")
    assert expressions.step()
    assert expressions.column_text(0) == "integer"
    assert expressions.column_text(1) == "real"
    assert expressions.column_text(2) == "text"
    assert expressions.column_text(3) == "null"
    assert expressions.column_text(4) == "blob"
    assert not expressions.step()
    expressions.close()
    db.close()

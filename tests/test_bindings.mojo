from std.collections import List
from sqlite_fire.sqlite import Connection, SQLITE_BLOB, SQLITE_INTEGER, SQLITE_NULL, SQLITE_REAL, SQLITE_TEXT

def main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE binding_values (id INTEGER PRIMARY KEY, text_value TEXT, int_value INTEGER, real_value REAL, blob_value BLOB, null_value TEXT)\0")

    # Bound values are data, not SQL: a quote and injection-looking text round-trip unchanged.
    var insert = db.query("INSERT INTO binding_values(text_value) VALUES (?)\0")
    insert.bind_text(1, "x'); DROP TABLE binding_values; --")
    assert not insert.step()
    insert.close()
    var injected = db.query("SELECT count(*) FROM binding_values WHERE text_value = ?\0")
    injected.bind_text(1, "x'); DROP TABLE binding_values; --")
    assert injected.step()
    assert injected.column_int(0) == 1
    assert not injected.step()
    injected.close()

    # Scalar bindings preserve SQLite's dynamic type codes.
    var scalars = db.query("SELECT ?, ?, ?, ?\0")
    scalars.bind_int(1, 42)
    scalars.bind_real(2, 2.5)
    scalars.bind_text(3, "hello")
    scalars.bind_null(4)
    assert scalars.step()
    assert scalars.column_type(0) == Int(SQLITE_INTEGER)
    assert scalars.column_int(0) == 42
    assert scalars.column_type(1) == Int(SQLITE_REAL)
    assert scalars.column_real(1) == 2.5
    assert scalars.column_type(2) == Int(SQLITE_TEXT)
    assert scalars.column_text(2) == "hello"
    assert scalars.column_type(3) == Int(SQLITE_NULL)
    assert scalars.column_null(3)
    assert not scalars.step()
    scalars.close()

    # Named parameters have stable one-based indexes and can be reused by name.
    var named = db.query("SELECT :number, @label, $number\0")
    assert named.parameter_count() == 3
    assert named.parameter_name(1) == ":number"
    assert named.parameter_name(2) == "@label"
    assert named.parameter_name(3) == "$number"
    named.bind_int(1, 7)
    named.bind_text(2, "named")
    named.bind_int(3, 9)
    assert named.step()
    assert named.column_int(0) == 7
    assert named.column_text(1) == "named"
    assert named.column_int(2) == 9
    assert not named.step()
    named.close()

    # reset retains bindings; clear_bindings replaces them with NULL.
    var reusable = db.query("SELECT ?\0")
    reusable.bind_int(1, 11)
    assert reusable.step()
    assert reusable.column_int(0) == 11
    assert not reusable.step()
    reusable.reset()
    assert reusable.step()
    assert reusable.column_int(0) == 11
    assert not reusable.step()
    reusable.clear_bindings()
    reusable.reset()
    assert reusable.step()
    assert reusable.column_type(0) == Int(SQLITE_NULL)
    assert not reusable.step()
    reusable.close()

    # Embedded NUL bytes are preserved by binding; inspect them through SQLite hex().
    var nul = db.query("SELECT hex(?)\0")
    nul.bind_text(1, "A\0B")
    assert nul.step()
    assert nul.column_text(0) == "410042"
    assert not nul.step()
    nul.close()

    # BLOB bindings are binary and expose their exact bytes.
    var blob = List[UInt8]()
    blob.append(0)
    blob.append(16)
    blob.append(255)
    var blob_stmt = db.query("SELECT ?\0")
    blob_stmt.bind_blob(1, blob)
    assert blob_stmt.step()
    assert blob_stmt.column_type(0) == Int(SQLITE_BLOB)
    var round_trip = blob_stmt.column_blob(0)
    assert len(round_trip) == 3
    assert round_trip[0] == 0
    assert round_trip[1] == 16
    assert round_trip[2] == 255
    assert not blob_stmt.step()
    blob_stmt.close()
    db.close()

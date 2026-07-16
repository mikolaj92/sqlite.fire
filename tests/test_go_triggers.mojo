from sqlite_fire.sqlite import Connection

def main() raises:
    var db = Connection(":memory:\0")

    # Recursive trigger execution is explicitly enabled for this connection.
    db.execute("PRAGMA recursive_triggers = ON\0")
    db.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)\0")
    db.execute("CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER NOT NULL, depth INTEGER NOT NULL)\0")
    db.execute("CREATE TRIGGER parent_after_insert AFTER INSERT ON parent WHEN NEW.value < 3 BEGIN INSERT INTO events(parent_id, depth) VALUES (NEW.id, NEW.value); UPDATE parent SET value = NEW.value + 1 WHERE id = NEW.id; END;\0")
    db.execute("CREATE TRIGGER parent_after_update AFTER UPDATE OF value ON parent WHEN NEW.value < 3 BEGIN INSERT INTO events(parent_id, depth) VALUES (NEW.id, NEW.value); UPDATE parent SET value = NEW.value + 1 WHERE id = NEW.id; END;\0")

    # The prepared seed starts a bounded 0 -> 1 -> 2 -> 3 trigger chain.
    var seed = db.query("INSERT INTO parent(value) VALUES (?)\0")
    seed.bind_int(1, 0)
    assert not seed.step()
    assert db.changes() == 1
    seed.close()

    var parent = db.query("SELECT value FROM parent WHERE id = ?\0")
    parent.bind_int(1, 1)
    assert parent.step()
    assert parent.column_int(0) == 3
    assert not parent.step()
    parent.close()

    var event_count = db.query("SELECT count(*), min(depth), max(depth) FROM events WHERE parent_id = ?\0")
    event_count.bind_int(1, 1)
    assert event_count.step()
    assert event_count.column_int(0) == 3
    assert event_count.column_int(1) == 0
    assert event_count.column_int(2) == 2
    assert not event_count.step()
    event_count.close()

    var event_rows = db.query("SELECT depth FROM events WHERE parent_id = ? ORDER BY id\0")
    event_rows.bind_int(1, 1)
    assert event_rows.step()
    assert event_rows.column_int(0) == 0
    assert event_rows.step()
    assert event_rows.column_int(0) == 1
    assert event_rows.step()
    assert event_rows.column_int(0) == 2
    assert not event_rows.step()
    event_rows.close()
    db.close()

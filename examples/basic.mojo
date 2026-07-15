from sqlite_fire.sqlite import Connection

fn main() raises:
    var db = Connection("/tmp/sqlite-fire-example.db\0")
    db.execute("DROP TABLE IF EXISTS users\0")
    db.execute("CREATE TABLE users (id INTEGER, name TEXT)\0")
    db.execute("INSERT INTO users VALUES (1, 'Ada')\0")
    db.execute("INSERT INTO users VALUES (2, 'Grace')\0")

    var rows = db.query("SELECT id, name FROM users ORDER BY id\0")
    while rows.step():
        print(rows.column_int(0), rows.column_text(1))

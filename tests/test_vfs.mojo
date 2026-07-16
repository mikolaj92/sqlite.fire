from sqlite_fire import Connection, OpenOptions, PassthroughVFS
from sqlite_fire.sqlite import SQLITE_OPEN_CREATE, SQLITE_OPEN_READWRITE, SQLITE_OPEN_URI


def main() raises:
    # Keep the VFS name unique and unregister only after its database closes.
    var vfs = PassthroughVFS("sqlite_fire_mojo_passthrough_vfs")
    var options = OpenOptions()
    options.flags = Int(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI)
    options.vfs = "sqlite_fire_mojo_passthrough_vfs"
    var db = Connection(":memory:\0", options)
    db.execute("CREATE TABLE vfs_values (value INTEGER)\0")
    db.execute("INSERT INTO vfs_values VALUES (42)\0")
    var rows = db.query("SELECT value FROM vfs_values\0")
    assert rows.step()
    assert rows.column_int(0) == 42
    assert not rows.step()
    rows.close()
    db.close()
    vfs.close()

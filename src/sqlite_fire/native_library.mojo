"""Resolve the sqlite.fire native bridge without depending on process cwd."""

from std.os import getenv
from std.pathlib import Path
from std.sys import CompilationTarget


def library_path() raises -> String:
    """Return the explicit bridge path or its platform loader name."""
    var configured = getenv("SQLITE_FIRE_LIBRARY")
    if configured != "":
        if not configured.startswith("/"):
            raise Error("SQLITE_FIRE_LIBRARY must be an absolute path")
        if not Path(configured).is_file():
            raise Error("SQLITE_FIRE_LIBRARY must name an existing regular file")
        return configured
    if CompilationTarget.is_linux():
        return "libsqlite_fire.so"
    if CompilationTarget.is_macos():
        return "libsqlite_fire.dylib"
    raise Error("sqlite.fire supports only Linux and macOS")

This repository is meant to be a cross-platform implementation of the `redo` build system,
as initially described by [Daniel J. Bernstein.](https://cr.yp.to/redo.html).

It is also based on apenwarr's implementation.
You can view that Python implementation in `redo` You can view that Python implementation in the `redo` directory.

You can also see Alan Grosskurth's simple shell implementation at `msh/redo-ifchange.sh`.

## What is unique about this implementation

This implementation is different in the following ways:

- It will only use `mshell` as the scripting language for the do files.
  This allows for the build system to be cross-platform.

- The implementation itself will be written in `mshell`.

- The internal implementation will use the `sqlite3` CLI binary for interacting with the database.

- A project root must be set for invocation. Right now, this is either a .git directory or a directory that has been set using the CLI interface.

  ```sh
  redo.msh root /path/to/a/project/root
  ```


## Other

The `apenwarr` implementation uses local .redo/ directories at the points of invocation.
I prefer that a single database is used at the traditional location of `$XDG_DATA_HOME`:

```
$HOME/.local/share/redo-msh # Unix
$LOCALAPPDATA/redo-msh/ # Windows
```

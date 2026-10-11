# Real filesystem failure checks

`RealStorageFailureTests` complements deterministic durable-write failpoint tests.
It checks filesystem errors before commit, not power-loss durability or every
possible error after rename.

- **EACCES:** under a non-root account, seed a committed file, remove directory
  write permission, and require a real POSIX creation failure with `errno=EACCES`.
  A failed state replacement must preserve the old bytes and leave no transaction
  files. Restore permission and verify replacement works. Cleanup restores mode
  even when assertions fail. Root explicitly skips this case; macOS CI runs it as
  the normal runner user.
- **ENOSPC:** the Linux resource CI job creates an anonymous 8 MiB tmpfs inside a
  disposable Docker container. The test requires opt-in `KILN_ENOSPC_MOUNT`, the
  exact dedicated `/kiln-enospc` path, a matching tmpfs mount in mountinfo, verified
  capacity no greater than 16 MiB, and an empty directory. It writes at most 16 MiB
  until the kernel returns `ENOSPC`, then checks failed replacement preserves old
  committed bytes and removes transaction files. Truncating the filler must make
  a subsequent replacement succeed. Docker removes the anonymous mount on exit.

Normal local tests explicitly skip ENOSPC. Do not create a host mount, fill a local
Docker volume, or point this test at application state. The CI mount contains no
user data and cannot consume the host filesystem's free disk space. CI requires
`KILN_REAL_ENOSPC_COMPLETE` in addition to a successful test exit so a skip cannot
be mistaken for execution. These checks do not simulate host reboot, power loss,
or interrupted directory flushes.

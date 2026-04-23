# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MATLAB library providing two orthogonal capabilities:

1. **Cross-platform path normalization** — the `pth` class parses mixed separators (`/`, `\`) and reassembles paths with the native OS separator.
2. **rclone-backed file caching** — `CacheToLocal` (read-cache) and `CacheLocallyForRemote` (write-cache) safely mirror files between remote storage (e.g., `Z:\` network drives) and local SSD, with audit logging via JSON.

Requires **MATLAB R2023a+** (for `jsonencode(..., PrettyPrint=true)`) and the external **`rclone`** binary.

## Running

```matlab
% Path normalization
p = pth('C:/Users/data/file.mat');
p.get()                             % -> 'C:\Users\data\file.mat' on Windows

% Read-cache (remote -> local on first access)
c = CacheToLocal(pth('Z:\remote\data.mat'), 'C:\local_cache');
localPath = c.get();                % copies via rclone on first call

% Write-cache (local first, push later)
w = CacheLocallyForRemote(pth('Z:\remote\out.mat'), 'C:\local_cache');
save(w.get(), 'results');
w.pushToRemote();                   % rclone --immutable to remote

% Tests
runtests('tests')                   % MATLAB unit test framework
```

**Required `.env` file** (gitignored) at repo root:

```
RCLONE_PATH=C:\path\to\rclone.exe
```

`CacheBase.loadEnv()` validates the path exists on construction.

## Key Classes

- **`pth`** — path value class.
  - Constructor: `pth(pathString)`.
  - `.get() → char` — normalized path.
  - Properties: `PathParts`, `StartsWithSeparator`, `EndsWithSeparator`. Leading/trailing separators are preserved.

- **`CacheBase`** (abstract handle class, extended by both cache classes).
  - Static helpers: `loadEnv()`, `computeHash(path)` → `[short_hash(6 chars), full_hash(32 chars)]` (MD5 via Java `MessageDigest`).
  - Protected: `rcloneCopy`, JSON read/write, audit-log append, collision checking, local listing.

- **`CacheToLocal`** (read-cache). Methods: `get()`, `deleteLocal()` (safe — remote untouched), `localExists()`, `getRemote()`.

- **`CacheLocallyForRemote`** (write-cache). Methods: `get()`, `pushToRemote()`, `checkSumCompareLocalAndRemote()`, `quickCompareLocalAndRemote()` (size/mtime within 2 s), `deleteLocal()` (requires checksum match — errors on mismatch), `localExists()`, `remoteExists()`, `getRemote()`.

- **`ManageCacheToLocalTempDir`** — bulk read-cache ops: `listCache`, `checkStale`, `rebuildActiveJson`, `clearEntireLocalCache`.

- **`ManageCacheLocallyForRemoteTempDir`** — bulk write-cache ops: `listCache`, `checkStale`, `rebuildActiveJson`, `pushAllLocalToRemote` (verifies all checksums first), `pushDirLocalToRemote`, `pushFileLocalToRemote`, `clearLocalCache` (only after all checksums match).

## Directory Layout

- Root — class files (`pth.m`, `CacheBase.m`, `CacheToLocal.m`, `CacheLocallyForRemote.m`, two `Manage...` managers).
- `tests/` — unit tests, one per class. Uses `tests/tmp/` as scratch space; setup/teardown follow the MATLAB `matlab.unittest` pattern.

## Cache Bookkeeping

Each cache directory contains:

- `cache_active.json` — current state (dirname hash → metadata).
- `cache_download_log.json` — append-only audit trail (read cache).
- `cache_upload_log.json` — append-only audit trail (write cache).
- `<dirname_hash>.txt` — breadcrumb file inside each cached directory.

## Gotchas

- **Cache separation is enforced.** A read cache directory must not contain `cache_upload_log.json` and vice versa. Manager constructors error on cross-contamination.
- **`dirname_hash` is MD5 of the remote directory path**, not the filename. `checkHashCollision()` guards against the vanishingly rare collision.
- **rclone `--immutable`** — if a remote file already exists and differs, the push errors rather than overwriting silently.
- **Checksum-gated deletion.** `CacheLocallyForRemote.deleteLocal()` refuses to delete until checksums match remote; the error includes size and file counts for diagnosis.
- **Handle semantics.** All cache classes are handle classes (via `CacheBase`). Pass-by-reference — copying a variable does not copy the cache.
- **UNC / `Z:\` paths are supported** via normal Windows conventions; test fixtures verify mixed-separator inputs.

## Related Repositories

Consumed by `sine_and_paired_analysis` for safe caching of 4–5 GB NRD/NSD/MED files between network drives and local SSD. Otherwise standalone — no dependencies on the other sibling repos.

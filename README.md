# pth

MATLAB utilities for **cross-platform file path handling** and **safe, rclone-backed file caching** between local and remote/network storage.

**Minimum MATLAB version**: R2023a

## Classes

| Class | Purpose |
|---|---|
| `pth` | Cross-platform path normalization |
| `CacheToLocal` | Copy remote files to a local cache (read-only remote) |
| `CacheLocallyForRemote` | Write locally, then push to remote destination |
| `ManageCacheToLocalTempDir` | Bulk operations on a read-cache directory |
| `ManageCacheLocallyForRemoteTempDir` | Bulk operations on a write-cache directory |
| `CacheBase` | Abstract base class (shared plumbing — not used directly) |

## Installation

1. Clone the repository and add it to your MATLAB path:

```matlab
addpath('/path/to/pth');
```

2. Install [rclone](https://rclone.org/) and create a `.env` file in the repo root:

```
RCLONE_PATH=C:\path\to\rclone.exe
```

> The `.env` file is gitignored and must be created on each machine.

---

## `pth` — Cross-Platform Paths

Parses a file path and reassembles it using the native file separator (`\` on Windows, `/` on macOS/Linux).

```matlab
p = pth('C:/Users/data/experiment_01/raw');
p.get()
% On Windows: 'C:\Users\data\experiment_01\raw'
% On macOS:   'C:/Users/data/experiment_01/raw'

% Mixed separators are handled correctly
p = pth('data/results\fig1.png');
p.get()  % Uses native separator
```

### API

| Method | Returns | Description |
|---|---|---|
| `pth(pathString)` | `pth` | Constructor. Accepts any separator style. |
| `get()` | `char` | Reassembles path using the current OS's separator. |

---

## `CacheToLocal` — Read Cache (Remote → Local)

Copies a file from a remote/network location to a local temp directory using `rclone copy --immutable`. The remote is **always treated as read-only**. The local copy is **always safe to delete**.

Files from the same remote directory share a local `dirname_hash/` folder, preventing filename collisions across different remote directories.

### Example

```matlab
remote = pth('\\server\share\data\session_001\recording.mat');
ct = CacheToLocal(remote, 'C:\Users\m218089\Desktop\local_data\read_cache');

% First call copies via rclone
local_path = ct.get();
%   Copying file from remote to local cache...
%     Remote: \\server\share\data\session_001\recording.mat
%     Local:  C:\...\read_cache\session_001_a3f7c2\recording.mat
%     Size:   2048.00 MB
%   Copy completed in 13.7 seconds (149.49 MB/s)

% Second call returns instantly (already cached)
local_path = ct.get();
%   Using cached local file: C:\...\read_cache\session_001_a3f7c2\recording.mat

% Load your data from the fast local copy
data = load(local_path);

% Clean up when done
ct.deleteLocal();
```

### API

| Method | Returns | Description |
|---|---|---|
| `CacheToLocal(remote_pth, local_temp_dir)` | `CacheToLocal` | Constructor. |
| `get()` | `char` | Returns local path, copying from remote if needed. |
| `deleteLocal()` | — | Deletes local cached file. Does NOT touch remote. |
| `localExists()` | `logical` | Check if local cached file exists. |
| `getRemote()` | `char` | Returns the remote file path string. |

---

## `CacheLocallyForRemote` — Write Cache (Local → Remote)

Write analysis results locally for speed, then push to a remote destination when ready using `rclone copy --immutable`. Local files are **never deleted until verified** against the remote via checksum.

### Example

```matlab
dest = pth('\\server\share\results\analysis.mat');
clf = CacheLocallyForRemote(dest, 'C:\Users\m218089\Desktop\local_data\write_cache');

% Get the local path and write your data
local_path = clf.get();
save(local_path, 'results');

% Push to remote when ready
clf.pushToRemote();
%   Pushing local file to remote...
%     Local:  C:\...\write_cache\results_e9c1a0\analysis.mat
%     Remote: \\server\share\results\analysis.mat
%   Push completed in 5.2 seconds (100.00 MB/s)

% Verify and clean up
clf.deleteLocal();  % Checksums local vs remote first. Errors if mismatch.
```

### API

| Method | Returns | Description |
|---|---|---|
| `CacheLocallyForRemote(dest_pth, local_temp_dir)` | `CacheLocallyForRemote` | Constructor. `dest_pth` is the remote **destination**. |
| `get()` | `char` | Returns local file path for writing. Does not copy. |
| `pushToRemote()` | — | Copies local file to remote with `--immutable`. |
| `checkSumCompareLocalAndRemote()` | `logical` | Compares local and remote by checksum (rclone check). |
| `quickCompareLocalAndRemote()` | `logical` | Compares by file size and modification time (2s leeway). |
| `deleteLocal()` | — | Deletes local **only after** checksum verification. Errors on mismatch. |
| `localExists()` | `logical` | Check if local file exists. |
| `remoteExists()` | `logical` | Check if remote file exists. |
| `getRemote()` | `char` | Returns the remote destination path string. |

---

## Manager Classes

### `ManageCacheToLocalTempDir` — Read Cache Manager

Bulk operations on a `CacheToLocal` temp directory.

```matlab
mgr = ManageCacheToLocalTempDir('C:\Users\m218089\Desktop\local_data\read_cache');
mgr.listCache();              % Print table of all cached entries
mgr.checkStale();             % Verify active JSON matches disk
mgr.rebuildActiveJson();      % Rebuild active JSON from disk contents
mgr.clearEntireLocalCache();  % Delete all cached files
```

### `ManageCacheLocallyForRemoteTempDir` — Write Cache Manager

Bulk operations on a `CacheLocallyForRemote` temp directory.

```matlab
mgr = ManageCacheLocallyForRemoteTempDir('C:\Users\m218089\Desktop\local_data\write_cache');
mgr.listCache();              % Print table of all cached entries
mgr.checkStale();             % Verify active JSON matches disk
mgr.pushAllLocalToRemote();   % Verify ALL checksums, then push all
mgr.pushDirLocalToRemote('results_e9c1a0');   % Push one directory
mgr.pushFileLocalToRemote('results_e9c1a0', 'analysis.mat');  % Push one file
mgr.clearLocalCache();        % Delete local only after ALL checksums match
```

---

## Safety Features

- **`rclone copy --immutable` everywhere** — existing remote files are never overwritten. If a file already exists and matches, rclone skips silently. If it differs, rclone errors.
- **Separate temp directories** — read-cache and write-cache must use different directories. Managers detect and error on cross-contamination.
- **Checksum-guarded deletion** — `CacheLocallyForRemote.deleteLocal()` verifies the remote copy matches before allowing deletion.
- **Push-all verification** — `pushAllLocalToRemote()` checks ALL checksums first, only pushes if ALL pass.
- **Hash-based directory naming** — files from the same remote directory share a `dirname_6charhash/` folder locally, preventing filename collisions.
- **Audit logs** — append-only JSON logs track every download and upload with timestamps, hashes, and file sizes.

## Cache Directory Structure

```
read_cache/
├── cache_active.json              ← current state of local cache
├── cache_download_log.json        ← append-only download history
├── session_001_a3f7c2.txt         ← human-readable breadcrumb
└── session_001_a3f7c2/
    ├── recording.mat
    └── events.csv

write_cache/
├── cache_active.json              ← current state of local files
├── cache_upload_log.json          ← append-only upload history
├── results_e9c1a0.txt
└── results_e9c1a0/
    └── analysis.mat
```

## Running Tests

```matlab
addpath('path/to/pth');
addpath('path/to/pth/tests');
runtests('tests');
```

Requires `rclone.exe` and a valid `.env` file.

---

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

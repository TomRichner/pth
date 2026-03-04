# pth

MATLAB utilities for **cross-platform file path handling** and **local caching of remote files**.

This repo provides two classes:

- **`pth`** — Parses a file path into its parts and reassembles it using the native file separator (`\` on Windows, `/` on macOS/Linux). Write paths once, run everywhere.
- **`CachedPath`** — Wraps a `pth` object pointing to a remote/network file and transparently caches it to a local directory (e.g., SSD) for faster repeated access. Validates the cache by file size, checks disk space before copying, and reports transfer speeds.

## Installation

Clone the repository and add it to your MATLAB path:

```matlab
addpath('/path/to/pth');
```

Or add it via MATLAB's **Set Path** dialog.

---

## `pth` — Cross-Platform Paths

### Basic Example

```matlab
% Create a pth object from any path style
p = pth('C:/Users/data/experiment_01/raw');

% Get the path using the current OS's file separator
p.get()
% On Windows: 'C:\Users\data\experiment_01\raw'
% On macOS:   'C:/Users/data/experiment_01/raw'
```

### Cross-Platform Paths

```matlab
% Windows-style path on any OS
p = pth('data\results\fig1.png');
p.get()  % Uses native separator

% Unix-style path on any OS
p = pth('data/results/fig1.png');
p.get()  % Uses native separator

% Mixed separators are handled correctly
p = pth('data/results\fig1.png');
p.get()  % Uses native separator
```

### Preserves Leading/Trailing Separators

```matlab
% Absolute Unix path
p = pth('/usr/local/bin/');
p.get()
% On Linux: '/usr/local/bin/'
% On Windows: '\usr\local\bin\'
```

### `pth` API

#### Constructor

```matlab
obj = pth(pathString)
```

| Argument     | Type   | Description                                   |
|-------------|--------|-----------------------------------------------|
| `pathString` | `char` | A file path string using any separator style. |

#### Properties

| Property               | Type      | Description                                        |
|------------------------|-----------|----------------------------------------------------|
| `PathParts`            | `cell`    | Cell array of individual path components.          |
| `StartsWithSeparator`  | `logical` | `true` if the original path began with `/` or `\`. |
| `EndsWithSeparator`    | `logical` | `true` if the original path ended with `/` or `\`. |

#### Methods

| Method  | Returns | Description                                                 |
|---------|---------|-------------------------------------------------------------|
| `get()` | `char`  | Reassembles the path using the current OS's file separator. |

---

## `CachedPath` — Local Caching of Remote Files

`CachedPath` is a `handle` class that wraps a `pth` object pointing to a file on a network drive or remote location. When you call `get()`, it copies the file to a local temp directory (if not already cached) and returns the local path — giving you fast, local-disk read speeds on subsequent accesses.

### How It Works

1. On first `get()`, the remote file is copied to a local temp directory with a session-specific filename.
2. On subsequent calls, the local cache is validated by comparing file sizes. If the sizes match, the cached copy is used directly.
3. Before copying, available disk space is checked (with a 10% buffer). Works on both Windows and macOS/Linux.

### Basic Example

```matlab
% Point to a large file on a network drive
remote = pth('//server/share/data/session_001/recording.mat');

% Create a cached version on local SSD
cp = CachedPath(remote, 'D:\temp_cache', 'sess001');

% First call copies the file (~2 GB at ~150 MB/s)
local_path = cp.get();
% Output:
%   Copying file from remote to local cache...
%     Remote: \\server\share\data\session_001\recording.mat
%     Local:  D:\temp_cache\recording_sess001.mat
%     Size:   2048.00 MB
%   Copy completed in 13.7 seconds (149.49 MB/s)

% Second call returns instantly from cache
local_path = cp.get();
% Output:
%   Using cached local file: D:\temp_cache\recording_sess001.mat
```

### Preemptive Caching

```matlab
% Copy the file before you need it
cp.touch();

% Later, get() returns the local path instantly
data = load(cp.get());
```

### Cleanup

```matlab
% Delete the local cached file when done
cp.clearTemp();
```

### `CachedPath` API

#### Constructor

```matlab
obj = CachedPath(remote_path_obj, local_temp_dir, session_id)
```

| Argument          | Type   | Description                                          |
|-------------------|--------|------------------------------------------------------|
| `remote_path_obj` | `pth`  | A `pth` object pointing to the remote file.          |
| `local_temp_dir`  | `char` | Local directory path for cached files.               |
| `session_id`      | `char` | Identifier appended to filename to avoid conflicts.  |

#### Properties

| Property          | Type   | Description                                      |
|-------------------|--------|--------------------------------------------------|
| `remote_path`     | `pth`  | The wrapped `pth` object for the remote file.    |
| `local_temp_dir`  | `char` | Local cache directory path.                      |
| `session_id`      | `char` | Session identifier used in cached filename.      |
| `local_file_path` | `char` | Full path to the local cached file (computed).   |

#### Methods

| Method              | Returns   | Description                                                              |
|---------------------|-----------|--------------------------------------------------------------------------|
| `get()`             | `char`    | Returns local cached path, copying from remote if needed.                |
| `get_remote()`      | `char`    | Returns the original remote file path.                                   |
| `touch()`           | —         | Preemptively copies the file to local cache.                             |
| `clearTemp()`       | —         | Deletes the local cached file.                                           |
| `check_disk_space(bytes)` | `logical` | Checks if enough local disk space exists (with 10% buffer).       |
| `compute_local_path()` | `char` | Generates the local cached file path from remote path + session ID.     |

---

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

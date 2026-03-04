# pth

A lightweight MATLAB utility class for **cross-platform file path handling**.

`pth` parses a file path string into its component parts and reassembles it using the native file separator (`\` on Windows, `/` on macOS/Linux). This makes it easy to write path-handling code that works seamlessly across operating systems.

## Installation

Clone the repository and add it to your MATLAB path:

```matlab
addpath('/path/to/pth');
```

Or add it via MATLAB's **Set Path** dialog.

## Usage

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

## API

### Constructor

```matlab
obj = pth(pathString)
```

| Argument     | Type   | Description                                    |
|-------------|--------|------------------------------------------------|
| `pathString` | `char` | A file path string using any separator style.  |

### Properties

| Property               | Type      | Description                                        |
|------------------------|-----------|----------------------------------------------------|
| `PathParts`            | `cell`    | Cell array of individual path components.          |
| `StartsWithSeparator`  | `logical` | `true` if the original path began with `/` or `\`. |
| `EndsWithSeparator`    | `logical` | `true` if the original path ended with `/` or `\`. |

### Methods

| Method  | Returns | Description                                                   |
|---------|---------|---------------------------------------------------------------|
| `get()` | `char`  | Reassembles the path using the current OS's file separator.   |

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

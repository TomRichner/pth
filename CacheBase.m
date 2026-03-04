classdef (Abstract) CacheBase < handle
    %CACHEBASE Abstract base class for rclone-backed file caching
    %   Provides shared plumbing for CacheToLocal and CacheLocallyForRemote:
    %   - MD5 hash computation for directory-based local naming
    %   - .env loading for rclone path
    %   - rclone copy wrapper with --immutable
    %   - JSON read/write utilities for active cache and log files
    %   - dirname_hash.txt creation and updates
    %
    %   Minimum MATLAB version: R2023a

    properties
        remote_path         % pth object pointing to remote file
        local_temp_dir      % Root temp directory for caching
        local_dir_name      % dirname_shorthash folder name (e.g., 'data_a3f7c2')
        local_dir_path      % Full path to local dirname_hash/ directory
        local_file_path     % Full path to local cached file
        short_hash          % 6-char MD5 hash of remote directory path
        full_hash           % Full 32-char MD5 hash of remote directory path
        rclone_path         % Path to rclone.exe (from .env)
    end

    methods
        function obj = CacheBase(remote_path_obj, local_temp_dir)
            %CACHEBASE Construct a CacheBase object
            %   remote_path_obj: pth object pointing to a remote file
            %   local_temp_dir: root temp directory for caching

            % Validate remote_path is a pth object
            if ~isa(remote_path_obj, 'pth')
                error('CacheBase:InvalidInput', ...
                    'remote_path_obj must be a pth object.');
            end

            obj.remote_path = remote_path_obj;
            obj.local_temp_dir = local_temp_dir;

            % Load rclone path from .env
            obj.rclone_path = CacheBase.loadEnv();

            % Compute hash of the remote DIRECTORY (not the file)
            remote_full = obj.remote_path.get();
            [remote_dir, filename, ext] = fileparts(remote_full);
            remote_filename = [filename, ext];

            [obj.short_hash, obj.full_hash] = CacheBase.computeHash(remote_dir);

            % Extract the directory name for the local folder name
            [~, dirname] = fileparts(remote_dir);
            if isempty(dirname)
                % Handle root paths or paths ending with separator
                dirname = 'root';
            end

            % Build local paths
            obj.local_dir_name = sprintf('%s_%s', dirname, obj.short_hash);
            obj.local_dir_path = fullfile(obj.local_temp_dir, obj.local_dir_name);
            obj.local_file_path = fullfile(obj.local_dir_path, remote_filename);

            % Ensure local temp dir exists
            if ~exist(obj.local_temp_dir, 'dir')
                mkdir(obj.local_temp_dir);
            end

            % Ensure local dirname_hash/ directory exists
            if ~exist(obj.local_dir_path, 'dir')
                mkdir(obj.local_dir_path);
            end

            % Check for hash collision in active JSON
            obj.checkHashCollision(remote_dir);

            % Create/update the dirname_hash.txt breadcrumb file
            obj.updateDirHashTxt();
        end
    end

    methods (Static)
        function rclone_exe = loadEnv()
            %LOADENV Read RCLONE_PATH from .env file in the same directory as this class
            %   Errors if .env is missing or RCLONE_PATH is not set or exe not found.

            class_dir = fileparts(mfilename('fullpath'));
            env_file = fullfile(class_dir, '.env');

            if ~exist(env_file, 'file')
                error('CacheBase:EnvNotFound', ...
                    ['.env file not found in: %s\n' ...
                     'Create a .env file with: RCLONE_PATH=C:\\path\\to\\rclone.exe'], ...
                    class_dir);
            end

            % Parse the .env file
            fid = fopen(env_file, 'r');
            if fid == -1
                error('CacheBase:EnvReadError', 'Could not open .env file: %s', env_file);
            end
            cleanup = onCleanup(@() fclose(fid));

            rclone_exe = '';
            while ~feof(fid)
                line = strtrim(fgetl(fid));
                if isempty(line) || line(1) == '#'
                    continue;
                end
                tokens = strsplit(line, '=', 'CollapseDelimiters', false);
                if numel(tokens) >= 2 && strcmp(strtrim(tokens{1}), 'RCLONE_PATH')
                    rclone_exe = strtrim(strjoin(tokens(2:end), '='));
                    break;
                end
            end

            if isempty(rclone_exe)
                error('CacheBase:RclonePathNotSet', ...
                    'RCLONE_PATH not found in .env file: %s\nAdd: RCLONE_PATH=C:\\path\\to\\rclone.exe', ...
                    env_file);
            end

            % Verify rclone exe exists
            if ~exist(rclone_exe, 'file')
                error('CacheBase:RcloneNotFound', ...
                    'rclone.exe not found at path specified in .env: %s', rclone_exe);
            end

            % Verify rclone runs
            [status, ~] = system(sprintf('"%s" --version', rclone_exe));
            if status ~= 0
                error('CacheBase:RcloneError', ...
                    'rclone at "%s" failed to run. Check installation.', rclone_exe);
            end
        end

        function [short_hash, full_hash] = computeHash(path_string)
            %COMPUTEHASH Compute MD5 hash of a path string
            %   Returns 6-char short hash and 32-char full hash.

            md = java.security.MessageDigest.getInstance('MD5');
            md.update(uint8(path_string));
            hash_bytes = typecast(md.digest(), 'uint8');
            full_hash = sprintf('%02x', hash_bytes);   % 32 hex chars
            short_hash = full_hash(1:6);               % 6 hex chars
        end
    end

    methods (Access = protected)
        function rcloneCopy(obj, src, dst)
            %RCLONECOPY Copy files using rclone with --immutable flag
            %   src and dst are paths (files or directories).
            %   Errors if rclone returns a non-zero exit code.

            cmd = sprintf('"%s" copy "%s" "%s" --immutable', obj.rclone_path, src, dst);
            [status, result] = system(cmd);
            if status ~= 0
                error('CacheBase:RcloneCopyFailed', ...
                    'rclone copy failed (exit code %d).\n  Source: %s\n  Dest:   %s\n  Output: %s', ...
                    status, src, dst, strtrim(result));
            end
        end

        function data = readJson(~, filepath)
            %READJSON Read and parse a JSON file
            %   Returns decoded struct. Returns empty struct if file doesn't exist.

            if ~exist(filepath, 'file')
                data = struct();
                return;
            end

            fid = fopen(filepath, 'r', 'n', 'UTF-8');
            if fid == -1
                error('CacheBase:JsonReadError', 'Could not open JSON file: %s', filepath);
            end
            cleanup = onCleanup(@() fclose(fid));

            raw = fread(fid, '*char')';
            if isempty(raw)
                data = struct();
                return;
            end
            data = jsondecode(raw);
        end

        function writeJson(~, filepath, data)
            %WRITEJSON Write struct to JSON file with pretty-printing

            json_str = jsonencode(data, PrettyPrint=true);
            fid = fopen(filepath, 'w', 'n', 'UTF-8');
            if fid == -1
                error('CacheBase:JsonWriteError', 'Could not write JSON file: %s', filepath);
            end
            cleanup = onCleanup(@() fclose(fid));
            fwrite(fid, json_str, 'char');
        end

        function updateActiveJson(obj, action, cache_type)
            %UPDATEACTIVEJSON Add or remove entry from cache_active.json
            %   action: 'add' or 'remove'
            %   cache_type: 'CacheToLocal' or 'CacheLocallyForRemote'

            active_path = fullfile(obj.local_temp_dir, 'cache_active.json');
            data = obj.readJson(active_path);

            % Initialize if empty
            if ~isfield(data, 'cache_type')
                data.cache_type = cache_type;
            end
            if ~isfield(data, 'entries')
                data.entries = struct();
            end

            switch action
                case 'add'
                    % Get current file list from local dirname_hash/ directory
                    files = obj.listLocalFiles();

                    remote_full = obj.remote_path.get();
                    [remote_dir, ~, ~] = fileparts(remote_full);

                    entry = struct();
                    entry.remote_dir = remote_dir;
                    entry.short_hash = obj.short_hash;
                    entry.full_hash = obj.full_hash;
                    entry.files = {files.name};
                    entry.created_at = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));

                    data.entries.(obj.local_dir_name) = entry;

                case 'remove'
                    if isfield(data.entries, obj.local_dir_name)
                        % Update the file list to reflect remaining files
                        files = obj.listLocalFiles();
                        if isempty(files)
                            data.entries = rmfield(data.entries, obj.local_dir_name);
                        else
                            data.entries.(obj.local_dir_name).files = {files.name};
                        end
                    end
            end

            obj.writeJson(active_path, data);
        end

        function appendDownloadLog(obj, remote_file, file_size_bytes)
            %APPENDDOWNLOADLOG Append an entry to cache_download_log.json

            log_path = fullfile(obj.local_temp_dir, 'cache_download_log.json');
            data = obj.readJson(log_path);

            if ~isfield(data, 'downloads')
                data.downloads = {};
            end

            remote_full = obj.remote_path.get();
            [remote_dir, ~, ~] = fileparts(remote_full);

            entry = struct();
            entry.remote_dir = remote_dir;
            entry.remote_file = remote_file;
            entry.local_dir_name = obj.local_dir_name;
            entry.short_hash = obj.short_hash;
            entry.full_hash = obj.full_hash;
            entry.downloaded_at = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
            entry.file_size_bytes = file_size_bytes;

            if iscell(data.downloads)
                data.downloads{end + 1} = entry;
            else
                % Convert from struct array to cell if needed
                existing = num2cell(data.downloads);
                existing{end + 1} = entry;
                data.downloads = existing;
            end

            obj.writeJson(log_path, data);
        end

        function appendUploadLog(obj, local_file, remote_destination, file_size_bytes)
            %APPENDUPLOADLOG Append an entry to cache_upload_log.json

            log_path = fullfile(obj.local_temp_dir, 'cache_upload_log.json');
            data = obj.readJson(log_path);

            if ~isfield(data, 'uploads')
                data.uploads = {};
            end

            entry = struct();
            entry.local_dir_name = obj.local_dir_name;
            entry.local_file = local_file;
            entry.remote_destination = remote_destination;
            entry.short_hash = obj.short_hash;
            entry.full_hash = obj.full_hash;
            entry.uploaded_at = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
            entry.file_size_bytes = file_size_bytes;

            if iscell(data.uploads)
                data.uploads{end + 1} = entry;
            else
                existing = num2cell(data.uploads);
                existing{end + 1} = entry;
                data.uploads = existing;
            end

            obj.writeJson(log_path, data);
        end

        function updateDirHashTxt(obj)
            %UPDATEDIRHASHTXT Create/update dirname_hash.txt breadcrumb file
            %   Contains remote path, full hash, and listing of cached files.

            txt_path = fullfile(obj.local_temp_dir, [obj.local_dir_name, '.txt']);

            remote_full = obj.remote_path.get();
            [remote_dir, ~, ~] = fileparts(remote_full);

            lines = {};
            lines{end + 1} = sprintf('Remote directory: %s', remote_dir);
            lines{end + 1} = sprintf('Full hash: %s', obj.full_hash);
            lines{end + 1} = sprintf('Short hash: %s', obj.short_hash);
            lines{end + 1} = '';
            lines{end + 1} = 'Files:';

            % List files currently in the dirname_hash/ directory
            files = obj.listLocalFiles();
            if isempty(files)
                lines{end + 1} = '  (none)';
            else
                for i = 1:numel(files)
                    lines{end + 1} = sprintf('  %s', files(i).name); %#ok<AGROW>
                end
            end

            writelines(string(lines), txt_path);
        end

        function files = listLocalFiles(obj)
            %LISTLOCALFILES List files in the local dirname_hash/ directory
            %   Returns dir() output for files only (no directories).

            if ~exist(obj.local_dir_path, 'dir')
                files = [];
                return;
            end

            all_items = dir(obj.local_dir_path);
            % Filter out directories (., .., and any subdirs)
            files = all_items(~[all_items.isdir]);
        end

        function checkHashCollision(obj, remote_dir)
            %CHECKHASHCOLLISION Check if the short hash already maps to a different remote dir
            %   Reads cache_active.json and verifies no collision exists.

            active_path = fullfile(obj.local_temp_dir, 'cache_active.json');
            data = obj.readJson(active_path);

            if ~isfield(data, 'entries')
                return;
            end

            if isfield(data.entries, obj.local_dir_name)
                existing_remote = data.entries.(obj.local_dir_name).remote_dir;
                if ~strcmp(existing_remote, remote_dir)
                    error('CacheBase:HashCollision', ...
                        ['Hash collision detected!\n' ...
                         '  Short hash: %s\n' ...
                         '  Existing remote dir: %s\n' ...
                         '  New remote dir: %s\n' ...
                         'This is extremely unlikely. Contact the developer.'], ...
                        obj.short_hash, existing_remote, remote_dir);
                end
            end
        end
    end
end

classdef ManageCacheToLocalTempDir < handle
    %MANAGECACHETOLOCALTTEMPDIR Manager for CacheToLocal temp directories
    %   Provides bulk operations on a read-cache temp directory:
    %   - Stale check (verify active JSON matches disk)
    %   - Rebuild active JSON from disk
    %   - Clear entire local cache
    %   - List cached entries
    %
    %   Verifies that the temp directory is a CacheToLocal directory
    %   (not CacheLocallyForRemote) by checking the cache_type in
    %   cache_active.json and ensuring no cache_upload_log.json exists.
    %
    %   Minimum MATLAB version: R2023a

    properties
        local_temp_dir      % Root temp directory
        active_json_path    % Path to cache_active.json
        log_json_path       % Path to cache_download_log.json
    end

    methods
        function obj = ManageCacheToLocalTempDir(local_temp_dir)
            %MANAGECACHETOLOCALTTEMPDIR Construct a read-cache manager
            %   local_temp_dir: root temp directory to manage

            if ~exist(local_temp_dir, 'dir')
                error('ManageCacheToLocalTempDir:DirNotFound', ...
                    'Temp directory does not exist: %s', local_temp_dir);
            end

            obj.local_temp_dir = local_temp_dir;
            obj.active_json_path = fullfile(local_temp_dir, 'cache_active.json');
            obj.log_json_path = fullfile(local_temp_dir, 'cache_download_log.json');

            % Check for cross-contamination
            upload_log_path = fullfile(local_temp_dir, 'cache_upload_log.json');
            if exist(upload_log_path, 'file')
                error('ManageCacheToLocalTempDir:CrossContamination', ...
                    ['Found cache_upload_log.json in this directory.\n' ...
                     'This directory appears to be a CacheLocallyForRemote temp dir.\n' ...
                     'CacheToLocal and CacheLocallyForRemote must use separate directories.\n' ...
                     'Directory: %s'], local_temp_dir);
            end

            % Verify cache_type if active JSON exists
            if exist(obj.active_json_path, 'file')
                data = jsondecode(fileread(obj.active_json_path));
                if isfield(data, 'cache_type') && ~strcmp(data.cache_type, 'CacheToLocal')
                    error('ManageCacheToLocalTempDir:WrongCacheType', ...
                        ['cache_active.json has cache_type = "%s".\n' ...
                         'Expected "CacheToLocal".\n' ...
                         'Directory: %s'], data.cache_type, local_temp_dir);
                end
            end
        end

        function checkStale(obj)
            %CHECKSTALE Verify active JSON matches what's on disk
            %   Errors if:
            %   - JSON says a file exists but it doesn't on disk
            %   - A dirname_hash/ directory exists on disk but isn't in JSON

            if ~exist(obj.active_json_path, 'file')
                % No active JSON — check if there are any dirname_hash dirs
                disk_dirs = obj.findDirHashDirs();
                if ~isempty(disk_dirs)
                    error('ManageCacheToLocalTempDir:Stale', ...
                        ['No cache_active.json found, but %d dirname_hash directories exist on disk.\n' ...
                         'Run rebuildActiveJson() to rebuild from disk.\n' ...
                         'Directory: %s'], numel(disk_dirs), obj.local_temp_dir);
                end
                fprintf('No active JSON and no cached directories. Cache is clean.\n');
                return;
            end

            data = jsondecode(fileread(obj.active_json_path));
            if ~isfield(data, 'entries')
                data.entries = struct();
            end

            issues = {};

            % Check JSON entries against disk
            entry_names = fieldnames(data.entries);
            for i = 1:numel(entry_names)
                dir_name = entry_names{i};
                entry = data.entries.(dir_name);
                dir_path = fullfile(obj.local_temp_dir, dir_name);

                if ~exist(dir_path, 'dir')
                    issues{end + 1} = sprintf('  JSON entry "%s" but directory not found on disk', dir_name); %#ok<AGROW>
                    continue;
                end

                % Check each file in the entry
                if isfield(entry, 'files')
                    files = entry.files;
                    if ischar(files)
                        files = {files};
                    end
                    for j = 1:numel(files)
                        file_path = fullfile(dir_path, files{j});
                        if ~exist(file_path, 'file')
                            issues{end + 1} = sprintf('  JSON says "%s/%s" exists but file not found', dir_name, files{j}); %#ok<AGROW>
                        end
                    end
                end
            end

            % Check disk against JSON
            disk_dirs = obj.findDirHashDirs();
            for i = 1:numel(disk_dirs)
                dir_name = disk_dirs{i};
                if ~isfield(data.entries, dir_name)
                    issues{end + 1} = sprintf('  Directory "%s" exists on disk but not in JSON', dir_name); %#ok<AGROW>
                end
            end

            if ~isempty(issues)
                error('ManageCacheToLocalTempDir:Stale', ...
                    'Active JSON is stale. Issues found:\n%s\nRun rebuildActiveJson() to fix.', ...
                    strjoin(issues, '\n'));
            end

            fprintf('Cache is consistent. %d entries verified.\n', numel(entry_names));
        end

        function rebuildActiveJson(obj)
            %REBUILDACTIVEJSON Scan disk and rebuild cache_active.json from scratch
            %   Reads dirname_hash.txt files to recover remote paths and hashes.

            disk_dirs = obj.findDirHashDirs();

            data = struct();
            data.cache_type = 'CacheToLocal';
            data.entries = struct();

            for i = 1:numel(disk_dirs)
                dir_name = disk_dirs{i};
                dir_path = fullfile(obj.local_temp_dir, dir_name);
                txt_path = fullfile(obj.local_temp_dir, [dir_name, '.txt']);

                entry = struct();

                % Try to read info from .txt file
                if exist(txt_path, 'file')
                    content = fileread(txt_path);
                    % Parse remote directory
                    remote_match = regexp(content, 'Remote directory: (.+)', 'tokens');
                    if ~isempty(remote_match)
                        entry.remote_dir = strtrim(remote_match{1}{1});
                    else
                        entry.remote_dir = 'unknown';
                    end
                    % Parse full hash
                    hash_match = regexp(content, 'Full hash: ([0-9a-f]+)', 'tokens');
                    if ~isempty(hash_match)
                        entry.full_hash = hash_match{1}{1};
                        entry.short_hash = entry.full_hash(1:6);
                    else
                        entry.full_hash = 'unknown';
                        entry.short_hash = 'unknown';
                    end
                else
                    entry.remote_dir = 'unknown';
                    entry.full_hash = 'unknown';
                    entry.short_hash = 'unknown';
                    warning('ManageCacheToLocalTempDir:NoTxtFile', ...
                        'No .txt breadcrumb found for: %s', dir_name);
                end

                % List files in directory
                all_items = dir(dir_path);
                files = all_items(~[all_items.isdir]);
                entry.files = {files.name};
                entry.created_at = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));

                data.entries.(dir_name) = entry;
            end

            % Write rebuilt JSON
            json_str = jsonencode(data, PrettyPrint=true);
            fid = fopen(obj.active_json_path, 'w', 'n', 'UTF-8');
            cleanup = onCleanup(@() fclose(fid));
            fwrite(fid, json_str, 'char');

            fprintf('Rebuilt cache_active.json with %d entries.\n', numel(disk_dirs));
        end

        function clearEntireLocalCache(obj)
            %CLEARENTIRELOCALCACHE Delete all cached directories and .txt files
            %   Resets cache_active.json to empty.
            %   Verifies no cache_upload_log.json exists first.

            % Safety check: no upload log should exist
            upload_log_path = fullfile(obj.local_temp_dir, 'cache_upload_log.json');
            if exist(upload_log_path, 'file')
                error('ManageCacheToLocalTempDir:CrossContamination', ...
                    'Found cache_upload_log.json. Cannot clear — this may be a write-cache dir.');
            end

            if ~exist(obj.active_json_path, 'file')
                fprintf('No cache_active.json found. Nothing to clear.\n');
                return;
            end

            data = jsondecode(fileread(obj.active_json_path));
            if ~isfield(data, 'entries')
                fprintf('No entries in cache_active.json. Nothing to clear.\n');
                return;
            end

            entry_names = fieldnames(data.entries);
            cleared_count = 0;

            for i = 1:numel(entry_names)
                dir_name = entry_names{i};
                dir_path = fullfile(obj.local_temp_dir, dir_name);
                txt_path = fullfile(obj.local_temp_dir, [dir_name, '.txt']);

                if exist(dir_path, 'dir')
                    rmdir(dir_path, 's');
                    cleared_count = cleared_count + 1;
                end
                if exist(txt_path, 'file')
                    delete(txt_path);
                end
            end

            % Reset active JSON
            data.entries = struct();
            json_str = jsonencode(data, PrettyPrint=true);
            fid = fopen(obj.active_json_path, 'w', 'n', 'UTF-8');
            cleanup = onCleanup(@() fclose(fid));
            fwrite(fid, json_str, 'char');

            fprintf('Cleared %d cached directories.\n', cleared_count);
        end

        function listCache(obj)
            %LISTCACHE Print a table of all cached entries

            if ~exist(obj.active_json_path, 'file')
                fprintf('No cache_active.json found. Cache is empty.\n');
                return;
            end

            data = jsondecode(fileread(obj.active_json_path));
            if ~isfield(data, 'entries') || isempty(fieldnames(data.entries))
                fprintf('Cache is empty.\n');
                return;
            end

            entry_names = fieldnames(data.entries);
            total_size = 0;

            fprintf('\n%-25s  %-50s  %5s  %10s\n', 'Local Dir', 'Remote Dir', 'Files', 'Size (MB)');
            fprintf('%s\n', repmat('-', 1, 95));

            for i = 1:numel(entry_names)
                dir_name = entry_names{i};
                entry = data.entries.(dir_name);
                dir_path = fullfile(obj.local_temp_dir, dir_name);

                % Count files and size
                if exist(dir_path, 'dir')
                    all_items = dir(dir_path);
                    files = all_items(~[all_items.isdir]);
                    n_files = numel(files);
                    dir_size = sum([files.bytes]) / 1024 / 1024;
                else
                    n_files = 0;
                    dir_size = 0;
                end
                total_size = total_size + dir_size;

                remote_dir = entry.remote_dir;
                if length(remote_dir) > 50
                    remote_dir = ['...' remote_dir(end-46:end)];
                end

                fprintf('%-25s  %-50s  %5d  %10.2f\n', dir_name, remote_dir, n_files, dir_size);
            end

            fprintf('%s\n', repmat('-', 1, 95));
            fprintf('Total: %d entries, %.2f MB\n\n', numel(entry_names), total_size);
        end
    end

    methods (Access = private)
        function dirs = findDirHashDirs(obj)
            %FINDDIRHASHDIRS Find all dirname_hash/ directories on disk
            %   Returns cell array of directory names (not full paths).

            all_items = dir(obj.local_temp_dir);
            dirs = {};
            for i = 1:numel(all_items)
                if all_items(i).isdir && ~startsWith(all_items(i).name, '.')
                    % Check if it has the dirname_hash pattern (contains _)
                    if contains(all_items(i).name, '_')
                        dirs{end + 1} = all_items(i).name; %#ok<AGROW>
                    end
                end
            end
        end
    end
end

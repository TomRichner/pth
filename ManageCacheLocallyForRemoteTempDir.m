classdef ManageCacheLocallyForRemoteTempDir < handle
    %MANAGECACHELOCALLYFORREMOTTEMPDIR Manager for CacheLocallyForRemote temp directories
    %   Provides bulk operations on a write-cache temp directory:
    %   - Stale check (verify active JSON matches disk)
    %   - Rebuild active JSON from disk
    %   - Push all local dirs to remote (after checksum verification)
    %   - Push individual dirs or files to remote
    %   - Clear local cache (after checksum verification)
    %   - List cached entries
    %
    %   Verifies that the temp directory is a CacheLocallyForRemote directory
    %   (not CacheToLocal) by checking the cache_type in cache_active.json
    %   and ensuring no cache_download_log.json exists.
    %
    %   Minimum MATLAB version: R2023a

    properties
        local_temp_dir      % Root temp directory
        active_json_path    % Path to cache_active.json
        log_json_path       % Path to cache_upload_log.json
        rclone_path         % Path to rclone.exe
    end

    methods
        function obj = ManageCacheLocallyForRemoteTempDir(local_temp_dir)
            %MANAGECACHELOCALLYFORREMOTTEMPDIR Construct a write-cache manager

            if ~exist(local_temp_dir, 'dir')
                error('ManageCacheLocallyForRemoteTempDir:DirNotFound', ...
                    'Temp directory does not exist: %s', local_temp_dir);
            end

            obj.local_temp_dir = local_temp_dir;
            obj.active_json_path = fullfile(local_temp_dir, 'cache_active.json');
            obj.log_json_path = fullfile(local_temp_dir, 'cache_upload_log.json');

            % Load rclone path
            obj.rclone_path = CacheBase.loadEnv();

            % Check for cross-contamination
            download_log_path = fullfile(local_temp_dir, 'cache_download_log.json');
            if exist(download_log_path, 'file')
                error('ManageCacheLocallyForRemoteTempDir:CrossContamination', ...
                    ['Found cache_download_log.json in this directory.\n' ...
                     'This directory appears to be a CacheToLocal temp dir.\n' ...
                     'CacheToLocal and CacheLocallyForRemote must use separate directories.\n' ...
                     'Directory: %s'], local_temp_dir);
            end

            % Verify cache_type if active JSON exists
            if exist(obj.active_json_path, 'file')
                data = jsondecode(fileread(obj.active_json_path));
                if isfield(data, 'cache_type') && ~strcmp(data.cache_type, 'CacheLocallyForRemote')
                    error('ManageCacheLocallyForRemoteTempDir:WrongCacheType', ...
                        ['cache_active.json has cache_type = "%s".\n' ...
                         'Expected "CacheLocallyForRemote".\n' ...
                         'Directory: %s'], data.cache_type, local_temp_dir);
                end
            end
        end

        function checkStale(obj)
            %CHECKSTALE Verify active JSON matches what's on disk

            if ~exist(obj.active_json_path, 'file')
                disk_dirs = obj.findDirHashDirs();
                if ~isempty(disk_dirs)
                    error('ManageCacheLocallyForRemoteTempDir:Stale', ...
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
                error('ManageCacheLocallyForRemoteTempDir:Stale', ...
                    'Active JSON is stale. Issues found:\n%s\nRun rebuildActiveJson() to fix.', ...
                    strjoin(issues, '\n'));
            end

            fprintf('Cache is consistent. %d entries verified.\n', numel(entry_names));
        end

        function rebuildActiveJson(obj)
            %REBUILDACTIVEJSON Scan disk and rebuild cache_active.json

            disk_dirs = obj.findDirHashDirs();

            data = struct();
            data.cache_type = 'CacheLocallyForRemote';
            data.entries = struct();

            for i = 1:numel(disk_dirs)
                dir_name = disk_dirs{i};
                dir_path = fullfile(obj.local_temp_dir, dir_name);
                txt_path = fullfile(obj.local_temp_dir, [dir_name, '.txt']);

                entry = struct();

                if exist(txt_path, 'file')
                    content = fileread(txt_path);
                    remote_match = regexp(content, 'Remote directory: (.+)', 'tokens');
                    if ~isempty(remote_match)
                        entry.remote_dir = strtrim(remote_match{1}{1});
                    else
                        entry.remote_dir = 'unknown';
                    end
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
                    warning('ManageCacheLocallyForRemoteTempDir:NoTxtFile', ...
                        'No .txt breadcrumb found for: %s', dir_name);
                end

                all_items = dir(dir_path);
                files = all_items(~[all_items.isdir]);
                entry.files = {files.name};
                entry.created_at = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));

                data.entries.(dir_name) = entry;
            end

            json_str = jsonencode(data, PrettyPrint=true);
            fid = fopen(obj.active_json_path, 'w', 'n', 'UTF-8');
            cleanup = onCleanup(@() fclose(fid));
            fwrite(fid, json_str, 'char');

            fprintf('Rebuilt cache_active.json with %d entries.\n', numel(disk_dirs));
        end

        function pushAllLocalToRemote(obj)
            %PUSHALLLOCALTOREMOTE Push all local dirs to remote after verifying ALL checksums
            %   First verifies every entry's checksum. If ALL pass, pushes all.
            %   If ANY fail, errors without pushing anything.

            if ~exist(obj.active_json_path, 'file')
                fprintf('No cache_active.json found. Nothing to push.\n');
                return;
            end

            data = jsondecode(fileread(obj.active_json_path));
            if ~isfield(data, 'entries') || isempty(fieldnames(data.entries))
                fprintf('No entries to push.\n');
                return;
            end

            entry_names = fieldnames(data.entries);
            mismatches = {};

            % Phase 1: Verify ALL checksums
            fprintf('Phase 1: Verifying checksums for %d entries...\n', numel(entry_names));
            for i = 1:numel(entry_names)
                dir_name = entry_names{i};
                entry = data.entries.(dir_name);
                dir_path = fullfile(obj.local_temp_dir, dir_name);
                remote_dir = entry.remote_dir;

                if ~exist(dir_path, 'dir')
                    mismatches{end + 1} = sprintf('  %s: local directory not found', dir_name); %#ok<AGROW>
                    continue;
                end

                % Use rclone check for verification
                cmd = sprintf('"%s" check "%s" "%s" --one-way', ...
                    obj.rclone_path, dir_path, remote_dir);
                [status, result] = system(cmd);

                if status ~= 0
                    % Check if it's simply that remote doesn't have files yet (not pushed)
                    % In that case, files are new — that's okay for pushing
                    if contains(result, 'not in')
                        fprintf('  %s: new files to push (not yet on remote)\n', dir_name);
                    else
                        mismatches{end + 1} = sprintf('  %s: checksum mismatch\n    %s', dir_name, strtrim(result)); %#ok<AGROW>
                    end
                else
                    fprintf('  %s: checksums verified\n', dir_name);
                end
            end

            if ~isempty(mismatches)
                error('ManageCacheLocallyForRemoteTempDir:ChecksumFailed', ...
                    ['Cannot push — checksum verification failed for:\n%s\n' ...
                     'Resolve these issues before pushing.'], ...
                    strjoin(mismatches, '\n'));
            end

            % Phase 2: Push all entries
            fprintf('\nPhase 2: Pushing %d entries to remote...\n', numel(entry_names));
            for i = 1:numel(entry_names)
                dir_name = entry_names{i};
                entry = data.entries.(dir_name);
                obj.pushDirLocalToRemote(dir_name);
            end

            fprintf('All %d entries pushed successfully.\n', numel(entry_names));
        end

        function pushDirLocalToRemote(obj, dirname_hash)
            %PUSHDIRLOCALTOREMOTE Push a specific dirname_hash/ directory to remote

            if ~exist(obj.active_json_path, 'file')
                error('ManageCacheLocallyForRemoteTempDir:NoActiveJson', ...
                    'No cache_active.json found.');
            end

            data = jsondecode(fileread(obj.active_json_path));
            if ~isfield(data.entries, dirname_hash)
                error('ManageCacheLocallyForRemoteTempDir:EntryNotFound', ...
                    'Entry "%s" not found in cache_active.json.', dirname_hash);
            end

            entry = data.entries.(dirname_hash);
            dir_path = fullfile(obj.local_temp_dir, dirname_hash);
            remote_dir = entry.remote_dir;

            if ~exist(dir_path, 'dir')
                error('ManageCacheLocallyForRemoteTempDir:DirNotFound', ...
                    'Local directory not found: %s', dir_path);
            end

            fprintf('Pushing %s to %s...\n', dirname_hash, remote_dir);

            cmd = sprintf('"%s" copy "%s" "%s" --immutable', ...
                obj.rclone_path, dir_path, remote_dir);
            [status, result] = system(cmd);

            if status ~= 0
                error('ManageCacheLocallyForRemoteTempDir:PushFailed', ...
                    'rclone copy failed for %s:\n%s', dirname_hash, strtrim(result));
            end

            % Log each file that was pushed
            all_items = dir(dir_path);
            files = all_items(~[all_items.isdir]);
            for i = 1:numel(files)
                remote_file_path = fullfile(remote_dir, files(i).name);
                obj.appendToUploadLog(dirname_hash, files(i).name, remote_file_path, files(i).bytes);
            end

            fprintf('Pushed %s (%d files)\n', dirname_hash, numel(files));
        end

        function pushFileLocalToRemote(obj, dirname_hash, filename)
            %PUSHFILELOCALTOREMOTE Push a single file from a dirname_hash/ to remote

            if ~exist(obj.active_json_path, 'file')
                error('ManageCacheLocallyForRemoteTempDir:NoActiveJson', ...
                    'No cache_active.json found.');
            end

            data = jsondecode(fileread(obj.active_json_path));
            if ~isfield(data.entries, dirname_hash)
                error('ManageCacheLocallyForRemoteTempDir:EntryNotFound', ...
                    'Entry "%s" not found in cache_active.json.', dirname_hash);
            end

            entry = data.entries.(dirname_hash);
            file_path = fullfile(obj.local_temp_dir, dirname_hash, filename);
            remote_dir = entry.remote_dir;

            if ~exist(file_path, 'file')
                error('ManageCacheLocallyForRemoteTempDir:FileNotFound', ...
                    'Local file not found: %s', file_path);
            end

            fprintf('Pushing %s/%s to %s...\n', dirname_hash, filename, remote_dir);

            cmd = sprintf('"%s" copy "%s" "%s" --immutable', ...
                obj.rclone_path, file_path, remote_dir);
            [status, result] = system(cmd);

            if status ~= 0
                error('ManageCacheLocallyForRemoteTempDir:PushFailed', ...
                    'rclone copy failed for %s/%s:\n%s', dirname_hash, filename, strtrim(result));
            end

            file_info = dir(file_path);
            remote_file_path = fullfile(remote_dir, filename);
            obj.appendToUploadLog(dirname_hash, filename, remote_file_path, file_info.bytes);

            fprintf('Pushed %s/%s\n', dirname_hash, filename);
        end

        function clearLocalCache(obj)
            %CLEARLOCALCACHE Delete all local dirs after verifying ALL match remote
            %   Checks every entry's checksum. If ALL match, deletes all.
            %   If ANY mismatch, errors with details.

            if ~exist(obj.active_json_path, 'file')
                fprintf('No cache_active.json found. Nothing to clear.\n');
                return;
            end

            data = jsondecode(fileread(obj.active_json_path));
            if ~isfield(data, 'entries') || isempty(fieldnames(data.entries))
                fprintf('No entries to clear.\n');
                return;
            end

            entry_names = fieldnames(data.entries);
            mismatches = {};

            % Verify ALL checksums first
            fprintf('Verifying checksums before clearing...\n');
            for i = 1:numel(entry_names)
                dir_name = entry_names{i};
                entry = data.entries.(dir_name);
                dir_path = fullfile(obj.local_temp_dir, dir_name);
                remote_dir = entry.remote_dir;

                if ~exist(dir_path, 'dir')
                    continue; % Already gone
                end

                cmd = sprintf('"%s" check "%s" "%s" --one-way', ...
                    obj.rclone_path, dir_path, remote_dir);
                [status, result] = system(cmd);

                if status ~= 0
                    mismatches{end + 1} = sprintf('  %s → %s\n    %s', ...
                        dir_name, remote_dir, strtrim(result)); %#ok<AGROW>
                end
            end

            if ~isempty(mismatches)
                error('ManageCacheLocallyForRemoteTempDir:ChecksumMismatch', ...
                    ['Cannot clear — checksum mismatch for:\n%s\n' ...
                     'Push to remote first with pushAllLocalToRemote().'], ...
                    strjoin(mismatches, '\n'));
            end

            % All match — safe to delete
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
            %LISTCACHE Print a table of all cached entries with sync status

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

            all_items = dir(obj.local_temp_dir);
            dirs = {};
            for i = 1:numel(all_items)
                if all_items(i).isdir && ~startsWith(all_items(i).name, '.')
                    if contains(all_items(i).name, '_')
                        dirs{end + 1} = all_items(i).name; %#ok<AGROW>
                    end
                end
            end
        end

        function appendToUploadLog(obj, dirname_hash, filename, remote_dest, file_size)
            %APPENDTOUPLOADLOG Append an entry to cache_upload_log.json

            data = struct();
            if exist(obj.log_json_path, 'file')
                data = jsondecode(fileread(obj.log_json_path));
            end

            if ~isfield(data, 'uploads')
                data.uploads = {};
            end

            % Get hash info from active JSON
            active_data = jsondecode(fileread(obj.active_json_path));
            if isfield(active_data.entries, dirname_hash)
                entry_data = active_data.entries.(dirname_hash);
                short_hash = entry_data.short_hash;
                full_hash = entry_data.full_hash;
            else
                short_hash = 'unknown';
                full_hash = 'unknown';
            end

            entry = struct();
            entry.local_dir_name = dirname_hash;
            entry.local_file = filename;
            entry.remote_destination = remote_dest;
            entry.short_hash = short_hash;
            entry.full_hash = full_hash;
            entry.uploaded_at = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
            entry.file_size_bytes = file_size;

            if iscell(data.uploads)
                data.uploads{end + 1} = entry;
            else
                existing = num2cell(data.uploads);
                existing{end + 1} = entry;
                data.uploads = existing;
            end

            json_str = jsonencode(data, PrettyPrint=true);
            fid = fopen(obj.log_json_path, 'w', 'n', 'UTF-8');
            cleanup = onCleanup(@() fclose(fid));
            fwrite(fid, json_str, 'char');
        end
    end
end

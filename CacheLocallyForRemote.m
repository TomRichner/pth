classdef CacheLocallyForRemote < CacheBase
    %CACHELOCALLYFORREMOTE Cache analysis files locally for later writing to remote
    %   Write files locally for speed during analysis, then push to a remote
    %   destination when ready using rclone copy --immutable.
    %
    %   The local copy should only be deleted after verifying it matches the
    %   remote via checksum comparison. If they don't match, an error is thrown.
    %
    %   Usage:
    %     dest = pth('//server/results/analysis.mat');
    %     clf = CacheLocallyForRemote(dest, 'C:\Users\m218089\Desktop\local_data\write_cache');
    %     local_path = clf.get();       % returns local path for writing
    %     save(local_path, 'results');   % write your data locally
    %     clf.pushToRemote();            % push to remote with --immutable
    %     clf.deleteLocal();             % delete local after checksum verification
    %
    %   Minimum MATLAB version: R2023a

    methods
        function obj = CacheLocallyForRemote(remote_path_obj, local_temp_dir)
            %CACHELOCALLYFORREMOTE Construct a write-cache object
            %   remote_path_obj: pth object pointing to remote DESTINATION
            %   local_temp_dir: local directory for temporary writes

            obj@CacheBase(remote_path_obj, local_temp_dir);

            % Register in active JSON on construction
            obj.updateActiveJson('add', 'CacheLocallyForRemote');
        end

        function local_path = get(obj)
            %GET Returns local file path for writing
            %   Does NOT copy anything. The user writes to this path.
            %   The directory is already created by the constructor.

            local_path = obj.local_file_path;
        end

        function local_path = getLocal(obj)
            %GETLOCAL Alias for get() — returns local temp file path

            local_path = obj.local_file_path;
        end

        function remote_full = getRemote(obj)
            %GETREMOTE Returns the remote destination path

            remote_full = obj.remote_path.get();
        end

        function pushToRemote(obj)
            %PUSHTOREMOTE Copy local file to remote destination using rclone --immutable
            %   Verifies local file exists before pushing.
            %   Appends to cache_upload_log.json on success.

            % Verify local file exists
            if ~exist(obj.local_file_path, 'file')
                error('CacheLocallyForRemote:LocalNotFound', ...
                    'Local file does not exist: %s\nWrite your data to this path first.', ...
                    obj.local_file_path);
            end

            % Get file info for logging
            local_info = dir(obj.local_file_path);
            file_size = local_info.bytes;
            [~, filename, ext] = fileparts(obj.local_file_path);
            local_filename = [filename, ext];

            % Get remote destination directory
            remote_full = obj.remote_path.get();
            [remote_dir, ~, ~] = fileparts(remote_full);

            % Ensure remote directory exists (rclone handles this)
            fprintf('Pushing local file to remote...\n');
            fprintf('  Local:  %s\n', obj.local_file_path);
            fprintf('  Remote: %s\n', remote_full);
            fprintf('  Size:   %.2f MB\n', file_size / 1024 / 1024);

            tic;
            obj.rcloneCopy(obj.local_file_path, remote_dir);
            elapsed = toc;

            fprintf('Push completed in %.1f seconds', elapsed);
            if elapsed > 0
                fprintf(' (%.2f MB/s)', file_size / 1024 / 1024 / elapsed);
            end
            fprintf('\n');

            % Append to upload log
            obj.appendUploadLog(local_filename, remote_full, file_size);

            % Update active JSON to reflect current files
            obj.updateActiveJson('add', 'CacheLocallyForRemote');

            % Update dirname_hash.txt
            obj.updateDirHashTxt();
        end

        function match = checkSumCompareLocalAndRemote(obj)
            %CHECKSUMCOMPARELOCALANDREMOTE Compare local and remote files by checksum
            %   Uses rclone check to verify file integrity.
            %   Returns true if files are identical, false otherwise.

            remote_full = obj.remote_path.get();
            [remote_dir, ~, ~] = fileparts(remote_full);

            if ~exist(obj.local_file_path, 'file')
                error('CacheLocallyForRemote:LocalNotFound', ...
                    'Local file does not exist: %s', obj.local_file_path);
            end

            % rclone check compares source and dest
            cmd = sprintf('"%s" check "%s" "%s" --one-way', ...
                obj.rclone_path, obj.local_dir_path, remote_dir);
            [status, result] = system(cmd);

            match = (status == 0);
            if ~match
                fprintf('Checksum comparison result: MISMATCH\n');
                fprintf('  rclone output: %s\n', strtrim(result));
            else
                fprintf('Checksum comparison result: MATCH\n');
            end
        end

        function match = quickCompareLocalAndRemote(obj)
            %QUICKCOMPARELOCALANDREMOTE Compare by file size and modification time
            %   Uses a 2-second leeway on modification time.
            %   Fast but less reliable than checksum comparison.

            remote_full = obj.remote_path.get();

            if ~exist(obj.local_file_path, 'file')
                match = false;
                return;
            end
            if ~exist(remote_full, 'file')
                match = false;
                return;
            end

            local_info = dir(obj.local_file_path);
            remote_info = dir(remote_full);

            % Compare sizes
            if local_info.bytes ~= remote_info.bytes
                match = false;
                fprintf('Quick compare: size mismatch (local=%d, remote=%d)\n', ...
                    local_info.bytes, remote_info.bytes);
                return;
            end

            % Compare modification times with 2-second leeway
            time_diff = abs(local_info.datenum - remote_info.datenum) * 86400; % seconds
            if time_diff > 2
                match = false;
                fprintf('Quick compare: time mismatch (%.1f seconds difference)\n', time_diff);
                return;
            end

            match = true;
            fprintf('Quick compare: MATCH (size=%d bytes, time diff=%.1fs)\n', ...
                local_info.bytes, time_diff);
        end

        function deleteLocal(obj)
            %DELETELOCAL Delete local file after verifying checksum match with remote
            %   Runs checkSumCompareLocalAndRemote() first.
            %   If match: deletes local file and updates active JSON.
            %   If no match: errors with file details.

            if ~exist(obj.local_file_path, 'file')
                fprintf('No local file to delete: %s\n', obj.local_file_path);
                return;
            end

            remote_full = obj.remote_path.get();

            % Check if remote exists
            if ~exist(remote_full, 'file')
                local_info = dir(obj.local_file_path);
                error('CacheLocallyForRemote:RemoteNotFound', ...
                    ['Cannot delete local file — remote file does not exist.\n' ...
                     '  Local:  %s (%d bytes)\n' ...
                     '  Remote: %s (not found)\n' ...
                     'Push to remote first with .pushToRemote(), then retry.'], ...
                    obj.local_file_path, local_info.bytes, remote_full);
            end

            % Verify checksum match
            match = obj.checkSumCompareLocalAndRemote();

            if ~match
                local_info = dir(obj.local_file_path);
                remote_info = dir(remote_full);

                % Count files in local and remote dirs
                [remote_dir, ~, ~] = fileparts(remote_full);
                local_files = obj.listLocalFiles();
                remote_files_list = dir(remote_dir);
                remote_files_list = remote_files_list(~[remote_files_list.isdir]);

                error('CacheLocallyForRemote:ChecksumMismatch', ...
                    ['Cannot delete local file — checksum mismatch with remote.\n' ...
                     '  Local:  %s (%d bytes)\n' ...
                     '  Remote: %s (%d bytes)\n' ...
                     '  Local files in dir:  %d (total %.2f MB)\n' ...
                     '  Remote files in dir: %d (total %.2f MB)\n' ...
                     'Push to remote first with .pushToRemote(), then retry.'], ...
                    obj.local_file_path, local_info.bytes, ...
                    remote_full, remote_info.bytes, ...
                    numel(local_files), sum([local_files.bytes]) / 1024 / 1024, ...
                    numel(remote_files_list), sum([remote_files_list.bytes]) / 1024 / 1024);
            end

            % Checksums match — safe to delete
            fprintf('Checksum verified. Deleting local file: %s\n', obj.local_file_path);
            delete(obj.local_file_path);

            % Update active JSON
            obj.updateActiveJson('remove', 'CacheLocallyForRemote');

            % Update dirname_hash.txt
            obj.updateDirHashTxt();
        end

        function exists = localExists(obj)
            %LOCALEXISTS Check if local file exists on disk

            exists = exist(obj.local_file_path, 'file') == 2;
        end

        function exists = remoteExists(obj)
            %REMOTEEXISTS Check if remote file exists

            remote_full = obj.remote_path.get();
            exists = exist(remote_full, 'file') == 2;
        end
    end
end

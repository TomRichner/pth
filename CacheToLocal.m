classdef CacheToLocal < CacheBase
    %CACHETOLOCAL Cache a remote file to local storage for fast read access
    %   Copies a file from a remote/network location to a local temp directory
    %   using rclone copy --immutable. The remote is always treated as read-only.
    %   The local copy is always safe to delete.
    %
    %   If the file is already cached locally, get() returns immediately.
    %   Files from the same remote directory share a local dirname_hash/ folder.
    %
    %   Usage:
    %     remote = pth('//server/data/recording.mat');
    %     ct = CacheToLocal(remote, 'C:\Users\m218089\Desktop\local_data\read_cache');
    %     local_path = ct.get();   % copies on first call, returns cached on subsequent
    %     data = load(local_path);
    %
    %   Minimum MATLAB version: R2023a

    methods
        function obj = CacheToLocal(remote_path_obj, local_temp_dir)
            %CACHETOLOCAL Construct a read-cache object
            %   remote_path_obj: pth object pointing to a remote file
            %   local_temp_dir: local directory for cached files

            obj@CacheBase(remote_path_obj, local_temp_dir);
        end

        function local_path = get(obj)
            %GET Returns path to local cached file, copying from remote if needed
            %   On first call: copies remote file to local cache using rclone.
            %   On subsequent calls: returns cached path immediately.
            %   Updates cache_active.json and cache_download_log.json.

            % If already cached, return immediately
            if exist(obj.local_file_path, 'file')
                fprintf('Using cached local file: %s\n', obj.local_file_path);
                local_path = obj.local_file_path;
                return;
            end

            % Verify remote file exists
            remote_full = obj.remote_path.get();
            if ~exist(remote_full, 'file')
                error('CacheToLocal:RemoteNotFound', ...
                    'Remote file does not exist: %s', remote_full);
            end

            % Get remote file info for logging
            remote_info = dir(remote_full);
            file_size = remote_info.bytes;
            [~, filename, ext] = fileparts(remote_full);
            remote_filename = [filename, ext];

            % Copy using rclone
            [remote_dir, ~, ~] = fileparts(remote_full);
            fprintf('Copying file from remote to local cache...\n');
            fprintf('  Remote: %s\n', remote_full);
            fprintf('  Local:  %s\n', obj.local_file_path);
            fprintf('  Size:   %.2f MB\n', file_size / 1024 / 1024);

            tic;
            % rclone copy copies the file from remote_dir to local_dir
            % We need to copy just this specific file, so we use the file path
            % and copy into the local directory
            obj.rcloneCopy(remote_full, obj.local_dir_path);
            elapsed = toc;

            % Verify the file was actually copied
            if ~exist(obj.local_file_path, 'file')
                error('CacheToLocal:CopyFailed', ...
                    'rclone copy completed but file not found at: %s', obj.local_file_path);
            end

            fprintf('Copy completed in %.1f seconds', elapsed);
            if elapsed > 0
                fprintf(' (%.2f MB/s)', file_size / 1024 / 1024 / elapsed);
            end
            fprintf('\n');

            % Update active JSON
            obj.updateActiveJson('add', 'CacheToLocal');

            % Append to download log
            obj.appendDownloadLog(remote_filename, file_size);

            % Update dirname_hash.txt
            obj.updateDirHashTxt();

            local_path = obj.local_file_path;
        end

        function deleteLocal(obj)
            %DELETELOCAL Delete the local cached file
            %   Removes the file from local cache and updates the active JSON
            %   and dirname_hash.txt. Does NOT touch the remote file.

            if exist(obj.local_file_path, 'file')
                fprintf('Deleting local cache file: %s\n', obj.local_file_path);
                delete(obj.local_file_path);

                % Update active JSON (remove file from entry)
                obj.updateActiveJson('remove', 'CacheToLocal');

                % Update dirname_hash.txt
                obj.updateDirHashTxt();
            else
                fprintf('No local cache file to delete: %s\n', obj.local_file_path);
            end
        end

        function exists = localExists(obj)
            %LOCALEXISTS Check if local cached file exists on disk

            exists = exist(obj.local_file_path, 'file') == 2;
        end

        function remote_full = getRemote(obj)
            %GETREMOTE Return the remote file path string

            remote_full = obj.remote_path.get();
        end
    end

    % Public wrappers for testing protected methods
    methods
        function data = readJsonPublic(obj, filepath)
            %READJSONPUBLIC Public wrapper for readJson (for testing)
            data = obj.readJson(filepath);
        end

        function writeJsonPublic(obj, filepath, data)
            %WRITEJSONPUBLIC Public wrapper for writeJson (for testing)
            obj.writeJson(filepath, data);
        end
    end
end

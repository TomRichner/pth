classdef WriteCachedPath < handle
    %WRITECACHEDPATH Manages local writing with remote backup for analysis files
    %   This class is for files that need to be written frequently during
    %   analysis (fast local writes) but should ultimately be copied to a
    %   remote location for permanent storage. The object "remembers" the
    %   remote path so you can copy to remote at any time.
    
    properties
        remote_path         % pth object pointing to remote destination
        local_temp_dir      % Local directory for temporary writes
        session_id          % Session ID to append to filename for uniqueness
        local_file_path     % Full path to local temp file (computed)
    end
    
    methods
        function obj = WriteCachedPath(remote_path_obj, local_temp_dir, session_id)
            %WRITECACHEDPATH Construct a write-cached path wrapper
            %   remote_path_obj: pth object pointing to remote destination
            %   local_temp_dir: Local directory path (string) for temp writes
            %   session_id: Session ID to append to filename
            
            if ~isa(remote_path_obj, 'pth')
                error('remote_path_obj must be a pth object');
            end
            
            obj.remote_path = remote_path_obj;
            obj.local_temp_dir = local_temp_dir;
            obj.session_id = session_id;
            
            % Ensure local temp directory exists
            if ~exist(obj.local_temp_dir, 'dir')
                mkdir(obj.local_temp_dir);
                fprintf('Created local temp directory: %s\n', obj.local_temp_dir);
            end
            
            % Compute local file path
            obj.local_file_path = obj.compute_local_path();
        end
        
        function local_path = compute_local_path(obj)
            %COMPUTE_LOCAL_PATH Generate the local temp file path
            
            remote_full = obj.remote_path.get();
            [~, filename, ext] = fileparts(remote_full);
            
            % Append session_id to filename to avoid conflicts
            local_filename = sprintf('%s_%s_temp%s', filename, obj.session_id, ext);
            local_path = fullfile(obj.local_temp_dir, local_filename);
        end
        
        function local_path = get(obj)
            %GET Returns path to local temp file for writing
            %   Use this path for frequent writes during analysis.
            %   The file will be written locally for speed.
            
            local_path = obj.local_file_path;
        end
        
        function local_path = get_local(obj)
            %GET_LOCAL Alias for get() - returns local temp file path
            %   Use this path for writing files locally during analysis.
            
            local_path = obj.local_file_path;
        end
        
        function remote_full = get_remote(obj)
            %GET_REMOTE Returns the remote file path
            %   Use this if you need to write directly to remote.
            
            remote_full = obj.remote_path.get();
        end
        
        function copy_local_to_remote(obj)
            %COPY_LOCAL_TO_REMOTE Copy the local file to remote location
            %   Call this at the end of analysis to backup to permanent storage.
            %   The object remembers the remote path, so you can call this
            %   anytime, even after reloading the object.
            
            % Check if local file exists
            if ~exist(obj.local_file_path, 'file')
                warning('Local file does not exist: %s\nNothing to copy to remote.', obj.local_file_path);
                return;
            end
            
            % Get remote path and ensure directory exists
            remote_full = obj.remote_path.get();
            remote_dir = fileparts(remote_full);
            if ~exist(remote_dir, 'dir')
                error(['remote directory does not exist, cannot copy local directory, ' obj.local_file_path ', to remote directory, ' remote_dir])
            end
            
            % Get file size for progress reporting
            local_info = dir(obj.local_file_path);
            file_size = local_info.bytes;
            
            % Copy file from local to remote
            fprintf('Copying file from local to remote...\n');
            fprintf('  Local:  %s\n', obj.local_file_path);
            fprintf('  Remote: %s\n', remote_full);
            fprintf('  Size:   %.2f MB\n', file_size / 1024 / 1024);
            
            tic;
            copyfile(obj.local_file_path, remote_full);
            elapsed = toc;
            
            fprintf('Copy completed in %.1f seconds (%.2f MB/s)\n', ...
                elapsed, file_size / 1024 / 1024 / elapsed);
        end
        
        function clearLocal(obj)
            %CLEARLOCAL Delete the local temp file
            %   Use this to free up local disk space after copying to remote.
            
            if exist(obj.local_file_path, 'file')
                fprintf('Deleting local temp file: %s\n', obj.local_file_path);
                delete(obj.local_file_path);
            else
                fprintf('No local temp file to delete.\n');
            end
        end
        
        function sync_from_remote(obj)
            %SYNC_FROM_REMOTE Copy the remote file to local (if it exists)
            %   Use this if you need to load an existing remote file locally
            %   for continued analysis.
            
            remote_full = obj.remote_path.get();
            
            % Check if remote file exists
            if ~exist(remote_full, 'file')
                warning('Remote file does not exist: %s\nNothing to sync.', remote_full);
                return;
            end
            
            % Get file size
            remote_info = dir(remote_full);
            file_size = remote_info.bytes;
            
            % Copy from remote to local
            fprintf('Syncing file from remote to local...\n');
            fprintf('  Remote: %s\n', remote_full);
            fprintf('  Local:  %s\n', obj.local_file_path);
            fprintf('  Size:   %.2f MB\n', file_size / 1024 / 1024);
            
            tic;
            copyfile(remote_full, obj.local_file_path);
            elapsed = toc;
            
            fprintf('Sync completed in %.1f seconds (%.2f MB/s)\n', ...
                elapsed, file_size / 1024 / 1024 / elapsed);
        end
        
        function exists_local = check_local_exists(obj)
            %CHECK_LOCAL_EXISTS Check if local temp file exists
            
            exists_local = exist(obj.local_file_path, 'file') == 2;
        end
        
        function exists_remote = check_remote_exists(obj)
            %CHECK_REMOTE_EXISTS Check if remote file exists
            
            remote_full = obj.remote_path.get();
            exists_remote = exist(remote_full, 'file') == 2;
        end
    end
end

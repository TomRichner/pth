classdef CachedPath < handle
    %CACHEDPATH Manages local caching of remote files for faster access
    %   This class wraps a remote pth object and automatically copies large
    %   files to a local temp directory for faster loading. It checks if
    %   the file already exists locally with the same size before copying.
    
    properties
        remote_path         % pth object pointing to remote file
        local_temp_dir      % Local directory for caching (string)
        session_id          % Session ID to append to filename for uniqueness
        local_file_path     % Full path to local cached file (computed)
    end
    
    methods
        function obj = CachedPath(remote_path_obj, local_temp_dir, session_id)
            %CACHEDPATH Construct a cached path wrapper
            %   remote_path_obj: pth object pointing to remote file
            %   local_temp_dir: Local directory path (string) for caching
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
            %COMPUTE_LOCAL_PATH Generate the local cached file path
            
            remote_full = obj.remote_path.get();
            [~, filename, ext] = fileparts(remote_full);
            
            % Append session_id to filename to avoid conflicts
            local_filename = sprintf('%s_%s%s', filename, obj.session_id, ext);
            local_path = fullfile(obj.local_temp_dir, local_filename);
        end
        
        function local_path = get(obj)
            %GET Returns path to local cached file, copying if necessary
            %   This method checks if the file exists locally with matching
            %   size. If not, it copies from remote after checking disk space.
            
            remote_full = obj.remote_path.get();
            
            % Check if remote file exists
            if ~exist(remote_full, 'file')
                error('Remote file does not exist: %s', remote_full);
            end
            
            % Get remote file info
            remote_info = dir(remote_full);
            remote_size = remote_info.bytes;
            
            % Check if local file exists
            if exist(obj.local_file_path, 'file')
                % Check if sizes match
                local_info = dir(obj.local_file_path);
                local_size = local_info.bytes;
                
                if local_size == remote_size
                    % File exists and matches, use it
                    fprintf('Using cached local file: %s\n', obj.local_file_path);
                    local_path = obj.local_file_path;
                    return;
                else
                    % Size mismatch, delete old local file
                    fprintf('Local file size mismatch. Remote: %d bytes, Local: %d bytes\n', ...
                        remote_size, local_size);
                    fprintf('Deleting old local cache file...\n');
                    delete(obj.local_file_path);
                end
            end
            
            % Need to copy file - check disk space first
            if ~obj.check_disk_space(remote_size)
                error('Insufficient local disk space to cache file. Need %d bytes.', remote_size);
            end
            
            % Copy file from remote to local
            fprintf('Copying file from remote to local cache...\n');
            fprintf('  Remote: %s\n', remote_full);
            fprintf('  Local:  %s\n', obj.local_file_path);
            fprintf('  Size:   %.2f MB\n', remote_size / 1024 / 1024);
            
            tic;
            copyfile(remote_full, obj.local_file_path);
            elapsed = toc;
            
            fprintf('Copy completed in %.1f seconds (%.2f MB/s)\n', ...
                elapsed, remote_size / 1024 / 1024 / elapsed);
            
            local_path = obj.local_file_path;
        end
        
        function touch(obj)
            %TOUCH Preemptively copy the file to local cache
            %   This method can be called ahead of time to copy the file
            %   to local storage before it's needed.
            
            fprintf('Preemptively caching file...\n');
            obj.get(); % Just call get() to trigger the copy
        end
        
        function clearTemp(obj)
            %CLEARTEMP Delete the local cached file
            
            if exist(obj.local_file_path, 'file')
                fprintf('Deleting local cache file: %s\n', obj.local_file_path);
                delete(obj.local_file_path);
            else
                fprintf('No local cache file to delete.\n');
            end
        end
        
        function has_space = check_disk_space(obj, bytes_needed)
            %CHECK_DISK_SPACE Check if there's enough space on local disk
            %   Returns true if there's enough space, false otherwise.
            %   Adds 10% buffer to the required space.
            
            % Get drive letter from local temp dir
            if ispc
                % Windows
                local_drive = obj.local_temp_dir(1:2); % e.g., 'C:'
                [status, result] = system(sprintf('wmic logicaldisk where "DeviceID=''%s''" get FreeSpace', local_drive));
                
                if status == 0
                    % Parse result
                    lines = strsplit(result, '\n');
                    for i = 1:length(lines)
                        line = strtrim(lines{i});
                        if ~isempty(line) && ~strcmp(line, 'FreeSpace')
                            free_space = str2double(line);
                            break;
                        end
                    end
                else
                    warning('Could not check disk space. Assuming sufficient space.');
                    has_space = true;
                    return;
                end
            else
                % Unix/Mac
                [status, result] = system(sprintf('df -k "%s" | tail -1 | awk ''{print $4}''', obj.local_temp_dir));
                if status == 0
                    free_space = str2double(result) * 1024; % Convert KB to bytes
                else
                    warning('Could not check disk space. Assuming sufficient space.');
                    has_space = true;
                    return;
                end
            end
            
            % Add 10% buffer
            bytes_needed_with_buffer = bytes_needed * 1.1;
            
            has_space = free_space >= bytes_needed_with_buffer;
            
            if ~has_space
                fprintf('Insufficient disk space:\n');
                fprintf('  Available: %.2f GB\n', free_space / 1024 / 1024 / 1024);
                fprintf('  Needed:    %.2f GB (with 10%% buffer)\n', ...
                    bytes_needed_with_buffer / 1024 / 1024 / 1024);
            end
        end
        
        function remote_full = get_remote(obj)
            %GET_REMOTE Returns the remote file path
            %   Useful for accessing the original remote path
            
            remote_full = obj.remote_path.get();
        end
    end
end

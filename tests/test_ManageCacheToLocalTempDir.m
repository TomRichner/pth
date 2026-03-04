classdef test_ManageCacheToLocalTempDir < matlab.unittest.TestCase
    %TEST_MANAGECACHETOLOCALTTEMPDIR Unit tests for ManageCacheToLocalTempDir

    properties
        mock_remote
        mock_local
    end

    methods (TestMethodSetup)
        function createFixtures(testCase)
            test_dir = fileparts(mfilename('fullpath'));
            tmp_dir = fullfile(test_dir, 'tmp');

            if exist(tmp_dir, 'dir')
                rmdir(tmp_dir, 's');
            end

            % Create mock remote with test files
            testCase.mock_remote = fullfile(tmp_dir, 'mock_remote', 'project_A');
            mkdir(testCase.mock_remote);
            writelines("test data 1", fullfile(testCase.mock_remote, 'data.txt'));
            writelines("test data 2", fullfile(testCase.mock_remote, 'results.txt'));

            % Create local temp dir
            testCase.mock_local = fullfile(tmp_dir, 'local_read');
            mkdir(testCase.mock_local);
        end
    end

    methods (TestMethodTeardown)
        function cleanFixtures(testCase)
            test_dir = fileparts(mfilename('fullpath'));
            tmp_dir = fullfile(test_dir, 'tmp');
            if exist(tmp_dir, 'dir')
                rmdir(tmp_dir, 's');
            end
        end
    end

    methods (Test)
        function testConstructor(testCase)
            %TEST: constructor works on valid read-cache directory
            % First cache a file to create the active JSON
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            mgr = ManageCacheToLocalTempDir(testCase.mock_local);
            testCase.verifyNotEmpty(mgr.local_temp_dir);
        end

        function testConstructorErrorsOnMissingDir(testCase)
            %TEST: constructor errors if directory doesn't exist
            testCase.verifyError(...
                @() ManageCacheToLocalTempDir(fullfile(testCase.mock_local, 'nonexistent')), ...
                'ManageCacheToLocalTempDir:DirNotFound');
        end

        function testConstructorErrorsOnWriteCacheDir(testCase)
            %TEST: constructor errors if cache_upload_log.json exists
            % Create a fake upload log to simulate a write-cache dir
            fid = fopen(fullfile(testCase.mock_local, 'cache_upload_log.json'), 'w');
            fprintf(fid, '{}');
            fclose(fid);

            testCase.verifyError(...
                @() ManageCacheToLocalTempDir(testCase.mock_local), ...
                'ManageCacheToLocalTempDir:CrossContamination');

            % Clean up
            delete(fullfile(testCase.mock_local, 'cache_upload_log.json'));
        end

        function testCheckStalePassesForConsistentState(testCase)
            %TEST: checkStale() passes when JSON matches disk
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            mgr = ManageCacheToLocalTempDir(testCase.mock_local);
            mgr.checkStale(); % Should not error
        end

        function testCheckStaleErrorsWhenFileMissing(testCase)
            %TEST: checkStale() errors when JSON says file exists but doesn't
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            % Manually delete the cached file without updating JSON
            delete(ct.local_file_path);

            mgr = ManageCacheToLocalTempDir(testCase.mock_local);
            testCase.verifyError(@() mgr.checkStale(), ...
                'ManageCacheToLocalTempDir:Stale');
        end

        function testCheckStaleErrorsWhenDirNotInJson(testCase)
            %TEST: checkStale() errors when directory exists but not in JSON
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            % Create a rogue dirname_hash directory
            mkdir(fullfile(testCase.mock_local, 'rogue_abc123'));

            mgr = ManageCacheToLocalTempDir(testCase.mock_local);
            testCase.verifyError(@() mgr.checkStale(), ...
                'ManageCacheToLocalTempDir:Stale');

            % Clean up
            rmdir(fullfile(testCase.mock_local, 'rogue_abc123'), 's');
        end

        function testRebuildActiveJson(testCase)
            %TEST: rebuildActiveJson() correctly rebuilds from disk
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            % Delete the active JSON
            delete(fullfile(testCase.mock_local, 'cache_active.json'));

            % Rebuild
            mgr = ManageCacheToLocalTempDir(testCase.mock_local);
            mgr.rebuildActiveJson();

            % Verify it was rebuilt
            testCase.verifyTrue(exist(fullfile(testCase.mock_local, 'cache_active.json'), 'file') == 2);
            data = jsondecode(fileread(fullfile(testCase.mock_local, 'cache_active.json')));
            testCase.verifyEqual(data.cache_type, 'CacheToLocal');
            testCase.verifyTrue(isfield(data.entries, ct.local_dir_name));
        end

        function testClearEntireLocalCache(testCase)
            %TEST: clearEntireLocalCache() deletes all cached dirs and .txt files
            remote1 = pth(fullfile(testCase.mock_remote, 'data.txt'));
            remote2 = pth(fullfile(testCase.mock_remote, 'results.txt'));
            ct1 = CacheToLocal(remote1, testCase.mock_local);
            ct2 = CacheToLocal(remote2, testCase.mock_local);
            ct1.get();
            ct2.get();

            mgr = ManageCacheToLocalTempDir(testCase.mock_local);
            mgr.clearEntireLocalCache();

            % Verify dirs are gone
            testCase.verifyFalse(exist(ct1.local_dir_path, 'dir') == 7);

            % Verify active JSON is empty
            data = jsondecode(fileread(fullfile(testCase.mock_local, 'cache_active.json')));
            testCase.verifyTrue(isempty(fieldnames(data.entries)));
        end

        function testClearErrorsIfUploadLogExists(testCase)
            %TEST: clearEntireLocalCache() errors if upload log present
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            % Create the manager BEFORE the upload log exists
            mgr = ManageCacheToLocalTempDir(testCase.mock_local);

            % Now inject a fake upload log to simulate cross-contamination
            fid = fopen(fullfile(testCase.mock_local, 'cache_upload_log.json'), 'w');
            fprintf(fid, '{}');
            fclose(fid);

            testCase.verifyError(@() mgr.clearEntireLocalCache(), ...
                'ManageCacheToLocalTempDir:CrossContamination');

            % Clean up
            delete(fullfile(testCase.mock_local, 'cache_upload_log.json'));
        end

        function testListCache(testCase)
            %TEST: listCache() runs without error
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            mgr = ManageCacheToLocalTempDir(testCase.mock_local);
            mgr.listCache(); % Should print to console without error
        end

        function testConstructorErrorsOnWrongCacheType(testCase)
            %TEST: constructor errors if cache_type is CacheLocallyForRemote
            % Create a fake active JSON with wrong cache_type
            active_path = fullfile(testCase.mock_local, 'cache_active.json');
            data = struct('cache_type', 'CacheLocallyForRemote', 'entries', struct());
            fid = fopen(active_path, 'w', 'n', 'UTF-8');
            fwrite(fid, jsonencode(data, PrettyPrint=true), 'char');
            fclose(fid);

            testCase.verifyError(...
                @() ManageCacheToLocalTempDir(testCase.mock_local), ...
                'ManageCacheToLocalTempDir:WrongCacheType');

            % Clean up
            delete(active_path);
        end
    end
end

classdef test_ManageCacheLocallyForRemoteTempDir < matlab.unittest.TestCase
    %TEST_MANAGECACHELOCALLYFORREMOTTEMPDIR Unit tests for ManageCacheLocallyForRemoteTempDir

    properties
        mock_remote_dest
        mock_local
    end

    methods (TestMethodSetup)
        function createFixtures(testCase)
            test_dir = fileparts(mfilename('fullpath'));
            tmp_dir = fullfile(test_dir, 'tmp');

            if exist(tmp_dir, 'dir')
                rmdir(tmp_dir, 's');
            end

            % Create mock remote destination
            testCase.mock_remote_dest = fullfile(tmp_dir, 'mock_remote_dest', 'results');
            mkdir(testCase.mock_remote_dest);

            % Create local write temp dir
            testCase.mock_local = fullfile(tmp_dir, 'local_write');
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
            %TEST: constructor works on valid write-cache directory
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            testCase.verifyNotEmpty(mgr.local_temp_dir);
        end

        function testConstructorErrorsOnMissingDir(testCase)
            %TEST: constructor errors if directory doesn't exist
            testCase.verifyError(...
                @() ManageCacheLocallyForRemoteTempDir(fullfile(testCase.mock_local, 'nonexistent')), ...
                'ManageCacheLocallyForRemoteTempDir:DirNotFound');
        end

        function testConstructorErrorsOnReadCacheDir(testCase)
            %TEST: constructor errors if cache_download_log.json exists
            fid = fopen(fullfile(testCase.mock_local, 'cache_download_log.json'), 'w');
            fprintf(fid, '{}');
            fclose(fid);

            testCase.verifyError(...
                @() ManageCacheLocallyForRemoteTempDir(testCase.mock_local), ...
                'ManageCacheLocallyForRemoteTempDir:CrossContamination');

            delete(fullfile(testCase.mock_local, 'cache_download_log.json'));
        end

        function testConstructorErrorsOnWrongCacheType(testCase)
            %TEST: constructor errors if cache_type is CacheToLocal
            active_path = fullfile(testCase.mock_local, 'cache_active.json');
            data = struct('cache_type', 'CacheToLocal', 'entries', struct());
            fid = fopen(active_path, 'w', 'n', 'UTF-8');
            fwrite(fid, jsonencode(data, PrettyPrint=true), 'char');
            fclose(fid);

            testCase.verifyError(...
                @() ManageCacheLocallyForRemoteTempDir(testCase.mock_local), ...
                'ManageCacheLocallyForRemoteTempDir:WrongCacheType');

            delete(active_path);
        end

        function testCheckStalePassesForConsistentState(testCase)
            %TEST: checkStale() passes when JSON matches disk
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            writelines("test data", clf.get());

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            mgr.checkStale(); % Should not error
        end

        function testCheckStaleErrorsWhenFileMissing(testCase)
            %TEST: checkStale() errors when JSON says file exists but doesn't
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            local_path = clf.get();
            writelines("test data", local_path);

            % Push to remote so active JSON gets updated with file in files list
            clf.pushToRemote();

            % Manually delete the local file without updating JSON
            delete(local_path);

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            testCase.verifyError(@() mgr.checkStale(), ...
                'ManageCacheLocallyForRemoteTempDir:Stale');
        end

        function testRebuildActiveJson(testCase)
            %TEST: rebuildActiveJson() correctly rebuilds from disk
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            writelines("test data", clf.get());

            % Delete and rebuild
            delete(fullfile(testCase.mock_local, 'cache_active.json'));
            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            mgr.rebuildActiveJson();

            active_path = fullfile(testCase.mock_local, 'cache_active.json');
            testCase.verifyTrue(exist(active_path, 'file') == 2);
            data = jsondecode(fileread(active_path));
            testCase.verifyEqual(data.cache_type, 'CacheLocallyForRemote');
        end

        function testPushAllLocalToRemote(testCase)
            %TEST: pushAllLocalToRemote() pushes files after checksum verification
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            writelines("push all test data", clf.get());

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            mgr.pushAllLocalToRemote();

            % Verify remote file exists
            testCase.verifyTrue(exist(fullfile(testCase.mock_remote_dest, 'analysis.txt'), 'file') == 2);

            % Verify upload log exists
            testCase.verifyTrue(exist(fullfile(testCase.mock_local, 'cache_upload_log.json'), 'file') == 2);
        end

        function testPushDirLocalToRemote(testCase)
            %TEST: pushDirLocalToRemote() pushes a specific directory
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            writelines("push dir test data", clf.get());

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            mgr.pushDirLocalToRemote(clf.local_dir_name);

            testCase.verifyTrue(exist(fullfile(testCase.mock_remote_dest, 'analysis.txt'), 'file') == 2);
        end

        function testPushFileLocalToRemote(testCase)
            %TEST: pushFileLocalToRemote() pushes a single file
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            writelines("push file test data", clf.get());

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            mgr.pushFileLocalToRemote(clf.local_dir_name, 'analysis.txt');

            testCase.verifyTrue(exist(fullfile(testCase.mock_remote_dest, 'analysis.txt'), 'file') == 2);
        end

        function testClearLocalCacheAfterPush(testCase)
            %TEST: clearLocalCache() succeeds when all checksums match
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            writelines("clear test data", clf.get());
            clf.pushToRemote();

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            mgr.clearLocalCache();

            % Verify local dir is gone
            testCase.verifyFalse(exist(clf.local_dir_path, 'dir') == 7);
        end

        function testClearLocalCacheErrorsOnMismatch(testCase)
            %TEST: clearLocalCache() errors when checksums don't match
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            local_path = clf.get();
            writelines("original data for clear test", local_path);
            clf.pushToRemote();

            % Modify local to create mismatch
            writelines("modified data should block clear", local_path);

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            testCase.verifyError(@() mgr.clearLocalCache(), ...
                'ManageCacheLocallyForRemoteTempDir:ChecksumMismatch');

            % Verify local file is still there
            testCase.verifyTrue(clf.localExists());
        end

        function testListCache(testCase)
            %TEST: listCache() runs without error
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);
            writelines("list test data", clf.get());

            mgr = ManageCacheLocallyForRemoteTempDir(testCase.mock_local);
            mgr.listCache();
        end
    end
end

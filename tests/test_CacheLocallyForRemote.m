classdef test_CacheLocallyForRemote < matlab.unittest.TestCase
    %TEST_CACHELOCALLYFORREMOTE Unit tests for CacheLocallyForRemote class

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

            % Create mock remote destination directory
            testCase.mock_remote_dest = fullfile(tmp_dir, 'mock_remote_dest', 'results');
            mkdir(testCase.mock_remote_dest);

            % Create empty local temp dir for writing
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
        function testGetReturnsLocalPath(testCase)
            %TEST: get() returns local path without copying anything
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            testCase.verifyTrue(ischar(local_path) || isstring(local_path), ...
                'get() should return a path string');
            testCase.verifyTrue(contains(local_path, 'analysis.txt'), ...
                'get() path should contain the original filename');
        end

        function testGetDoesNotCopy(testCase)
            %TEST: get() does not create the file — user must write to it
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            testCase.verifyFalse(exist(local_path, 'file') == 2, ...
                'get() should not create the file');
        end

        function testPushToRemote(testCase)
            %TEST: pushToRemote() copies local file to remote with --immutable
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            % Write a file locally
            local_path = clf.get();
            writelines("analysis results data", local_path);

            % Push to remote
            clf.pushToRemote();

            % Verify remote file exists
            remote_full = fullfile(testCase.mock_remote_dest, 'analysis.txt');
            testCase.verifyTrue(exist(remote_full, 'file') == 2, ...
                'pushToRemote should copy file to remote');

            % Verify content matches
            remote_content = fileread(remote_full);
            local_content = fileread(local_path);
            testCase.verifyEqual(strtrim(remote_content), strtrim(local_content), ...
                'Remote content should match local');
        end

        function testPushToRemoteErrorsIfLocalMissing(testCase)
            %TEST: pushToRemote() errors if local file doesn't exist
            dest = pth(fullfile(testCase.mock_remote_dest, 'missing.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            testCase.verifyError(@() clf.pushToRemote(), ...
                'CacheLocallyForRemote:LocalNotFound');
        end

        function testPushToRemoteIdempotent(testCase)
            %TEST: pushToRemote() skips silently if remote already matches
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("some data", local_path);

            % Push twice — second should not error (--immutable skips matching files)
            clf.pushToRemote();
            clf.pushToRemote(); % Should not error
        end

        function testCheckSumMatchForIdenticalFiles(testCase)
            %TEST: checkSumCompareLocalAndRemote() returns true for identical files
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("checksum test data", local_path);
            clf.pushToRemote();

            match = clf.checkSumCompareLocalAndRemote();
            testCase.verifyTrue(match, ...
                'Checksum should match for identical files');
        end

        function testCheckSumMismatchForDifferentFiles(testCase)
            %TEST: checkSumCompareLocalAndRemote() returns false for different files
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("original data", local_path);
            clf.pushToRemote();

            % Modify local file (the remote stays the same)
            writelines("modified data", local_path);

            match = clf.checkSumCompareLocalAndRemote();
            testCase.verifyFalse(match, ...
                'Checksum should not match after local modification');
        end

        function testQuickCompare(testCase)
            %TEST: quickCompareLocalAndRemote() works with size comparison
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("quick compare test data", local_path);
            clf.pushToRemote();

            % Should match immediately after push
            match = clf.quickCompareLocalAndRemote();
            testCase.verifyTrue(match, ...
                'Quick compare should match after push');
        end

        function testDeleteLocalAfterChecksumMatch(testCase)
            %TEST: deleteLocal() succeeds when checksums match
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("delete test data", local_path);
            clf.pushToRemote();

            clf.deleteLocal(); % Should succeed
            testCase.verifyFalse(clf.localExists(), ...
                'Local file should be deleted after verified deleteLocal');
        end

        function testDeleteLocalErrorsOnMismatch(testCase)
            %TEST: deleteLocal() errors when checksums don't match
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("original data for delete test", local_path);
            clf.pushToRemote();

            % Modify local file to create mismatch
            writelines("modified data should cause error", local_path);

            testCase.verifyError(@() clf.deleteLocal(), ...
                'CacheLocallyForRemote:ChecksumMismatch');
            testCase.verifyTrue(clf.localExists(), ...
                'Local file should NOT be deleted on mismatch');
        end

        function testDeleteLocalErrorsIfRemoteMissing(testCase)
            %TEST: deleteLocal() errors if remote file doesn't exist
            dest = pth(fullfile(testCase.mock_remote_dest, 'no_remote.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("local only data", local_path);

            testCase.verifyError(@() clf.deleteLocal(), ...
                'CacheLocallyForRemote:RemoteNotFound');
        end

        function testUploadLogCreated(testCase)
            %TEST: cache_upload_log.json has correct entries after push
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            local_path = clf.get();
            writelines("upload log test", local_path);
            clf.pushToRemote();

            log_path = fullfile(testCase.mock_local, 'cache_upload_log.json');
            testCase.verifyTrue(exist(log_path, 'file') == 2, ...
                'cache_upload_log.json should be created');

            data = jsondecode(fileread(log_path));
            if iscell(data.uploads)
                entry = data.uploads{1};
            else
                entry = data.uploads(1);
            end
            testCase.verifyEqual(entry.local_file, 'analysis.txt');
            testCase.verifyEqual(entry.short_hash, clf.short_hash);
            testCase.verifyEqual(entry.full_hash, clf.full_hash);
            testCase.verifyTrue(isfield(entry, 'uploaded_at'));
        end

        function testActiveJsonHasCorrectType(testCase)
            %TEST: cache_active.json has cache_type = CacheLocallyForRemote
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            active_path = fullfile(testCase.mock_local, 'cache_active.json');
            data = jsondecode(fileread(active_path));
            testCase.verifyEqual(data.cache_type, 'CacheLocallyForRemote');
        end

        function testLocalExists(testCase)
            %TEST: localExists() returns correct state
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            testCase.verifyFalse(clf.localExists());
            writelines("test", clf.get());
            testCase.verifyTrue(clf.localExists());
        end

        function testRemoteExists(testCase)
            %TEST: remoteExists() returns correct state
            dest = pth(fullfile(testCase.mock_remote_dest, 'analysis.txt'));
            clf = CacheLocallyForRemote(dest, testCase.mock_local);

            testCase.verifyFalse(clf.remoteExists());
            writelines("test", clf.get());
            clf.pushToRemote();
            testCase.verifyTrue(clf.remoteExists());
        end
    end
end

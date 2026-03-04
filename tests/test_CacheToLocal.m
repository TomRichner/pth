classdef test_CacheToLocal < matlab.unittest.TestCase
    %TEST_CACHETOLOCAL Unit tests for CacheToLocal class

    properties
        mock_remote_A
        mock_remote_B
        mock_local
    end

    methods (TestMethodSetup)
        function createFixtures(testCase)
            test_dir = fileparts(mfilename('fullpath'));
            tmp_dir = fullfile(test_dir, 'tmp');

            if exist(tmp_dir, 'dir')
                rmdir(tmp_dir, 's');
            end

            % Create mock remote directories with test files
            testCase.mock_remote_A = fullfile(tmp_dir, 'mock_remote', 'project_A');
            mkdir(testCase.mock_remote_A);
            writelines("test data file 1", fullfile(testCase.mock_remote_A, 'data.txt'));
            writelines("test results file", fullfile(testCase.mock_remote_A, 'results.txt'));

            testCase.mock_remote_B = fullfile(tmp_dir, 'mock_remote', 'project_B');
            mkdir(testCase.mock_remote_B);
            writelines("test data file B", fullfile(testCase.mock_remote_B, 'data.txt'));

            % Create empty local temp dir
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
        function testGetCopiesFile(testCase)
            %TEST: get() copies file from remote to local
            remote = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            local_path = ct.get();
            testCase.verifyTrue(exist(local_path, 'file') == 2, ...
                'get() should copy file to local cache');

            % Verify content matches
            local_content = fileread(local_path);
            remote_content = fileread(fullfile(testCase.mock_remote_A, 'data.txt'));
            testCase.verifyEqual(strtrim(local_content), strtrim(remote_content), ...
                'Cached file content should match remote');
        end

        function testGetSkipsOnSecondCall(testCase)
            %TEST: second get() returns immediately without re-copying
            remote = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            local_path1 = ct.get();
            local_path2 = ct.get();
            testCase.verifyEqual(local_path1, local_path2, ...
                'Second get() should return the same path');
        end

        function testActiveJsonCreated(testCase)
            %TEST: cache_active.json is created after get()
            remote = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            active_path = fullfile(testCase.mock_local, 'cache_active.json');
            testCase.verifyTrue(exist(active_path, 'file') == 2, ...
                'cache_active.json should be created');

            data = jsondecode(fileread(active_path));
            testCase.verifyEqual(data.cache_type, 'CacheToLocal', ...
                'cache_type should be CacheToLocal');
            testCase.verifyTrue(isfield(data.entries, ct.local_dir_name), ...
                'Active JSON should have an entry for this dir');
        end

        function testDownloadLogCreated(testCase)
            %TEST: cache_download_log.json is created with correct entry
            remote = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            log_path = fullfile(testCase.mock_local, 'cache_download_log.json');
            testCase.verifyTrue(exist(log_path, 'file') == 2, ...
                'cache_download_log.json should be created');

            data = jsondecode(fileread(log_path));
            testCase.verifyTrue(isfield(data, 'downloads'), ...
                'Download log should have downloads field');

            if iscell(data.downloads)
                entry = data.downloads{1};
            else
                entry = data.downloads(1);
            end
            testCase.verifyEqual(entry.remote_file, 'data.txt', ...
                'Download log entry should have correct filename');
            testCase.verifyEqual(entry.short_hash, ct.short_hash, ...
                'Download log should contain short hash');
            testCase.verifyEqual(entry.full_hash, ct.full_hash, ...
                'Download log should contain full hash');
            testCase.verifyTrue(isfield(entry, 'downloaded_at'), ...
                'Download log should have timestamp');
        end

        function testDirHashTxtUpdatedAfterGet(testCase)
            %TEST: dirname_hash.txt lists the cached file after get()
            remote = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            txt_path = fullfile(testCase.mock_local, [ct.local_dir_name, '.txt']);
            content = fileread(txt_path);
            testCase.verifyTrue(contains(content, 'data.txt'), ...
                'dirname_hash.txt should list the cached file');
        end

        function testDeleteLocal(testCase)
            %TEST: deleteLocal() removes local file and updates JSON
            remote = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            testCase.verifyTrue(ct.localExists(), 'File should exist before delete');
            ct.deleteLocal();
            testCase.verifyFalse(ct.localExists(), 'File should not exist after delete');
        end

        function testDeleteLocalDoesNotTouchRemote(testCase)
            %TEST: deleteLocal() does NOT delete the remote file
            remote_path_str = fullfile(testCase.mock_remote_A, 'data.txt');
            remote = pth(remote_path_str);
            ct = CacheToLocal(remote, testCase.mock_local);
            ct.get();

            ct.deleteLocal();
            testCase.verifyTrue(exist(remote_path_str, 'file') == 2, ...
                'deleteLocal should not touch the remote file');
        end

        function testSameRemoteDirSharesLocalDir(testCase)
            %TEST: two files from same remote dir share local dirname_hash/ folder
            remote1 = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            remote2 = pth(fullfile(testCase.mock_remote_A, 'results.txt'));

            ct1 = CacheToLocal(remote1, testCase.mock_local);
            ct2 = CacheToLocal(remote2, testCase.mock_local);

            testCase.verifyEqual(ct1.local_dir_name, ct2.local_dir_name, ...
                'Files from same remote dir should share local dirname_hash/');
            testCase.verifyEqual(ct1.local_dir_path, ct2.local_dir_path, ...
                'Files from same remote dir should have same local dir path');
        end

        function testDifferentRemoteDirsGetDifferentLocalDirs(testCase)
            %TEST: files with same name from different dirs get different local dirs
            remote1 = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            remote2 = pth(fullfile(testCase.mock_remote_B, 'data.txt'));

            ct1 = CacheToLocal(remote1, testCase.mock_local);
            ct2 = CacheToLocal(remote2, testCase.mock_local);

            testCase.verifyNotEqual(ct1.local_dir_name, ct2.local_dir_name, ...
                'Files from different remote dirs should have different local dirs');

            % Both should have data.txt as the filename
            [~, name1, ext1] = fileparts(ct1.local_file_path);
            [~, name2, ext2] = fileparts(ct2.local_file_path);
            testCase.verifyEqual([name1 ext1], [name2 ext2], ...
                'Both should preserve the original filename');
        end

        function testErrorOnNonexistentRemote(testCase)
            %TEST: get() errors when remote file doesn't exist
            remote = pth(fullfile(testCase.mock_remote_A, 'nonexistent.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            testCase.verifyError(@() ct.get(), 'CacheToLocal:RemoteNotFound');
        end

        function testLocalExists(testCase)
            %TEST: localExists() returns correct state
            remote = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            testCase.verifyFalse(ct.localExists(), 'Should not exist before get()');
            ct.get();
            testCase.verifyTrue(ct.localExists(), 'Should exist after get()');
        end

        function testGetRemote(testCase)
            %TEST: getRemote() returns the remote path
            remote_path_str = fullfile(testCase.mock_remote_A, 'data.txt');
            remote = pth(remote_path_str);
            ct = CacheToLocal(remote, testCase.mock_local);

            testCase.verifyEqual(ct.getRemote(), remote_path_str, ...
                'getRemote() should return the original remote path');
        end

        function testMultipleDownloadsAppendToLog(testCase)
            %TEST: downloading multiple files appends separate entries to log
            remote1 = pth(fullfile(testCase.mock_remote_A, 'data.txt'));
            remote2 = pth(fullfile(testCase.mock_remote_A, 'results.txt'));

            ct1 = CacheToLocal(remote1, testCase.mock_local);
            ct2 = CacheToLocal(remote2, testCase.mock_local);

            ct1.get();
            ct2.get();

            log_path = fullfile(testCase.mock_local, 'cache_download_log.json');
            data = jsondecode(fileread(log_path));

            if iscell(data.downloads)
                n_entries = numel(data.downloads);
            else
                n_entries = numel(data.downloads);
            end
            testCase.verifyEqual(n_entries, 2, ...
                'Download log should have 2 entries after downloading 2 files');
        end
    end
end

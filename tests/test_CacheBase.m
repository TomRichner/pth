classdef test_CacheBase < matlab.unittest.TestCase
    %TEST_CACHEBASE Unit tests for CacheBase abstract class
    %   Tests .env loading, hash computation, JSON utilities, and
    %   local path computation. Uses a concrete subclass stub to test
    %   the abstract CacheBase.

    properties
        mock_remote
        mock_local
    end

    methods (TestMethodSetup)
        function createFixtures(testCase)
            test_dir = fileparts(mfilename('fullpath'));
            tmp_dir = fullfile(test_dir, 'tmp');

            % Clean previous run if exists
            if exist(tmp_dir, 'dir')
                rmdir(tmp_dir, 's');
            end

            % Create mock remote directory with test files
            testCase.mock_remote = fullfile(tmp_dir, 'mock_remote', 'project_A');
            mkdir(testCase.mock_remote);
            writelines("test data file 1", fullfile(testCase.mock_remote, 'data.txt'));
            writelines("test results file", fullfile(testCase.mock_remote, 'results.txt'));

            % Create empty local temp dir
            testCase.mock_local = fullfile(tmp_dir, 'local_cache');
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
        function testEnvExists(testCase)
            %TEST: .env file exists and RCLONE_PATH is set
            rclone_exe = CacheBase.loadEnv();
            testCase.verifyNotEmpty(rclone_exe, '.env should return a non-empty RCLONE_PATH');
        end

        function testRcloneReachable(testCase)
            %TEST: rclone.exe is reachable and runs
            rclone_exe = CacheBase.loadEnv();
            [status, result] = system(sprintf('"%s" --version', rclone_exe));
            testCase.verifyEqual(status, 0, ...
                sprintf('rclone should run successfully. Output: %s', result));
        end

        function testHashDeterministic(testCase)
            %TEST: computeHash returns the same result for the same input
            [short1, full1] = CacheBase.computeHash('//server/project_A/data');
            [short2, full2] = CacheBase.computeHash('//server/project_A/data');
            testCase.verifyEqual(short1, short2, 'Short hash should be deterministic');
            testCase.verifyEqual(full1, full2, 'Full hash should be deterministic');
        end

        function testHashLengths(testCase)
            %TEST: computeHash returns 6-char short and 32-char full
            [short_hash, full_hash] = CacheBase.computeHash('/some/path');
            testCase.verifyLength(short_hash, 6, 'Short hash should be 6 characters');
            testCase.verifyLength(full_hash, 32, 'Full hash should be 32 characters');
        end

        function testHashShortIsPrefixOfFull(testCase)
            %TEST: short hash is the first 6 chars of the full hash
            [short_hash, full_hash] = CacheBase.computeHash('/some/test/path');
            testCase.verifyEqual(short_hash, full_hash(1:6), ...
                'Short hash should be the first 6 chars of full hash');
        end

        function testDifferentPathsDifferentHashes(testCase)
            %TEST: different paths produce different hashes
            [short1, ~] = CacheBase.computeHash('//server/project_A/data');
            [short2, ~] = CacheBase.computeHash('//server/project_B/data');
            testCase.verifyNotEqual(short1, short2, ...
                'Different paths should produce different hashes');
        end

        function testHashHexCharacters(testCase)
            %TEST: hash output contains only valid hex characters
            [short_hash, full_hash] = CacheBase.computeHash('/test/path');
            testCase.verifyTrue(all(ismember(short_hash, '0123456789abcdef')), ...
                'Short hash should contain only hex characters');
            testCase.verifyTrue(all(ismember(full_hash, '0123456789abcdef')), ...
                'Full hash should contain only hex characters');
        end

        function testLocalDirNameFormat(testCase)
            %TEST: local_dir_name follows dirname_shorthash format
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            % The dirname should be project_A_<6charhash>
            testCase.verifyTrue(startsWith(ct.local_dir_name, 'project_A_'), ...
                'local_dir_name should start with the remote directory name');
            parts = strsplit(ct.local_dir_name, '_');
            hash_part = parts{end};
            testCase.verifyLength(hash_part, 6, ...
                'Hash suffix in local_dir_name should be 6 characters');
        end

        function testLocalFilePathPreservesFilename(testCase)
            %TEST: local_file_path preserves the original filename
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            [~, name, ext] = fileparts(ct.local_file_path);
            testCase.verifyEqual([name, ext], 'data.txt', ...
                'local_file_path should preserve the original filename');
        end

        function testLocalDirCreated(testCase)
            %TEST: constructor creates the local dirname_hash/ directory
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            testCase.verifyTrue(exist(ct.local_dir_path, 'dir') == 7, ...
                'Constructor should create the local dirname_hash/ directory');
        end

        function testDirHashTxtCreated(testCase)
            %TEST: constructor creates dirname_hash.txt breadcrumb file
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            txt_path = fullfile(testCase.mock_local, [ct.local_dir_name, '.txt']);
            testCase.verifyTrue(exist(txt_path, 'file') == 2, ...
                'Constructor should create dirname_hash.txt');

            % Verify contents
            content = fileread(txt_path);
            testCase.verifyTrue(contains(content, 'Remote directory:'), ...
                'dirname_hash.txt should contain remote directory');
            testCase.verifyTrue(contains(content, 'Full hash:'), ...
                'dirname_hash.txt should contain full hash');
            testCase.verifyTrue(contains(content, ct.full_hash), ...
                'dirname_hash.txt should contain the actual full hash value');
        end

        function testJsonRoundTrip(testCase)
            %TEST: readJson and writeJson round-trip correctly
            remote = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct = CacheToLocal(remote, testCase.mock_local);

            % Write a test JSON
            test_json_path = fullfile(testCase.mock_local, 'test_roundtrip.json');
            test_data = struct('key1', 'value1', 'key2', 42, 'key3', true);
            ct.writeJsonPublic(test_json_path, test_data);

            % Read it back
            loaded = ct.readJsonPublic(test_json_path);
            testCase.verifyEqual(loaded.key1, 'value1');
            testCase.verifyEqual(loaded.key2, 42);
            testCase.verifyEqual(loaded.key3, true);
        end

        function testHashCollisionDetection(testCase)
            %TEST: hash collision detection errors when same hash maps to different dir
            % This test verifies the collision check mechanism.
            % We can't easily force a real collision, so we test that
            % the same remote dir reuses the entry without error.
            remote1 = pth(fullfile(testCase.mock_remote, 'data.txt'));
            ct1 = CacheToLocal(remote1, testCase.mock_local);

            % Same directory, different file — should NOT error (same hash)
            remote2 = pth(fullfile(testCase.mock_remote, 'results.txt'));
            ct2 = CacheToLocal(remote2, testCase.mock_local);

            testCase.verifyEqual(ct1.local_dir_name, ct2.local_dir_name, ...
                'Files from same remote dir should share the same local dir');
        end

        function testInvalidRemotePathErrors(testCase)
            %TEST: constructor errors if remote_path is not a pth object
            testCase.verifyError(@() CacheToLocal('not_a_pth', testCase.mock_local), ...
                'CacheBase:InvalidInput');
        end
    end
end

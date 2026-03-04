classdef pth
    properties
        PathParts
        StartsWithSeparator
        EndsWithSeparator
    end
    
    methods
        function obj = pth(pathString)
            % Constructor
            % Check and store if the path starts/ends with a file separator
            obj.StartsWithSeparator = ~isempty(regexp(pathString, '^[/\\]', 'once'));
            obj.EndsWithSeparator = ~isempty(regexp(pathString, '[/\\]$', 'once'));

            % Use regexp to split at both forward and backward slashes
            obj.PathParts = regexp(pathString, '[/\\]+', 'split');
            % Remove empty cells that may occur due to splitting
            obj.PathParts = obj.PathParts(~cellfun('isempty', obj.PathParts));
        end
        
        function fullPath = get(obj)
            % Build full path using the appropriate file separator
            fullPath = strjoin(obj.PathParts, filesep);

            % Prepend or append file separator if necessary
            if obj.StartsWithSeparator
                fullPath = [filesep, fullPath];
            end
            if obj.EndsWithSeparator && ~isempty(obj.PathParts)
                fullPath = [fullPath, filesep];
            end
        end
    end
end
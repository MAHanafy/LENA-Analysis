function recordings = find_recordings(baseDir, cfg)
%FIND_RECORDINGS Recursively discover ITS recordings below BASEDIR.

baseDir = char(baseDir);
allItsFiles = dir(fullfile(baseDir, '**', '*.its'));
if isempty(allItsFiles)
    fprintf(2, ['\n*** WARNING: No .its files found in baseDir:\n' ...
        '    %s\n    Update baseDir to the folder that contains your ITS/WAV data.\n\n'], baseDir);
    error('No .its files found in or under directory: %s', baseDir);
end

[~, selectedBaseFolderName] = fileparts(baseDir);
useConfiguredAges = strcmpi(selectedBaseFolderName, 'AM28');
if ~useConfiguredAges
    warning('No age lookup is configured for this folder. Legacy acoustic age fields will be NaN.');
end

recordings = repmat(struct( ...
    'folder', '', 'name', '', 'subjectName', '', 'baseName', '', ...
    'age', NaN, 'index', 0, 'total', numel(allItsFiles)), numel(allItsFiles), 1);

for ik = 1:numel(allItsFiles)
    fname = allItsFiles(ik).name;
    [~, stem] = fileparts(fname);
    separatorIndex = strfind(stem, '_');
    if isempty(separatorIndex)
        subjectName = stem;
    else
        subjectName = stem(1:separatorIndex(1)-1);
    end

    if startsWith(stem, [subjectName '_'], 'IgnoreCase', true)
        baseName = stem;
    else
        baseName = [subjectName '_' stem];
    end

    if useConfiguredAges && ik <= numel(cfg.ages)
        age = cfg.ages(ik);
    else
        age = NaN;
    end

    recordings(ik).folder = allItsFiles(ik).folder;
    recordings(ik).name = fname;
    recordings(ik).subjectName = subjectName;
    recordings(ik).baseName = baseName;
    recordings(ik).age = age;
    recordings(ik).index = ik;
end
end

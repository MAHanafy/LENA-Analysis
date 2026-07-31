function resultsFolder = run_lena_analysis(baseDir, cfg)
%RUN_LENA_ANALYSIS Run the modular LENA acoustic/interaction pipeline.
%
%   run_lena_analysis
%       Opens a folder-selection window.
%
%   run_lena_analysis(baseDir)
%       Processes all paired ITS/WAV recordings beneath baseDir.
%
% The analysis algorithms and output schemas are unchanged from
% acoust_detail_funcs_newhelpers_MH.m; the code is only reorganized.

tic

if nargin < 2 || isempty(cfg)
    cfg = lena.config();
end

if nargin < 1 || isempty(baseDir)
    fprintf(['A window will now open. Select a cohort or subject folder ' ...
        'containing ITS/WAV data.\n\n']);
    baseDir = uigetdir(cfg.defaultBaseDir, ...
        'Select cohort or subject data folder');
    if isequal(baseDir, 0)
        error('User cancelled folder selection.');
    end
end
baseDir = char(baseDir);
disp(['Folder selected: ' baseDir]);

scriptPath = fileparts(mfilename('fullpath'));
addpath(scriptPath);

if exist('shrp', 'file') ~= 2
    error(['shrp.m not found on MATLAB path. Add shrp.m to the script ' ...
        'folder or MATLAB path.']);
end

recordings = lena.find_recordings(baseDir, cfg);

timestamp = char(datetime("now", "Format", "yyyyMMdd"));
resultsFolder = fullfile(scriptPath, ['results_' timestamp]);
if ~exist(resultsFolder, 'dir')
    mkdir(resultsFolder);
end

subjectResultFolders = strings(0, 1);
subjectNames = strings(0, 1);
for ik = 1:numel(recordings)
    result = lena.process_recording(recordings(ik), cfg);
    result = lena.save_results(result, resultsFolder, cfg);
    lena.create_plots(result, cfg);
    subjectResultFolders(end + 1, 1) = string(result.subjectResultsFolder);
    subjectNames(end + 1, 1) = string(result.subjectName);

    disp(' ');
    disp('Done.');
    disp(['file: ' result.baseName ', here: ' result.resultsFolder])
end

[uniqueSubjectFolders, subjectIndexes] = unique(subjectResultFolders, 'stable');
for subjectIndex = 1:numel(uniqueSubjectFolders)
    try
        finalResult = struct( ...
            'subjectResultsFolder', char(uniqueSubjectFolders(subjectIndex)), ...
            'subjectName', char(subjectNames(subjectIndexes(subjectIndex))));
        lena.save_results(finalResult, resultsFolder, cfg, true);
    catch mergeError
        warning('Could not create merged workbook for %s: %s', ...
            subjectNames(subjectIndexes(subjectIndex)), mergeError.message);
    end
end

toc
end

function result = save_results(result, resultsFolder, cfg)
%SAVE_RESULTS Write unchanged recording outputs and refresh the subject workbook.

subjectResultsFolder = build_mirrored_subject_results_folder( ...
    resultsFolder, result.currDir, result.subjectName);
if ~exist(subjectResultsFolder, 'dir')
    mkdir(subjectResultsFolder);
end

itsResultsFolder = fullfile(subjectResultsFolder, result.baseName);
if ~exist(itsResultsFolder, 'dir')
    mkdir(itsResultsFolder);
end

save_outputs_original(itsResultsFolder, result.subjectName, result.fname, ...
    result.dataF0c, result.dataF0c2f, result.dataF0c2m, result.dataF0f, ...
    result.dataF0m, result.interactionResults, result.segmentTable, ...
    result.turnPairs, cfg.nameCorrespondencesFile);

try
    merge_subject_all_segments(subjectResultsFolder, result.subjectName);
catch mergeError
    warning('Could not refresh merged workbook for %s: %s', ...
        result.subjectName, mergeError.message);
end

result.resultsFolder = itsResultsFolder;
result.subjectResultsFolder = subjectResultsFolder;
end

function baseName = build_output_base_name(subjName, fname)
% Return a stable output stem for both supported ITS filename formats.
%   Old: e20101221_110132_003524.its               -> AM28_e20101221_110132_003524
%   New: AM28_010213_e20110124_120018_003264.its  -> AM28_010213_e20110124_120018_003264
    [~, fileStem, ~] = fileparts(fname);
    subjectPrefix = [subjName '_'];
    if startsWith(fileStem, subjectPrefix, 'IgnoreCase', true)
        baseName = fileStem;
    else
        baseName = [subjName '_' fileStem];
    end
end


function save_outputs_original(resultsFolder, subjName, fname, dataF0c, dataF0c2f, dataF0c2m, dataF0f, dataF0m, interactionResults, segmentTable, turnPairs, nameCorrespondencesFile)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if nargin < 11
        turnPairs = table();
    end
    if nargin < 12
        nameCorrespondencesFile = '';
    end
    % SAVE_OUTPUTS_ORIGINAL
    %
    % PURPOSE:
    % Save all acoustic output structures into .mat files using the same
    % naming convention as the original script.
    %
    % INPUT:
    %   resultsFolder = destination folder for output files
    %   subjName      = subject name
    %   fname         = original ITS file name
    %   dataF0c       = child results
    %   dataF0c2f     = child-to-female-adult results
    %   dataF0c2m     = child-to-male-adult results
    %   dataF0f       = female adult near results
    %   dataF0m       = male adult near results
    %
    % NOTES:
    % - Files are saved in MATLAB .mat format.
    % - File names follow the pattern:
    %     subjName_recordingLabel_CATEGORY.mat
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    cd(resultsFolder);
    outputBaseName = build_output_base_name(subjName, fname);
    save([outputBaseName '_CHN'], 'dataF0c');
    save([outputBaseName '_CHN2FAN'], 'dataF0c2f');
    save([outputBaseName '_CHN2MAN'], 'dataF0c2m');
    save([outputBaseName '_FAN'], 'dataF0f');
    save([outputBaseName '_MAN'], 'dataF0m');
    save([outputBaseName '_AICM_INTERACTIONS'], 'interactionResults', 'segmentTable', 'turnPairs');

    allSegmentsCore = create_all_segments_table(segmentTable, interactionResults, turnPairs);
    allSegmentsFileName = [outputBaseName '_AICM_INTERACTIONS_All_Segments'];
    allSegmentsTable = add_recording_metadata_columns(allSegmentsCore, outputBaseName, ...
        allSegmentsFileName, nameCorrespondencesFile);
    if ~isempty(allSegmentsTable) && height(allSegmentsTable) > 0
        writetable(allSegmentsTable, [allSegmentsFileName '.csv']);
    end

    interactionsCore = create_combined_aicm_table(allSegmentsCore);
    interactionsFileName = [outputBaseName '_AICM_INTERACTIONS'];
    interactionsTable = add_recording_metadata_columns(interactionsCore, outputBaseName, ...
        interactionsFileName, nameCorrespondencesFile);
    if ~isempty(interactionsTable) && height(interactionsTable) > 0
        writetable(interactionsTable, [interactionsFileName '.csv']);
    end
end



function outputTable = add_recording_metadata_columns(inputTable, recordingBaseName, outputFileName, nameCorrespondencesFile)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ADD_RECORDING_METADATA_COLUMNS
%
% Prepend recording-level metadata to every exported row:
%   1) file name    = output CSV stem (the name shown as the Excel sheet)
%   2) subject name = first token of the combined recording name
%   3) Session ID   = column A lookup by Combined name in column E
%   4) Date         = the eYYYYMMDD token stored as a MATLAB datetime
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    nRows = height(inputTable);

    subjectName = regexp(recordingBaseName, '^[^_]+', 'match', 'once');
    if isempty(subjectName)
        subjectName = recordingBaseName;
    end

    dateDigits = regexp(recordingBaseName, '(?:^|_)e(\d{8})(?:_|$)', 'tokens', 'once');
    recordingDate = NaT;
    if ~isempty(dateDigits)
        recordingDate = datetime(dateDigits{1}, 'InputFormat', 'yyyyMMdd', 'Format', 'M/d/yyyy');
    else
        warning('No eYYYYMMDD date token found in recording name: %s', recordingBaseName);
    end

    sessionID = lookup_session_id_by_combined_name(recordingBaseName, nameCorrespondencesFile);

    fileNames = repmat(string(outputFileName), nRows, 1);
    subjectNames = repmat(string(subjectName), nRows, 1);
    sessionIDs = repmat(sessionID, nRows, 1);
    dates = repmat(recordingDate, nRows, 1);

    metadataTable = table(fileNames, subjectNames, sessionIDs, dates, ...
        'VariableNames', {'file name','subject name','Session ID','Date'});
    outputTable = [metadataTable inputTable];
end

function sessionID = lookup_session_id_by_combined_name(recordingBaseName, nameCorrespondencesFile)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Search every worksheet in Name_Correspondences.xlsx. The lookup key is
% the Combined name in column E and the returned Session ID is column A.
% Reading by column position also supports sheets whose headers differ.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    persistent cachedWorkbookPath cachedCombinedNames cachedSessionIDs

    sessionID = NaN;
    if isempty(nameCorrespondencesFile) || ~isfile(nameCorrespondencesFile)
        warning('Name correspondence workbook not found: %s', nameCorrespondencesFile);
        return;
    end

    % Cache the correspondence workbook because this function is called for
    % both CSV exports from every recording.
    if isempty(cachedWorkbookPath) || ~strcmp(cachedWorkbookPath, nameCorrespondencesFile)
        cachedWorkbookPath = nameCorrespondencesFile;
        cachedCombinedNames = strings(0, 1);
        cachedSessionIDs = zeros(0, 1);

        sheetList = sheetnames(nameCorrespondencesFile);
        for s = 1:numel(sheetList)
            raw = readcell(nameCorrespondencesFile, 'Sheet', sheetList{s});
            if size(raw, 2) < 5
                continue;
            end

            for r = 1:size(raw, 1)
                combinedName = strtrim(string(raw{r, 5}));
                rawSessionID = raw{r, 1};
                if isnumeric(rawSessionID) && isscalar(rawSessionID)
                    numericSessionID = double(rawSessionID);
                else
                    numericSessionID = str2double(string(rawSessionID));
                end
                if strlength(combinedName) > 0 && ~ismissing(combinedName) && ~isnan(numericSessionID)
                    cachedCombinedNames(end+1, 1) = combinedName; %#ok<AGROW>
                    cachedSessionIDs(end+1, 1) = numericSessionID; %#ok<AGROW>
                end
            end
        end
    end

    matchIndex = find(strcmpi(cachedCombinedNames, string(recordingBaseName)), 1, 'first');
    if ~isempty(matchIndex)
        sessionID = cachedSessionIDs(matchIndex);
        return;
    end

    warning('No Session ID match found for Combined name: %s', recordingBaseName);
end

function subjectFolder = build_mirrored_subject_results_folder(resultsFolder, sourceFolder, subjectName)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Mirror the source hierarchy beginning immediately below Cougar_union and
% ending at the subject. For example:
%   F:\...\Cougar_union\CI\S1AC\2014_12
% becomes:
%   results_YYYYMMDD\CI\S1AC
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    normalizedSource = strrep(sourceFolder, '/', filesep);
    pathParts = strsplit(normalizedSource, filesep);
    cougarIndex = find(strcmpi(pathParts, 'Cougar_union'), 1, 'last');
    subjectIndex = find(strcmpi(pathParts, subjectName), 1, 'last');

    if ~isempty(cougarIndex) && ~isempty(subjectIndex) && subjectIndex > cougarIndex
        relativeParts = pathParts(cougarIndex + 1 : subjectIndex);
        subjectFolder = fullfile(resultsFolder, relativeParts{:});
    else
        % Safe fallback for data stored outside the Cougar_union hierarchy.
        subjectFolder = fullfile(resultsFolder, subjectName);
    end
end

function merge_subject_all_segments(subjectFolder, subjectName)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Merge all completed recording-level All-Segments CSVs for one subject.
% This function is called after every successful session so the workbook is
% always current, even during a long cohort-level run.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    csvFiles = dir(fullfile(subjectFolder, '**', '*_AICM_INTERACTIONS_All_Segments.csv'));
    if isempty(csvFiles)
        return;
    end

    [~, order] = sort({csvFiles.name});
    csvFiles = csvFiles(order);
    mergedTable = table();

    for f = 1:numel(csvFiles)
        csvPath = fullfile(csvFiles(f).folder, csvFiles(f).name);
        currentTable = lena.read_all_segments_csv(csvPath);
        if isempty(mergedTable)
            mergedTable = currentTable;
        else
            if ~isequal(mergedTable.Properties.VariableNames, currentTable.Properties.VariableNames)
                error('Cannot merge All-Segments CSVs because columns differ: %s', csvPath);
            end
            mergedTable = [mergedTable; currentTable]; %#ok<AGROW>
        end
    end

    sortColumns = {'Date','file name','conversationId','startSec'};
    sortColumns = sortColumns(ismember(sortColumns, mergedTable.Properties.VariableNames));
    if ~isempty(sortColumns)
        mergedTable = sortrows(mergedTable, sortColumns);
    end
    if ismember('Date', mergedTable.Properties.VariableNames) && isdatetime(mergedTable.('Date'))
        mergedTable.('Date').Format = 'M/d/yyyy';
    end

    outputXlsx = fullfile(subjectFolder, [subjectName '_AICM_INTERACTIONS_All_Segments.xlsx']);
    writetable(mergedTable, outputXlsx, 'Sheet', 'All_Segments', 'WriteMode', 'overwritesheet');
    fprintf('Merged %d completed sessions (%d rows) for %s into:\n  %s\n', ...
        numel(csvFiles), height(mergedTable), subjectName, outputXlsx);
end



function allSegmentsTable = create_all_segments_table(segmentTable, interactionResults, turnPairs)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% CREATE_ALL_SEGMENTS_TABLE
%
% PURPOSE:
% Export one row per speaker segment with classLabel from any interaction
% it participates in (initiator or responder). Blank only if unclassified.
% Written to *_AICM_INTERACTIONS_All_Segments.csv
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if nargin < 3
        turnPairs = table();
    end

    if isempty(segmentTable)
        allSegmentsTable = empty_all_segments_table_v3();
        return;
    end

    nSegments = height(segmentTable);
    speakers = strings(nSegments, 1);
    startSecs = zeros(nSegments, 1);
    endSecs = zeros(nSegments, 1);
    durationSecs = zeros(nSegments, 1);
    conversationIds = zeros(nSegments, 1);
    segmentIndices = zeros(nSegments, 1);
    isValidSpeeches = false(nSegments, 1);
    wordCounts = zeros(nSegments, 1);
    sourceLineIndices = nan(nSegments, 1);
    classLabels = strings(nSegments, 1);
    fromSpeakers = strings(nSegments, 1);
    gapSecs = nan(nSegments, 1);
    speechTypes = strings(nSegments, 1);
    f0means = nan(nSegments, 1);
    f0stds = nan(nSegments, 1);
    f0mins = nan(nSegments, 1);
    f0maxs = nan(nSegments, 1);
    f0ranges = nan(nSegments, 1);
    f0rangesST = nan(nSegments, 1);
    dBFSs = nan(nSegments, 1);
    dBSPLs = nan(nSegments, 1);
    pctUttVxs = nan(nSegments, 1);
    syllableCounts = nan(nSegments, 1);
    syllablesPerSecs = nan(nSegments, 1);

    for i = 1:nSegments
        speakers(i) = string(segmentTable.speaker(i));
        startSecs(i) = segmentTable.startSec(i);
        endSecs(i) = segmentTable.endSec(i);
        durationSecs(i) = segmentTable.durationSec(i);
        conversationIds(i) = tableColOrDefault(segmentTable, i, 'conversationId', NaN);
        segmentIndices(i) = tableColOrDefault(segmentTable, i, 'segmentIndex', NaN);
        isValidSpeeches(i) = logical(tableColOrDefault(segmentTable, i, 'isValidSpeech', false));
        wordCounts(i) = segment_word_count_v3(segmentTable, i);
        if ismember('sourceLineIndex', segmentTable.Properties.VariableNames)
            sourceLineIndices(i) = segmentTable.sourceLineIndex(i);
        elseif ismember('sourceIndex', segmentTable.Properties.VariableNames)
            sourceLineIndices(i) = segmentTable.sourceIndex(i);
        end

        % Acoustic values are stored for every segment, including segments
        % with no interaction label. F0 values may legitimately remain NaN.
        f0means(i) = tableColOrNan(segmentTable, i, 'f0mean');
        f0stds(i) = tableColOrNan(segmentTable, i, 'f0std');
        f0mins(i) = tableColOrNan(segmentTable, i, 'f0min');
        f0maxs(i) = tableColOrNan(segmentTable, i, 'f0max');
        f0ranges(i) = tableColOrNan(segmentTable, i, 'f0range');
        f0rangesST(i) = tableColOrNan(segmentTable, i, 'f0rangeST');
        dBFSs(i) = tableColOrNan(segmentTable, i, 'dBFS');
        dBSPLs(i) = tableColOrNan(segmentTable, i, 'dBSPL');
        pctUttVxs(i) = tableColOrNan(segmentTable, i, 'pctUttVx');
        syllableCounts(i) = tableColOrNan(segmentTable, i, 'syllableCount');
        syllablesPerSecs(i) = tableColOrNan(segmentTable, i, 'syllablesPerSec');

        intIdx = find_interaction_row_for_segment(interactionResults, conversationIds(i), segmentIndices(i));
        if ~isempty(intIdx)
            classLabels(i) = string(interactionResults.classLabel(intIdx));
            gapSecs(i) = tableColOrNan(interactionResults, intIdx, 'gapSec');
            speechTypes(i) = string(tableColOrDefault(interactionResults, intIdx, 'speechType', ""));
        end

        pairIdx = find_turn_pair_for_target_segment(turnPairs, conversationIds(i), segmentIndices(i));
        if isempty(pairIdx)
            pairIdx = find_turn_pair_for_source_segment(turnPairs, conversationIds(i), segmentIndices(i));
        end
        if ~isempty(pairIdx)
            fromSpeakers(i) = string(turnPairs.fromSpeaker(pairIdx));
            if classLabels(i) == ""
                classLabels(i) = string(turnPairs.classLabel(pairIdx));
            end
            if isnan(gapSecs(i))
                gapSecs(i) = turnPairs.gapSec(pairIdx);
            end
            if speechTypes(i) == ""
                speechTypes(i) = string(turnPairs.speechType(pairIdx));
            end
        end
    end

    allSegmentsTable = table( ...
        conversationIds, speakers, startSecs, endSecs, isValidSpeeches, wordCounts, durationSecs, ...
        classLabels, fromSpeakers, gapSecs, speechTypes, ...
        f0means, f0stds, f0mins, f0maxs, f0ranges, f0rangesST, dBFSs, dBSPLs, pctUttVxs, syllableCounts, syllablesPerSecs, ...
        sourceLineIndices, ...
        'VariableNames', { ...
            'conversationId','speaker','startSec','endSec','isValidSpeech','WordCount','durationSec', ...
            'classLabel','fromSpeaker','gapSec','speechType', ...
            'f0mean','f0std','f0min','f0max','f0range','f0rangeST','dBFS','dBSPL','pctUttVx','syllableCount','syllablesPerSec', ...
            'sourceLineIndex'});

    allSegmentsTable = sortrows(allSegmentsTable, {'conversationId','startSec','endSec'});
end

function allSegmentsTable = empty_all_segments_table_v3()
    allSegmentsTable = table( ...
        zeros(0,1), strings(0,1), zeros(0,1), zeros(0,1), false(0,1), zeros(0,1), zeros(0,1), ...
        strings(0,1), strings(0,1), zeros(0,1), strings(0,1), ...
        zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        zeros(0,1), ...
        'VariableNames', { ...
            'conversationId','speaker','startSec','endSec','isValidSpeech','WordCount','durationSec', ...
            'classLabel','fromSpeaker','gapSec','speechType', ...
            'f0mean','f0std','f0min','f0max','f0range','f0rangeST','dBFS','dBSPL','pctUttVx','syllableCount','syllablesPerSec', ...
            'sourceLineIndex'});
end

function wordCount = segment_word_count_v3(segmentTable, rowIdx)
% Speaker-appropriate LENA count: childUttCnt for CHN, adultWordCnt for FAN/MAN.
    spkr = string(segmentTable.speaker(rowIdx));
    if spkr == "CHN"
        wordCount = tableColOrDefault(segmentTable, rowIdx, 'childUttCnt', 0);
    else
        wordCount = tableColOrDefault(segmentTable, rowIdx, 'adultWordCnt', 0);
    end
end

function combinedTable = create_combined_aicm_table(allSegmentsTable)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% CREATE_COMBINED_AICM_TABLE
%
% PURPOSE:
% Build *_AICM_INTERACTIONS.csv as a filtered subset of All_Segments:
% one row per speaker segment that participates in a classified interaction
% (non-empty classLabel), with acoustic analysis columns.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    interactionVarNames = { ...
        'conversationId','speaker','classLabel','startSec','endSec', ...
        'gapSec','speechType','f0mean','f0std','f0min','f0max','f0range','f0rangeST', ...
        'dBFS','dBSPL','pctUttVx','syllableCount','syllablesPerSec'};

    if nargin < 1 || isempty(allSegmentsTable) || height(allSegmentsTable) == 0
        combinedTable = empty_combined_aicm_table_v3();
        return;
    end

    labels = string(allSegmentsTable.classLabel);
    hasLabel = strlength(strtrim(labels)) > 0;
    filtered = allSegmentsTable(hasLabel, :);

    if height(filtered) == 0
        combinedTable = empty_combined_aicm_table_v3();
        return;
    end

    combinedTable = filtered(:, interactionVarNames);
    combinedTable = sortrows(combinedTable, {'conversationId','startSec','endSec'});
end

function combinedTable = empty_combined_aicm_table_v3()
    combinedTable = table( ...
        zeros(0,1), strings(0,1), strings(0,1), zeros(0,1), zeros(0,1), ...
        zeros(0,1), strings(0,1), ...
        zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        'VariableNames', { ...
            'conversationId','speaker','classLabel','startSec','endSec', ...
            'gapSec','speechType','f0mean','f0std','f0min','f0max','f0range','f0rangeST', ...
            'dBFS','dBSPL','pctUttVx','syllableCount','syllablesPerSec'});
end

function idx = find_interaction_row_for_segment(interactionResults, conversationId, segmentIndex)
    idx = [];
    if isempty(interactionResults) || isnan(segmentIndex)
        return;
    end
    mask = interactionResults.conversationId == conversationId & interactionResults.segmentIndex == segmentIndex;
    hit = find(mask, 1, 'first');
    if ~isempty(hit)
        idx = hit;
    end
end

function idx = find_turn_pair_for_target_segment(turnPairs, conversationId, segmentIndex)
    idx = [];
    if isempty(turnPairs) || isnan(segmentIndex)
        return;
    end
    mask = turnPairs.conversationId == conversationId & turnPairs.toSegmentIndex == segmentIndex;
    hits = find(mask);
    if isempty(hits)
        return;
    end
    [~, bestLocal] = min(turnPairs.gapSec(hits));
    idx = hits(bestLocal);
end

function idx = find_turn_pair_for_source_segment(turnPairs, conversationId, segmentIndex)
    idx = [];
    if isempty(turnPairs) || isnan(segmentIndex)
        return;
    end
    mask = turnPairs.conversationId == conversationId & turnPairs.fromSegmentIndex == segmentIndex;
    hits = find(mask);
    if isempty(hits)
        return;
    end
    [~, bestLocal] = min(turnPairs.gapSec(hits));
    idx = hits(bestLocal);
end

function idx = find_segment_row_v3(segmentTable, conversationId, segmentIndex)
    idx = [];
    if isempty(segmentTable) || isnan(segmentIndex)
        return;
    end
    mask = segmentTable.conversationId == conversationId & segmentTable.segmentIndex == segmentIndex;
    hit = find(mask, 1, 'first');
    if ~isempty(hit)
        idx = hit;
    end
end

function val = tableColOrDefault(tbl, rowIdx, colName, defaultVal)
    if ismember(colName, tbl.Properties.VariableNames)
        val = tbl.(colName)(rowIdx);
    else
        val = defaultVal;
    end
end

function val = tableColOrNan(tbl, rowIdx, colName)
    %TABLECOLORNAN Read an optional table column, falling back to NaN.
    %   Acoustic columns are added only when their analyses are enabled, so
    %   output creation must tolerate tables that do not contain them.
    if ismember(colName, tbl.Properties.VariableNames)
        val = tbl.(colName)(rowIdx);
    else
        val = NaN;
    end
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% This script does acoustic analysis of any number of paired .WAV + .ITS
%%% files in some directory. It collects by talker (CHN, FAN, MAN) and
%%% conversational interaction types (ADS, CDS).
%%%
%%% Contextual Filtering: 
% The script specifically looks for AICM (Adult-Initiated Conversational Monitoring) 
% blocks to keep data separate for each file pair. 
% This high-level feedback on the natural language environment 
% is what LENA was optimized for—identifying patterns of child vocal behavior.
%%% PIPELINE:
% 1) Select folder containing ITS files
% 2) Find all ITS files recursively
% 3) Parse AICM conversations   
% 4) Extract speaker intervals (CHN, FAN, MAN)
% 5) Extract child interaction contexts (CHN2FAN, CHN2MAN)
% 6) Build AICM segment table (speaker, start, end)
% 7) Classify directional interactions:
%       MANtoMAN, MANtoFAN, FANtoMAN, FANtoFAN
%       MANtoCHN, CHNtoMAN, FANtoCHN, CHNtoFAN
% 8) Run F0 extraction using shrp.m
% 9) Compute acoustic features:
%       F0 mean, F0 min, F0 max, F0 std, dBFS, syllables
% 10) Save ITS/interaction + acoustic results (.mat, CSV) and summary plots
%%%
%%% NOTES:
% - Default classifier: v3 turn-pair pipeline (see default_interaction_params_v3)
% - Legacy classifiers (simple / rules) kept for comparison
% - Directionality is preserved (e.g., MAN→CHN ≠ CHN→MAN)
% - v3 uses one primary label per segment (segmentPrimaryLabelOnly=true)
% - v3 interactionResults includes both initiator and responder segments
%%%
%%% Mark VanDam, Jan. 2013
%%% Updated: Mohamed A. Hanafy, March 2026
%%% Updates_2: Mohamed A. Hanafy, April 2026 (interaction classification + acoustic features)
%%% Updates_3: Osvaldo Rodriguez, June 2026 — v3 interaction classifier integrated from aicm_interaction_classifier_v3.m
%%%   - Per-conversation classification (no cross-block linking)
%%%   - LENA turn-code metadata (TIMI, TIMR, TIFI, TIFR, ...)
%%%   - Turn-pair model (one row per directed interaction)
%%%   - Nearest-neighbor search within adjacencyWindowSec
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% add the explanation for every column name  in th readme 

clear;
tic

ages = [2.53 2.41 2.59 2.36 2.37 2.72 2.10 2.41 2.35 2.23 ...
    2.39 2.63 2.53 2.42 2.44 2.41 2.24 2.94 2.29 2.45 2.49 2.46];  % used by audio pipeline only

%% ================= PARAMETERS =================
% --- Audio / F0 parameters ---
rate = 16000;
frame_length = 20;
TimeStep = 3;
SHR_Threshold = 0.4;
Ceiling = 1250;
med_smooth = 0;
CHECK_VOICING = 1;
trimEdgeFrames = 2;

% --- v3 interaction classifier parameters (recommended) ---
interactionParams = default_interaction_params_v3();
adjacencyWindowSec = interactionParams.adjacencyWindowSec;  % used by legacy comparison only

%% ================= USER INPUT- Folder Selection Tool =================
nameCorrespondencesFile = 'F:\SynologyDrive\Cougar_union\Name_Correspondences.xlsx';

% Select one common parent folder. The recursive file search below processes
% every subject beneath it. Examples:
%   Select ...\Cougar_union\HA  -> process every HA subject
%   Select ...\Cougar_union     -> process every cohort and subject
defaultBaseDir = 'F:\SynologyDrive\Cougar_union\HA';
fprintf('A window will now open. Select a cohort or subject folder containing ITS/WAV data.\n\n');
baseDir = uigetdir(defaultBaseDir, 'Select cohort or subject data folder');
if isequal(baseDir, 0)
    error('User cancelled folder selection.');
end
baseDir = char(baseDir);
disp(['Folder selected: ' baseDir]);

% The existing ages vector is AM28-specific. Do not attach those ages to
% other subjects when a cohort-level or multi-subject folder is selected.
[~, selectedBaseFolderName] = fileparts(baseDir);
useConfiguredAges = strcmpi(selectedBaseFolderName, 'AM28');
if ~useConfiguredAges
    warning('No age lookup is configured for this folder. Legacy acoustic age fields will be NaN.');
end

%% ================= SETUP =================
scriptPath = fileparts(mfilename('fullpath'));
addpath(scriptPath);

% --- shrp.m required for audio/F0 pipeline ---
if exist('shrp', 'file') ~= 2
    error('shrp.m not found on MATLAB path. Add shrp.m to the script folder or MATLAB path.');
end

%% ================= FIND FILES =================
allItsFiles = dir(fullfile(baseDir, '**', '*.its'));
if isempty(allItsFiles)
    fprintf(2, '\n*** WARNING: No .its files found in baseDir:\n    %s\n    Update baseDir to the folder that contains your ITS/WAV data.\n\n', baseDir);
    error('No .its files found in or under directory: %s', baseDir);
end

%% ================= RESULTS FOLDER =================
% Save output files in timestamped results directory
timestamp = char(datetime("now","Format","yyyyMMdd"));
resultsFolder = fullfile(scriptPath, ['results_' timestamp]);
if ~exist(resultsFolder, 'dir')
    mkdir(resultsFolder);
end

%% ================= MAIN LOOP =================
for ik = 1:numel(allItsFiles)   %for ik = 1:numel(allItsFiles)
    currDir = allItsFiles(ik).folder;
    fname = allItsFiles(ik).name;

    cd(currDir)
    fprintf('\n---------------------------------------------------\n');
    fprintf('Working on ITS file %d of %d\n', ik, numel(allItsFiles));
    disp(['Working on file: ' fname ' in directory: ' currDir]);

    [subjName, matByLine] = read_its_file_original(fname);

    if useConfiguredAges && ik <= numel(ages)
        currAge = ages(ik);
    else
        currAge = NaN;
    end

    [tCHN, tCHN2FAN, tCHN2MAN, tFAN, tMAN] = parse_intervals_original(matByLine);

    % NOTE: Interval analysis uses analyze_interval_original_1based (corrected MATLAB indexing).
    % Legacy alternative: analyze_interval_original (0-based indexing, VanDam 2013).

    % NOTE: Three interaction classifiers are available:
    %   1) run_interaction_pipeline_v3        -> v3 turn-pair (recommended, default)
    %   2) classify_aicm_interactions_rules   -> legacy rules classifier
    %   3) classify_aicm_interactions         -> legacy simple adjacency
    [segmentTable, interactionResults, turnPairs] = run_interaction_pipeline_v3(matByLine, interactionParams);
    % Legacy alternatives (uncomment to use instead of v3):
    % segmentTable = extract_aicm_event_table(matByLine);
    % interactionResults = classify_aicm_interactions_rules(segmentTable, adjacencyWindowSec);
    % turnPairs = table();
    %% -------- RESET ARRAYS --------
    clear matByLine;
    disp(['tCHN= ' num2str(length(tCHN)) '  tFAN= ' num2str(length(tFAN)), ...
        'tMAN= ' num2str(length(tMAN))])

    % New filenames already begin with the subject ID (for example,
    % AM28_010213_e20110124_120018_003264). Avoid adding AM28 twice while
    % retaining compatibility with older names such as e20101221_110132_003524.
    baseName = build_output_base_name(subjName, fname);
    % Mirror the source cohort/subject hierarchy in the result folder:
    % ...\Cougar_union\CI\S1AC\... becomes
    % results_YYYYMMDD\CI\S1AC\recording\...
    subjectResultsFolder = build_mirrored_subject_results_folder( ...
        resultsFolder, currDir, subjName);
    if ~exist(subjectResultsFolder, 'dir')
        mkdir(subjectResultsFolder);
    end
    itsResultsFolder = fullfile(subjectResultsFolder, baseName);
    if ~exist(itsResultsFolder, 'dir')
        mkdir(itsResultsFolder);
    end

    %% -------- ACOUSTIC FEATURES --------
    [dataF0c2f, dataF0c2m, dataF0c, dataF0f, dataF0m] = initialize_outputs_original( ...
        tCHN2FAN, tCHN2MAN, tCHN, tFAN, tMAN);

    dataF0c2f = analyze_category_original('C2F', tCHN2FAN, fname, [200 600], ...
        dataF0c2f, currAge, subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0c2m = analyze_category_original('C2M', tCHN2MAN, fname, [200 600], ...
        dataF0c2m, currAge, subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0c = analyze_category_original('C', tCHN, fname, [200 600], ...
        dataF0c, currAge, subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0f = analyze_category_original('F', tFAN, fname, [120 400], ...
        dataF0f, currAge, subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0m = analyze_category_original('M', tMAN, fname, [50 250], ...
        dataF0m, currAge, subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    % Analyze every extracted segment once, including segments that are not
    % assigned to an interaction. dBFS and syllables remain available when
    % F0 cannot be estimated; only F0-dependent fields stay NaN.
    segmentTable = add_acoustics_to_segment_table(segmentTable, fname, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
    interactionResults = sync_acoustics_from_segment_table(segmentTable, interactionResults);

    save_outputs_original(itsResultsFolder, subjName, fname, dataF0c, dataF0c2f, dataF0c2m, dataF0f, dataF0m, ...
        interactionResults, segmentTable, turnPairs, nameCorrespondencesFile);

    % Refresh the subject workbook after every successful session. This
    % preserves a usable merged file even if a later cohort file fails or
    % the run is stopped before reaching the final ITS file.
    try
        merge_subject_all_segments(subjectResultsFolder, subjName);
    catch mergeError
        warning('Could not refresh merged workbook for %s: %s', subjName, mergeError.message);
    end

    run_evaluation_visualization_light(interactionResults, itsResultsFolder, baseName);
    compare_classifiers_light(segmentTable, turnPairs, interactionResults, itsResultsFolder, baseName, interactionParams);
    disp(' ');
    disp('Done.');
    disp(['file: ' baseName ', here: ' itsResultsFolder])
end

toc

%% Visualization
% %evaluate the active classifier
% run_evaluation_visualization(interactionResults);
% %compare both classifiers
% compare_both_classifiers(eventTable, fname, rate, frame_length, TimeStep, ...
%     SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames, adjacencyWindowSec);

%% ======================== LOCAL FUNCTIONS ==============================

function [subjName, matByLine] = read_its_file_original(fname)
  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % READ_ITS_FILE_ORIGINAL
    %
    % PURPOSE:
    % Read the current ITS file line by line and store each line inside
    % a MATLAB structure array called matByLine.
    %
    % INPUT:
    %   fname = file name of the ITS file in the current working directory
    %
    % OUTPUT:
    %   subjName  = subject name extracted from the file name
    %   matByLine = structure array where each element has:
    %               matByLine(i).text = one line from the ITS file
    %
    % NOTES:
    % - The subject name is taken as the part before the first underscore.
    %   Example:
    %       'AM28_010114.its' -> subjName = 'AM28'
    % - If there is no underscore, the file name without '.its' is used.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    underscorePos = strfind(fname, '_');
    if ~isempty(underscorePos)
        subjName = fname(1:underscorePos(1)-1);
    else
        subjName = fname(1:end-4);
    end

    fid = fopen(fname);
    if fid == -1
        error(['Cannot open file: ' fname '. Make sure the file exists in the current directory.']);
    end

    lineNo = 0;                  % Initialize line counter.
    matByLine(1).text = [];      % Initialize the structure array.
    % Read the file line by line until the end of the file.
    while 1
        tline = fgetl(fid);
        if ~ischar(tline), break, end
        lineNo = lineNo + 1;
        matByLine(lineNo).text = tline;
    end
    fclose(fid);

    if lineNo == 0
        error(['No data was read from file: ' fname '. File may be empty or unreadable.']);
    end
    disp(['Read ' num2str(lineNo) ' lines from ITS file.']);
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

function [tCHN, tCHN2FAN, tCHN2MAN, tFAN, tMAN] = parse_intervals_original(matByLine)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % PARSE_INTERVALS_ORIGINAL
    %
    % PURPOSE:
    % Parse the ITS file contents and extract time intervals for:
    %   - CHN      = child speech
    %   - CHN2FAN  = child speech in context of female adult near
    %   - CHN2MAN  = child speech in context of male adult near
    %   - FAN      = female adult near speech
    %   - MAN      = male adult near speech
    %
    % INPUT:
    %   matByLine = structure array created by read_its_file_original
    %
    % OUTPUT:
    %   tCHN      = Nx2 matrix of child utterance start/end times
    %   tCHN2FAN  = Nx2 matrix of child utterances associated with FAN
    %   tCHN2MAN  = Nx2 matrix of child utterances associated with MAN
    %   tFAN      = Nx2 matrix of female adult near intervals
    %   tMAN      = Nx2 matrix of male adult near intervals
    %
    % NOTES:
    % - Only conversations of type AICM are analyzed.
    % - CHN2FAN and CHN2MAN use the neighbor-based rule:
    %   if the previous or next line contains FAN or MAN, then the child
    %   utterance is assigned to that context.
    % - Time values are extracted from the ITS XML-like text using regexp.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    % Initialize all interval arrays as empty.
        
    tCHN = [];
    tCHN2FAN = [];
    tCHN2MAN = [];
    tFAN = [];
    tMAN = [];

    for k = 1:length(matByLine)       % Loop through every line in the ITS file.
      if isempty(strfind(matByLine(k).text, 'type="AICM"')) %         % Only process lines that mark the start of an AICM conversation.
            continue;
        end
        % Build the conversation block (cBlock) until </Conversation>.
        kk = 0;
        cBlock = [];
        while 1
            kk = kk + 1;
            if k+kk > length(matByLine)-1, break, end
            if ~isempty(strfind(matByLine(k+kk).text, '</Conversation>')), break, end
            cBlock(kk).text = matByLine(k+kk).text;
        end
        
        % Now parse the contents of this AICM conversation block.
        for jj = 1:length(cBlock)
            kLine = cBlock(jj).text;

            % ================= CHILD SPEECH =================
            if contains(kLine, 'spkr="CHN"')
                % Find where childUttCnt appears in the line.
                uttCntIndx = regexpi(kLine, 'childUttCnt="', 'end');
                % Extract the numeric value directly after childUttCnt=".
                uttCntStr = regexp(kLine(uttCntIndx+1:end), '^\d+', 'match', 'once');
                % Convert extracted utterance count to numeric value.
                if isempty(uttCntStr), uttCnt = 0; else, uttCnt = str2double(uttCntStr); end

                % Loop over all child utterances listed in this line.
                for m = 1:uttCnt
                    % Extract start and end time tokens for utterance m.
                    tkStart = regexp(kLine, ['startUtt' num2str(m) '="PT([\d\.]+)S"'], 'tokens', 'once');
                    tkEnd = regexp(kLine, ['endUtt' num2str(m) '="PT([\d\.]+)S"'], 'tokens', 'once');

                    if isempty(tkStart) || isempty(tkEnd)
                        continue;
                    end
                    % Extract time strings.
                    tStartUtt = tkStart{1};
                    tEndUtt = tkEnd{1};

                    % Store child utterance interval in tCHN.
                    tCHN = [tCHN; str2double(tStartUtt) str2double(tEndUtt)];
                    %  Neighbor-based rule for CHN2FAN / CHN2MAN:
                    % Only check if current CHN line is not the first or last line in the block.
            
                    if (1 < jj) && (jj < length(cBlock)-1)
                        %If the previous or next line contains FAN,
                        % assign this child utterance to CHN2FAN.
                        if contains([cBlock(jj+1).text cBlock(jj-1).text], 'spkr="FAN"')
                            tCHN2FAN = [tCHN2FAN; str2double(tStartUtt) str2double(tEndUtt)]; 
                        end
                        % If the previous or next line contains MAN,
                        % assign this child utterance to CHN2MAN.
                        if contains([cBlock(jj+1).text cBlock(jj-1).text], 'spkr="MAN"')
                            tCHN2MAN = [tCHN2MAN; str2double(tStartUtt) str2double(tEndUtt)]; 
                        end
                    end
                end
            end

           % ================= FEMALE ADULT NEAR =================

            if contains(kLine, 'spkr="FAN"')
                tkStart = regexp(kLine, 'startTime="PT([\d\.]+)S"', 'tokens', 'once');
                tkEnd = regexp(kLine, 'endTime="PT([\d\.]+)S"', 'tokens', 'once');
                if ~isempty(tkStart) && ~isempty(tkEnd)
                    tStartTime = tkStart{1};
                    tEndTime = tkEnd{1};
                    tFAN = [tFAN; str2double(tStartTime) str2double(tEndTime)]; 
                end
            end
            
            % ================= MALE ADULT NEAR =================
            if contains(kLine, 'spkr="MAN"')
                tkStart = regexp(kLine, 'startTime="PT([\d\.]+)S"', 'tokens', 'once');
                tkEnd = regexp(kLine, 'endTime="PT([\d\.]+)S"', 'tokens', 'once');
                if ~isempty(tkStart) && ~isempty(tkEnd)
                    tStartTime = tkStart{1};
                    tEndTime = tkEnd{1};
                    tMAN = [tMAN; str2double(tStartTime) str2double(tEndTime)];
                end
            end
        end
    end
end

function [dataF0c2f, dataF0c2m, dataF0c, dataF0f, dataF0m] = initialize_outputs_original(tCHN2FAN, tCHN2MAN, tCHN, tFAN, tMAN)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % INITIALIZE_OUTPUTS_ORIGINAL
    %
    % PURPOSE:
    % Initialize the output structure arrays for each talker category using
    % the same behavior as the original script.
    %
    % INPUT:
    %   tCHN2FAN, tCHN2MAN, tCHN, tFAN, tMAN = interval matrices
    %
    % OUTPUT:
    %   dataF0c2f, dataF0c2m, dataF0c, dataF0f, dataF0m
    %   = preallocated structure arrays
    %
    % NOTES:
    % - Empty interval arrays are replaced with 0 exactly as in the
    %   original code.
    % - Structures are preallocated by assigning the .fname field at the
    %   last index.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    
    clear dataF0c2f dataF0c2m dataF0c dataF0f dataF0m;

    if isempty(tCHN2FAN), tCHN2FAN = 0; end
    if isempty(tCHN2MAN), tCHN2MAN = 0; end
    if isempty(tCHN), tCHN = 0; end
    if isempty(tFAN), tFAN = 0; end
    if isempty(tMAN), tMAN = 0; end

    dataF0c2f(length(tCHN2FAN)).fname = [];
    dataF0c2m(length(tCHN2MAN)).fname = [];
    dataF0c(length(tCHN)).fname = [];
    dataF0f(length(tFAN)).fname = [];
    dataF0m(length(tMAN)).fname = [];
end

function dataOut = analyze_category_original(label, intervals, fname, F0MinMax, dataOut, currAge, subjName, rate, frame_length, TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames)
 %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ANALYZE_CATEGORY_ORIGINAL
    %
    % PURPOSE:
    % Run F0 analysis on all intervals for one category:
    %   C2F, C2M, C, F, or M
    %
    % INPUT:
    %   label       = short label used for progress printing
    %   intervals   = Nx2 matrix of start/end times
    %   fname       = ITS file name
    %   F0MinMax    = pitch search range for shrp
    %   dataOut     = preallocated output structure
    %   currAge     = age for this file
    %   subjName    = subject identifier
    %   rate, frame_length, TimeStep, SHR_Threshold, Ceiling,
    %   med_smooth, CHECK_VOICING = shrp parameters
    %
    % OUTPUT:
    %   dataOut = structure array filled with acoustic measurements
    %
    % NOTES:
    % - This preserves the original threshold logic:
    %     C2F and F require numel(intervals) > 4
    %     all other categories require numel(intervals) > 2
    % - Results are written into dataOut(q), not compacted.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

     
    if strcmp(label, 'C2F')
        doRun = numel(intervals) > 4;
    elseif strcmp(label, 'F')
        doRun = numel(intervals) > 4;
    else
        doRun = numel(intervals) > 2;
    end

    if ~doRun
        return;
    end

    for q = 1:length(intervals)
        row = analyze_interval_original_1based(intervals, q, fname, F0MinMax, rate, frame_length, TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
        %row = analyze_interval_original(intervals, q, fname, F0MinMax, rate, frame_length, TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

        if ~isempty(row)
            dataOut(q).age      = currAge;
            dataOut(q).subjName = subjName;
            dataOut(q).fname    = fname;
            dataOut(q).durUtt   = row.durUtt;
            dataOut(q).pctUttVx = row.pctUttVx;
            dataOut(q).f0mean   = row.f0mean;
            dataOut(q).f0std    = row.f0std;
            dataOut(q).f0min    = row.f0min;
            dataOut(q).f0max    = row.f0max;
            dataOut(q).dBFS     = row.dBFS;
        end
        disp(['working on ' label ' ' num2str(q) ' of ' num2str(length(intervals))]);
    end
end

function row = analyze_interval_original(intervals, q, fname, F0MinMax, rate, frame_length, TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ANALYZE_INTERVAL_ORIGINAL
    %
    % PURPOSE:
    % Analyze one utterance interval by:
    %   1) converting its start/end time to sample indices
    %   2) reading that audio segment from the WAV file
    %   3) running shrp pitch extraction
    %   4) computing basic acoustic summary values
    %
    % INPUT:
    %   intervals   = Nx2 matrix of intervals in seconds
    %   q           = current interval index
    %   fname       = ITS file name (used to derive WAV name)
    %   F0MinMax    = [min max] pitch range
    %   rate        = sampling rate
    %   frame_length, TimeStep, SHR_Threshold, Ceiling,
    %   med_smooth, CHECK_VOICING = shrp parameters
    %
    % OUTPUT:
    %   row = structure with fields:
    %         durUtt, pctUttVx, f0mean, f0std
    %         or empty [] if analysis is not valid
    %
    % NOTES:
    % - Original implementation using direct sample indexing.
    % - Uses 0-based style conversion from seconds to samples
    % - May produce invalid indices when start time = 0
    % - f0tNoZ is used the same way as in the original script to decide
    %   whether the utterance has enough voiced frames.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%    
    row = [];

    s1 = (intervals(q,1) * rate);
    s2 = (intervals(q,2) * rate);
    s1 = int64(s1); s1 = double(s1);
    s2 = int64(s2); s2 = double(s2);

    fnWav = [fname(1:end-3) 'wav'];
    cWav = audioread(fnWav, [s1 s2]);

    % Measurements that do not depend on successful pitch extraction.
    durUtt = (length(cWav) / rate) * 1000;
    rmsVal = rms(cWav);
    if rmsVal > 0
        dBFS = 20 * log10(rmsVal);
    else
        dBFS = -Inf;
    end
    sCount = estimate_syllables(cWav, rate);

    % Start with a valid non-F0 result. If shrp finds enough voiced frames,
    % the F0-dependent NaNs below are replaced with measurements.
    row = struct('durUtt', durUtt, ...
                 'pctUttVx', NaN, ...
                 'f0mean', NaN, ...
                 'f0std', NaN, ...
                 'f0min', NaN, ...
                 'f0max', NaN, ...
                 'f0range', NaN, ...
                 'dBFS', dBFS, ...
                 'syllableCount', sCount, ...
                 'syllablesPerSec', sCount / (durUtt/1000));

    [f0t, f0] = shrp(cWav, rate, F0MinMax, frame_length, ...
        TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING);

    [ii, jj, ~] = find(f0);
    f0tNoZ = zeros(1, length(jj));
    for kk = 1:length(jj)
        f0tNoZ(kk) = f0t(ii(kk));
    end

    if length(f0tNoZ) > 2
        fx = nonzeros(f0);
        if length(fx) > (2 * trimEdgeFrames)
            fx = fx((trimEdgeFrames + 1):(end - trimEdgeFrames));
        end

        if isempty(fx)
            return;
        end

        fmean = mean(fx);
        fstd  = std(fx);
        fmin  = min(fx);
        fmax  = max(fx);
        f0_range=fmax-fmin;
        durUtt = (length(cWav)/rate)*1000;
        durVx  = length(fx)*TimeStep;
        durPct = durVx / durUtt;

        rmsVal = rms(cWav);

        if rmsVal > 0
            dBFS = 20 * log10(rmsVal);
            dBSPL= dBFS + 97; % Convert dBFS to dBSPL using reference of 97 dB SPL at 0 dBFS
        else
            dBFS = -Inf;
        end

        sCount = estimate_syllables(cWav, rate);   
        row = struct('durUtt', durUtt, ...
                     'pctUttVx', durPct, ...
                     'f0mean', fmean, ...
                     'f0std', fstd, ...
                     'f0min', fmin, ...
                     'f0max', fmax, ...
                     'f0range', f0_range, ...
                     'dBFS', dBFS, ...
                     'dBSPL', dBSPL, ...
                     'syllableCount', sCount, ...
                     'syllablesPerSec', sCount / (durUtt/1000));


    end
end


function row = analyze_interval_original_1based(intervals, q, fname, F0MinMax,...
    rate, frame_length, TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames)

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ANALYZE_INTERVAL_ORIGINAL_1BASED
% Uses MATLAB 1-based indexing(not 0-based) (audioread uses 1-based sample indices)
% Updated implementation using proper MATLAB 1-based indexing.
%
% PURPOSE:
% Analyze one utterance interval using corrected MATLAB 1-based indexing:
%   1) converting start/end time(sec) to valid sample indices
%   2) read the corresponding audio segment from the WAV file
%   3) run shrp pitch extraction
%   4) computing basic acoustic summary values
%
% INPUT:
%   intervals   = Nx2 matrix of intervals in seconds
%   q           = current interval index
%   fname       = ITS file name (used to derive WAV name)
%   F0MinMax    = [min max] pitch range
%   rate        = sampling rate
%   frame_length, TimeStep, SHR_Threshold, Ceiling,
%   med_smooth, CHECK_VOICING = shrp parameters
%
% OUTPUT:
%   row = structure with fields:
%         durUtt, pctUttVx, f0mean, f0std
%         or empty [] if analysis is not valid
%
% IMPROVEMENTS:
% - Uses MATLAB 1-based indexing (first sample = 1,not 0)
% - Converts time (sec) to indices safely
% - Clamps indices within audio file boundaries
% - Prevents reading past file end uses audioinfo
% - skip and avoids invalid intervals before reading audio (e.g., start = 0, s2 <= s1)

% NOTES:
% - Uses audioinfo to prevent reading outside file limits
% - Maintains correct alignment with ITS time stamps
% - Recommended version for stable and accurate analysis
%
% USAGE:
% Can replace analyze_interval_original in the main workflow
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    row = [];

    fnWav = [fname(1:end-3) 'wav'];

    if ~exist(fnWav, 'file')
        return;
    end

    audioInfo = audioinfo(fnWav);
    totalSamples = audioInfo.TotalSamples;

    % Convert ITS times (sec) to MATLAB sample indices
    s1 = floor(intervals(q,1) * rate) + 1;
    s2 = floor(intervals(q,2) * rate);

    % Clamp indices to valid audio range
    s1 = max(1, s1);
    s2 = min(totalSamples, s2);

    % Skip invalid intervals
    if s2 <= s1
        return;
    end

    cWav = audioread(fnWav, [s1 s2]);

    % These measurements do not depend on successful pitch extraction.
    durUtt = (length(cWav) / rate) * 1000;
    rmsVal = rms(cWav);
    if rmsVal > 0
        dBFS = 20 * log10(rmsVal);
    else
        dBFS = -Inf;
    end
    sCount = estimate_syllables(cWav, rate);

    % Return non-F0 measurements even if shrp finds too little voicing.
    row = struct('durUtt', durUtt, ...
                 'pctUttVx', NaN, ...
                 'f0mean', NaN, ...
                 'f0std', NaN, ...
                 'f0min', NaN, ...
                 'f0max', NaN, ...
                 'f0range', NaN, ...
                 'dBFS', dBFS, ...
                 'syllableCount', sCount, ...
                 'syllablesPerSec', sCount / (durUtt/1000));

    [~, f0] = shrp(cWav, rate, F0MinMax, frame_length, ...
        TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING);

    fx = nonzeros(f0);
    if numel(fx) <= 2
        return;
    end

    % Remove unstable pitch estimates at the utterance edges.
    if numel(fx) > (2 * trimEdgeFrames)
        fx = fx((trimEdgeFrames + 1):(end - trimEdgeFrames));
    end
    if isempty(fx)
        return;
    end

    durVx = length(fx) * TimeStep;
    row.pctUttVx = durVx / durUtt;
    row.f0mean = mean(fx);
    row.f0std = std(fx);
    row.f0min = min(fx);
    row.f0max = max(fx);
    row.f0range = row.f0max - row.f0min;
   
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


function save_its_outputs(resultsFolder, subjName, fname, interactionResults, segmentTable, turnPairs, nameCorrespondencesFile)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% SAVE_ITS_OUTPUTS
%
% Save ITS/interaction classifier results only (no acoustic .mat files).
% CSV outputs: *_AICM_INTERACTIONS.csv (classified segments), *_AICM_INTERACTIONS_All_Segments.csv
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if nargin < 6
        turnPairs = table();
    end
    if nargin < 7
        nameCorrespondencesFile = '';
    end

    cd(resultsFolder);
    outputBaseName = build_output_base_name(subjName, fname);
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
        currentTable = readtable(csvPath, 'VariableNamingRule', 'preserve');
        if ismember('Date', currentTable.Properties.VariableNames) && ~isdatetime(currentTable.('Date'))
            dateText = string(currentTable.('Date'));
            parsedDates = NaT(size(dateText));
            isoMask = contains(dateText, '-');
            parsedDates(isoMask) = datetime(dateText(isoMask), 'InputFormat', 'yyyy-MM-dd');
            parsedDates(~isoMask) = datetime(dateText(~isoMask), 'InputFormat', 'M/d/yyyy');
            parsedDates.Format = 'M/d/yyyy';
            currentTable.('Date') = parsedDates;
        end
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


function eventTable = extract_aicm_event_table(matByLine)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % EXTRACT_AICM_EVENT_TABLE
    %
    % PURPOSE:
    % Build a row-wise event table of speaker events from each AICM conversation block.
    % One row corresponds to one CHN, FAN, or MAN segment.
    %
    % INPUT:
    %   matByLine = structure array containing ITS file lines
    %
    % OUTPUT:
    %   eventTable = table columns with speaker, startSec, endSec, and durationSec
    %
    % NOTES:
    % - Only CHN, FAN, and MAN segments are included
    % - A segment is included only if the immediately previous or next line in
    %   the conversation block is also CHN, FAN, or MAN (sequence order, not time)
    % - Events are extracted from AICM conversation blocks only
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    speakerList = {};
    startList = [];
    endList = [];
    durList = [];
    sourceIdxList = [];

    for k = 1:length(matByLine)
        if ~contains(matByLine(k).text, 'type="AICM"')
            continue;
        end

        cBlock = build_conversation_block(matByLine, k);

        for jj = 1:length(cBlock)
            kLine = cBlock(jj).text;
            [spkr, segStarts, segEnds] = parse_speaker_segments_from_line(kLine);

            if isempty(spkr)
                continue;
            end

            if ~has_aicm_line_neighbor_v3(cBlock, jj)
                continue;
            end

            for mm = 1:length(segStarts)
                speakerList{end+1,1} = spkr; %#ok<AGROW>
                startList(end+1,1) = segStarts(mm); %#ok<AGROW>
                endList(end+1,1) = segEnds(mm); %#ok<AGROW>
                durList(end+1,1) = segEnds(mm) - segStarts(mm); %#ok<AGROW>
                sourceIdxList(end+1,1) = k + jj; %#ok<AGROW>
            end
        end
    end

    if isempty(startList)
        eventTable = table(strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
            'VariableNames', {'speaker','startSec','endSec','durationSec','sourceIndex'});
        return;
    end

    eventTable = table(string(speakerList), startList, endList, durList, sourceIdxList, ...
        'VariableNames', {'speaker','startSec','endSec','durationSec','sourceIndex'});
    eventTable = sortrows(eventTable, {'startSec','endSec'});
end

function cBlock = build_conversation_block(matByLine, k)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % BUILD_CONVERSATION_BLOCK
    %
    % PURPOSE:
    % Return all lines belonging to one AICM conversation block.
    %
    % INPUT:
    %   matByLine = structure array containing ITS file lines
    %   k         = index of the current AICM conversation line
    %
    % OUTPUT:
    %   cBlock = structure array containing lines from one conversation block
    %
    % NOTES:
    % - Reading stops when </Conversation> is reached
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    kk = 0;
    cBlock = struct('text', {});
    while true
        kk = kk + 1;
        if (k + kk) > length(matByLine)
            break;
        end
        if contains(matByLine(k + kk).text, '</Conversation>')
            break;
        end
        cBlock(kk).text = matByLine(k + kk).text; %#ok<AGROW>
    end
end

function [spkr, segStarts, segEnds] = parse_speaker_segments_from_line(kLine)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % PARSE_SPEAKER_SEGMENTS_FROM_LINE
    %
    % PURPOSE:
    % Parse one ITS line and return speaker plus one or more segments.
    % CHN may contain multiple utterances on one line.
    % FAN and MAN usually contain one segment per line.
    %
    % INPUT:
    %   kLine = one line of ITS text
    %
    % OUTPUT:
    %   segTable = table of detected speaker segments with start/end times
    %
    % NOTES:
    % - Only CHN, FAN, and MAN segments are returned
    % - Child utterances may contain multiple utterance intervals
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    spkr = '';
    segStarts = [];
    segEnds = [];

    if contains(kLine, 'spkr="CHN"')
        spkr = 'CHN';
        uttCntIndx = regexpi(kLine, 'childUttCnt="', 'end');
        uttCnt = 0;
        if ~isempty(uttCntIndx)
            uttCntStr = regexp(kLine(uttCntIndx+1:end), '^\d+', 'match', 'once');
            if ~isempty(uttCntStr)
                uttCnt = str2double(uttCntStr);
            end
        end

        segStarts = zeros(1, uttCnt);
        segEnds = zeros(1, uttCnt);
        validCnt = 0;
        for m = 1:uttCnt
            tkStart = regexp(kLine, ['startUtt' num2str(m) '="PT([\d\.]+)S"'], 'tokens', 'once');
            tkEnd = regexp(kLine, ['endUtt' num2str(m) '="PT([\d\.]+)S"'], 'tokens', 'once');
            if isempty(tkStart) || isempty(tkEnd)
                continue;
            end
            validCnt = validCnt + 1;
            segStarts(validCnt) = str2double(tkStart{1});
            segEnds(validCnt) = str2double(tkEnd{1});
        end
        segStarts = segStarts(1:validCnt);
        segEnds = segEnds(1:validCnt);
        return;
    end

    if contains(kLine, 'spkr="FAN"')
        spkr = 'FAN';
    elseif contains(kLine, 'spkr="MAN"')
        spkr = 'MAN';
    else
        return;
    end

    tkStart = regexp(kLine, 'startTime="PT([\d\.]+)S"', 'tokens', 'once');
    tkEnd = regexp(kLine, 'endTime="PT([\d\.]+)S"', 'tokens', 'once');

    if isempty(tkStart) || isempty(tkEnd)
        spkr = '';
        return;
    end

    segStarts = str2double(tkStart{1});
    segEnds = str2double(tkEnd{1});
end

function interactionResults = classify_aicm_interactions(eventTable, adjacencyWindowSec)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % CLASSIFY_AICM_INTERACTIONS
    %
    % PURPOSE:
    % Assign directional labels such as:
    %   MANtoMAN, MANtoFAN, FANtoMAN, FANtoFAN,
    %   MANtoCHN, CHNtoMAN, FANtoCHN, CHNtoFAN
    %
    % INPUT:
    %   eventTable          = table of speaker events
    %   adjacencyWindowSec  = maximum allowed gap between adjacent events
    %
    % OUTPUT:
    %   interactionTable = table with speaker, timing, and classLabel
    %
    % NOTES:
    % - Original interaction classifier
    % - Uses simple adjacency rules
    % - A segment may receive more than one class label.
    % - Labels are assigned from adjacent events within adjacencyWindowSec.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if isempty(eventTable)
        interactionResults = table(strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), strings(0,1), ...
            zeros(0,1), zeros(0,1), zeros(0,1), ...
            'VariableNames', {'speaker','startSec','endSec','durationSec','classLabel', ...
            'prevGapSec','nextGapSec','eventIndex'});
        return;
    end

    outSpeaker = {};
    outStart = [];
    outEnd = [];
    outDur = [];
    outLabel = {};
    outPrevGap = [];
    outNextGap = [];
    outEventIdx = [];

    nEvents = height(eventTable);

    for q = 1:nEvents
        currSpeaker = char(eventTable.speaker(q));
        currStart = eventTable.startSec(q);
        currEnd = eventTable.endSec(q);
        currDur = eventTable.durationSec(q);

        prevIdx = q - 1;
        nextIdx = q + 1;

        hasPrev = prevIdx >= 1;
        hasNext = nextIdx <= nEvents;

        prevGap = NaN;
        nextGap = NaN;

        prevSpeaker = '';
        nextSpeaker = '';

        if hasPrev
            prevGap = currStart - eventTable.endSec(prevIdx);
            prevSpeaker = char(eventTable.speaker(prevIdx));
        end

        if hasNext
            nextGap = eventTable.startSec(nextIdx) - currEnd;
            nextSpeaker = char(eventTable.speaker(nextIdx));
        end

        labelList = {};

        if hasPrev && prevGap <= adjacencyWindowSec && prevGap >= 0
            prevLabel = build_directional_label(prevSpeaker, currSpeaker);
            if ~isempty(prevLabel) && is_supported_direction(prevLabel)
                labelList{end+1,1} = prevLabel; %#ok<AGROW>
            end
        end

        if hasNext && nextGap <= adjacencyWindowSec && nextGap >= 0
            nextLabel = build_directional_label(currSpeaker, nextSpeaker);
            if ~isempty(nextLabel) && is_supported_direction(nextLabel)
                labelList{end+1,1} = nextLabel; %#ok<AGROW>
            end
        end

        if isempty(labelList)
            continue;
        end

        labelList = unique(labelList, 'stable');
        for ll = 1:length(labelList)
            outSpeaker{end+1,1} = currSpeaker; %#ok<AGROW>
            outStart(end+1,1) = currStart; %#ok<AGROW>
            outEnd(end+1,1) = currEnd; %#ok<AGROW>
            outDur(end+1,1) = currDur; %#ok<AGROW>
            outLabel{end+1,1} = labelList{ll}; %#ok<AGROW>
            outPrevGap(end+1,1) = prevGap; %#ok<AGROW>
            outNextGap(end+1,1) = nextGap; %#ok<AGROW>
            outEventIdx(end+1,1) = q; %#ok<AGROW>
        end
    end

    interactionResults = table(string(outSpeaker), outStart, outEnd, outDur, string(outLabel), ...
        outPrevGap, outNextGap, outEventIdx, ...
        'VariableNames', {'speaker','startSec','endSec','durationSec','classLabel', ...
        'prevGapSec','nextGapSec','eventIndex'});
end



function interactionResults = classify_aicm_interactions_rules(eventTable, adjacencyWindowSec)


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% UPDATED VERSION OF CLASSIFY_AICM_INTERACTIONS 
% no preceding CHN / no following CHN logic
%
% PURPOSE:
% Updated interaction classifier to assign directional interaction labels (e.g., MANtoCHN, FANtoMAN) 
% using adjacency within a time window and the defined rules for adult-directed vs child-directed speech.
%
% INPUT:
%   eventTable          = table of speaker events
%   adjacencyWindowSec  = maximum allowed gap between adjacent events
%
% OUTPUT:
%   interactionTable = table with speaker, timing, and classLabel
%
% IMPROVEMENTS:
% - Preserves directionality
% - Applies "no preceding CHN" and "no following CHN" rules
% - Stores child-directed and adult-directed labels separately
%
% NOTE:
% Adult-directed labels are assigned only when the opposite side is not CHN,
% following this rule:
%   - no preceding CHN for forward adult-directed labels
%   - no following CHN for backward adult-directed labels
% Child-directed labels preserve directionality and are stored separately.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(eventTable)
        interactionResults = eventTable;
        interactionResults.classLabel = strings(0,1);
        return;
    end

    eventTable = sortrows(eventTable, 'startSec');

    allSpeaker = {};
    allStart = [];
    allEnd = [];
    allDur = [];
    allLabel = {};

    n = height(eventTable);

    for i = 1:n
        currSpeaker = string(eventTable.speaker(i));
        currStart   = eventTable.startSec(i);
        currEnd     = eventTable.endSec(i);
        currDur     = eventTable.durationSec(i);

        prevIdx = [];
        nextIdx = [];

        % nearest previous event within adjacency window
        if i > 1
            gapPrev = currStart - eventTable.endSec(i-1);
            if gapPrev >= 0 && gapPrev <= adjacencyWindowSec
                prevIdx = i - 1;
            end
        end

        % nearest next event within adjacency window
        if i < n
            gapNext = eventTable.startSec(i+1) - currEnd;
            if gapNext >= 0 && gapNext <= adjacencyWindowSec
                nextIdx = i + 1;
            end
        end

        prevSpeaker = "";
        nextSpeaker = "";

        if ~isempty(prevIdx)
            prevSpeaker = string(eventTable.speaker(prevIdx));
        end
        if ~isempty(nextIdx)
            nextSpeaker = string(eventTable.speaker(nextIdx));
        end

        labelsForCurrent = {};

        switch currSpeaker

            case "MAN"
                % Previous -> MAN
                if prevSpeaker == "MAN" && nextSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'MANtoMAN';
                end
                if prevSpeaker == "FAN" && nextSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'FANtoMAN';
                end
                if prevSpeaker == "CHN"
                    labelsForCurrent{end+1} = 'CHNtoMAN';
                end

                % MAN -> Next
                if nextSpeaker == "MAN" && prevSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'MANtoMAN';
                end
                if nextSpeaker == "FAN" && prevSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'MANtoFAN';
                end
                if nextSpeaker == "CHN"
                    labelsForCurrent{end+1} = 'MANtoCHN';
                end

            case "FAN"
                % Previous -> FAN
                if prevSpeaker == "MAN" && nextSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'MANtoFAN';
                end
                if prevSpeaker == "FAN" && nextSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'FANtoFAN';
                end
                if prevSpeaker == "CHN"
                    labelsForCurrent{end+1} = 'CHNtoFAN';
                end

                % FAN -> Next
                if nextSpeaker == "MAN" && prevSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'FANtoMAN';
                end
                if nextSpeaker == "FAN" && prevSpeaker ~= "CHN"
                    labelsForCurrent{end+1} = 'FANtoFAN';
                end
                if nextSpeaker == "CHN"
                    labelsForCurrent{end+1} = 'FANtoCHN';
                end

            case "CHN"
                if prevSpeaker == "MAN"
                    labelsForCurrent{end+1} = 'MANtoCHN';
                end
                if prevSpeaker == "FAN"
                    labelsForCurrent{end+1} = 'FANtoCHN';
                end
                if nextSpeaker == "MAN"
                    labelsForCurrent{end+1} = 'CHNtoMAN';
                end
                if nextSpeaker == "FAN"
                    labelsForCurrent{end+1} = 'CHNtoFAN';
                end
        end

        % remove duplicates
        if ~isempty(labelsForCurrent)
            labelsForCurrent = unique(labelsForCurrent, 'stable');

            for k = 1:numel(labelsForCurrent)
                allSpeaker{end+1,1} = char(currSpeaker);
                allStart(end+1,1) = currStart;
                allEnd(end+1,1) = currEnd;
                allDur(end+1,1) = currDur;
                allLabel{end+1,1} = labelsForCurrent{k};
            end
        end
    end

    interactionResults = table(allSpeaker, allStart, allEnd, allDur, allLabel, ...
        'VariableNames', {'speaker','startSec','endSec','durationSec','classLabel'});
end
function tf = is_supported_direction(classLabel)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% IS_SUPPORTED_DIRECTION
%
% PURPOSE:
% Check if a speaker pair forms a valid interaction type.
%
% INPUT:
%   fromSpeaker = previous or initiating speaker
%   toSpeaker   = following or target speaker
%
% OUTPUT:
%   tf = true if the speaker pair is supported, otherwise false
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    supported = {'MANtoMAN','MANtoFAN','FANtoMAN','FANtoFAN', ...
                 'MANtoCHN','CHNtoMAN','FANtoCHN','CHNtoFAN'};
    tf = any(strcmp(classLabel, supported));
end

function classLabel = build_directional_label(fromSpeaker, toSpeaker)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% BUILD_DIRECTIONAL_LABEL
%
% PURPOSE:
% Create a directional label string (e.g., "MANtoCHN") from two speakers.
%
% INPUT:
%   fromSpeaker = previous or initiating speaker
%   toSpeaker   = following or target speaker
%
% OUTPUT:
%   label = interaction label such as MANtoCHN or FANtoMAN
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if isempty(fromSpeaker) || isempty(toSpeaker)
        classLabel = '';
        return;
    end
    classLabel = [fromSpeaker 'to' toSpeaker];
end

function interactionResults = add_acoustics_to_interaction_table(interactionResults, fname, rate, frame_length, TimeStep, ...
    SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ADD_ACOUSTICS_TO_INTERACTION_TABLE
%
% PURPOSE:
% Compute acoustic features (F0 mean, min, max, std, dBFS)
% for each interaction segment and append them to the interaction table.
%
% INPUT:
%   interactionTable = table of classified interaction segments
%   fname            = ITS file name used to derive the WAV file name
%   rate             = sampling rate
%   frame_length, TimeStep, SHR_Threshold, Ceiling,
%   med_smooth, CHECK_VOICING = shrp parameters
%   trimEdgeFrames   = number of voiced F0 frames removed from each edge
%
% OUTPUT:
%   interactionTable = table with added acoustic measurements
%
% NOTES:
% - Computes F0 mean, min, max, std, and dBFS
% - Uses speaker-dependent F0 search ranges
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(interactionResults)
        interactionResults.f0mean = zeros(0,1);
        interactionResults.f0std = zeros(0,1);
        interactionResults.f0min = zeros(0,1);
        interactionResults.f0max = zeros(0,1);
        interactionResults.f0range = zeros(0,1);
        interactionResults.dBFS = zeros(0,1);
        interactionResults.pctUttVx = zeros(0,1);
        return;
    end

    nRows = height(interactionResults);
    f0mean = nan(nRows,1);
    f0std = nan(nRows,1);
    f0min = nan(nRows,1);
    f0max = nan(nRows,1);
    f0range = nan(nRows,1);
    dBFS = nan(nRows,1);
    pctUttVx = nan(nRows,1);

    intervals = [interactionResults.startSec interactionResults.endSec];

    for q = 1:nRows
        currSpeaker = char(interactionResults.speaker(q));
        F0MinMax = choose_f0_range(currSpeaker);
        row = analyze_interval_original_1based(intervals, q, fname, F0MinMax, rate, frame_length, ...
            TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
        
%         row = analyze_interval_original(intervals, q, fname, F0MinMax, rate, frame_length, ...
%             TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
        if isempty(row)
            continue;
        end

        f0mean(q) = row.f0mean;
        f0std(q) = row.f0std;
        f0min(q) = row.f0min;
        f0max(q) = row.f0max;
        f0range(q) = row.f0range;
        dBFS(q) = row.dBFS;
        pctUttVx(q) = row.pctUttVx;
    end

    interactionResults.f0mean = f0mean;
    interactionResults.f0std = f0std;
    interactionResults.f0min = f0min;
    interactionResults.f0max = f0max;
    interactionResults.f0range = f0range;
    interactionResults.dBFS = dBFS;
    interactionResults.pctUttVx = pctUttVx;
end

function segmentTable = add_acoustics_to_segment_table(segmentTable, fname, rate, frame_length, TimeStep, ...
    SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ADD_ACOUSTICS_TO_SEGMENT_TABLE
%
% Analyze every extracted AICM segment, whether classified or not.
% Non-pitch measurements (dBFS and syllables) are retained even when shrp
% cannot produce enough voiced F0 frames.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    acousticNames = {'f0mean','f0std','f0min','f0max','f0range','dBFS', ...
        'pctUttVx','syllableCount','syllablesPerSec'};

    if isempty(segmentTable)
        for k = 1:numel(acousticNames)
            segmentTable.(acousticNames{k}) = zeros(0,1);
        end
        return;
    end

    nRows = height(segmentTable);
    values = nan(nRows, numel(acousticNames));
    intervals = [segmentTable.startSec segmentTable.endSec];

    for q = 1:nRows
        F0MinMax = choose_f0_range(char(segmentTable.speaker(q)));
        row = analyze_interval_original_1based(intervals, q, fname, F0MinMax, rate, frame_length, ...
            TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
        if isempty(row)
            continue;
        end

        for k = 1:numel(acousticNames)
            values(q,k) = row.(acousticNames{k});
        end
    end

    for k = 1:numel(acousticNames)
        segmentTable.(acousticNames{k}) = values(:,k);
    end
end

function interactionResults = sync_acoustics_from_segment_table(segmentTable, interactionResults)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Copy all acoustic measurements from the complete segment table into
% the classified interaction rows without analyzing the WAV twice.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    acousticNames = {'f0mean','f0std','f0min','f0max','f0range','dBFS', ...
        'pctUttVx','syllableCount','syllablesPerSec'};

    if isempty(interactionResults)
        for k = 1:numel(acousticNames)
            interactionResults.(acousticNames{k}) = zeros(0,1);
        end
        return;
    end

    values = nan(height(interactionResults), numel(acousticNames));
    for q = 1:height(interactionResults)
        segIdx = find_segment_row_v3(segmentTable, ...
            interactionResults.conversationId(q), interactionResults.segmentIndex(q));
        if isempty(segIdx)
            continue;
        end
        for k = 1:numel(acousticNames)
            values(q,k) = segmentTable.(acousticNames{k})(segIdx);
        end
    end

    for k = 1:numel(acousticNames)
        interactionResults.(acousticNames{k}) = values(:,k);
    end
end

function segmentTable = add_syllables_to_segment_table(segmentTable, fname, rate)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ADD_SYLLABLES_TO_SEGMENT_TABLE
%
% Compute syllableCount and syllablesPerSec for every segment in
% segmentTable (initiators and responders alike).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(segmentTable)
        return;
    end

    nRows = height(segmentTable);
    syllableCount = nan(nRows, 1);
    syllablesPerSec = nan(nRows, 1);

    fnWav = [fname(1:end-3) 'wav'];
    if ~exist(fnWav, 'file')
        segmentTable.syllableCount = syllableCount;
        segmentTable.syllablesPerSec = syllablesPerSec;
        return;
    end

    audioInfo = audioinfo(fnWav);
    totalSamples = audioInfo.TotalSamples;

    for q = 1:nRows
        s1 = floor(segmentTable.startSec(q) * rate) + 1;
        s2 = floor(segmentTable.endSec(q) * rate);
        s1 = max(1, s1);
        s2 = min(totalSamples, s2);
        if s2 <= s1
            continue;
        end

        cWav = audioread(fnWav, [s1 s2]);
        sCount = estimate_syllables(cWav, rate);
        syllableCount(q) = sCount;
        durSec = length(cWav) / rate;
        if durSec > 0
            syllablesPerSec(q) = sCount / durSec;
        end
    end

    segmentTable.syllableCount = syllableCount;
    segmentTable.syllablesPerSec = syllablesPerSec;
end

function interactionResults = sync_syllables_from_segment_table(segmentTable, interactionResults)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Copy syllable metrics from segmentTable into interactionResults rows.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(interactionResults) || isempty(segmentTable) || ...
            ~ismember('syllableCount', segmentTable.Properties.VariableNames)
        return;
    end

    syllableCount = nan(height(interactionResults), 1);
    syllablesPerSec = nan(height(interactionResults), 1);

    for q = 1:height(interactionResults)
        segIdx = find_segment_row_v3(segmentTable, ...
            interactionResults.conversationId(q), interactionResults.segmentIndex(q));
        if isempty(segIdx)
            continue;
        end
        syllableCount(q) = segmentTable.syllableCount(segIdx);
        syllablesPerSec(q) = segmentTable.syllablesPerSec(segIdx);
    end

    interactionResults.syllableCount = syllableCount;
    interactionResults.syllablesPerSec = syllablesPerSec;
end

function F0MinMax = choose_f0_range(speakerLabel)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% CHOOSE_F0_RANGE
%
% PURPOSE:
% Select appropriate F0 search range based on speaker type.
%
% INPUT:
%   speaker = speaker label (CHN, FAN, or MAN)
%
% OUTPUT:
%   F0MinMax = [min max] pitch search range
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    switch upper(speakerLabel)
        case 'CHN'
            F0MinMax = [100 600];  % typical CHN  [100 600], but can be adjusted if needed [200 600]
        case 'FAN'
            F0MinMax = [100 600];    % typical FAN adult [100 600], but can be adjusted if needed [120 400]
        case 'MAN'
            F0MinMax = [50 300];     % typical MAN adult [50 300], but can be adjusted if needed [50 250]
        otherwise
            F0MinMax = [50 600];    % typical but can be adjusted if needed
    end
end


function run_evaluation_visualization_light(interactionResults, resultsFolder, baseName)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% RUN_EVALUATION_VISUALIZATION_LIGHT
%
% PURPOSE:
% Lightweight evaluation for loop usage:
% - saves plots instead of displaying
% - avoids opening many figures
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(interactionResults)
        return;
    end

    validRows = ~ismissing(interactionResults.classLabel) & interactionResults.classLabel ~= "";
    resultsEval = interactionResults(validRows, :);

    if isempty(resultsEval)
        return;
    end

    adsLabels = ["MANtoMAN","MANtoFAN","FANtoMAN","FANtoFAN"];
    cdsLabels = ["MANtoCHN","CHNtoMAN","FANtoCHN","CHNtoFAN"];

    resultsEval.speechType = strings(height(resultsEval),1);
    resultsEval.speechType(ismember(resultsEval.classLabel, adsLabels)) = "ADS";
    resultsEval.speechType(ismember(resultsEval.classLabel, cdsLabels)) = "CDS";

    %% ---- Counts ----
    labelCounts = groupcounts(resultsEval, 'classLabel');
    labelCounts.Properties.VariableNames{'GroupCount'} = 'Count';
    
    speechTypeCounts = groupcounts(resultsEval, 'speechType');
    speechTypeCounts.Properties.VariableNames{'GroupCount'} = 'Count';
    
    %% ---- Combined Summary File with Percentages ----
    totalCount = sum(labelCounts.Count);
    
    % Create summaryType column for speechType
    speechTypeSummary = table(repmat("SpeechType", height(speechTypeCounts), 1), ...
        speechTypeCounts.speechType, speechTypeCounts.Count, ...
        (speechTypeCounts.Count / totalCount * 100), ...
        'VariableNames', {'summaryType', 'category', 'count', 'percentage'});
    
    % Create summaryType column for classLabel
    labelSummary = table(repmat("InteractionLabel", height(labelCounts), 1), ...
        labelCounts.classLabel, labelCounts.Count, ...
        (labelCounts.Count / totalCount * 100), ...
        'VariableNames', {'summaryType', 'category', 'count', 'percentage'});
    
    % Combine both summaries
    combinedSummary = [speechTypeSummary; labelSummary];
    writetable(combinedSummary, fullfile(resultsFolder, [baseName '_speechType_label_summary.csv']));

    %% ---- Plot: label counts ----
    fig = figure('Visible','off');
    bar(categorical(labelCounts.classLabel), labelCounts.Count);
    title('Interaction Counts');
    saveas(fig, fullfile(resultsFolder, [baseName '_counts.png']));
    close(fig);


    %% ---- Plot: ADS vs CDS ----
    fig = figure('Visible','off');
    bar(categorical(speechTypeCounts.speechType), speechTypeCounts.Count);
    title('ADS vs CDS');
    saveas(fig, fullfile(resultsFolder, [baseName '_ads_cds.png']));
    close(fig);

    %% ---- Plot: F0 mean (audio only) ----
    if ismember('f0mean', resultsEval.Properties.VariableNames)
        validF0 = ~isnan(resultsEval.f0mean);
        if any(validF0)
            fig = figure('Visible','off');
            boxchart(categorical(resultsEval.classLabel(validF0)), resultsEval.f0mean(validF0));
            xlabel('Interaction Label');
            ylabel('F0 Mean (Hz)');
            title('F0 Mean');
            saveas(fig, fullfile(resultsFolder, [baseName '_f0mean.png']));
            close(fig);
        end
    end

    % validF0 = ~isnan(resultsEval.f0mean);
    % if any(validF0)
    %     f0ByLabel = groupsummary(resultsEval(validF0,:), 'classLabel', 'mean', 'f0mean');
    % 
    %     fig = figure('Visible','off');
    %     bar(categorical(f0ByLabel.classLabel), f0ByLabel.mean_f0mean);
    %     xlabel('Interaction Label');
    %     ylabel('Mean F0 (Hz)');
    %     title('Mean F0 by Interaction Label');
    %     grid on;
    %     saveas(fig, fullfile(resultsFolder, [baseName '_f0mean.png']));
    %     close(fig);
    % end
    %% ---- Plot: dBFS (audio only) ----
    if ismember('dBFS', resultsEval.Properties.VariableNames)
        validDb = ~isnan(resultsEval.dBFS) & ~isinf(resultsEval.dBFS);
        if any(validDb)
            fig = figure('Visible','off');
            boxchart(categorical(resultsEval.classLabel(validDb)), resultsEval.dBFS(validDb));
            xlabel('Interaction Label');
            ylabel('dBFS');
            title('dBFS');
            saveas(fig, fullfile(resultsFolder, [baseName '_dbfs.png']));
            close(fig);
        end
    end
    % validDb = ~isnan(resultsEval.dBFS) & ~isinf(resultsEval.dBFS);
    % if any(validDb)
    %     dbByLabel = groupsummary(resultsEval(validDb,:), 'classLabel', 'mean', 'dBFS');
    % 
    %     fig = figure('Visible','off');
    %     bar(categorical(dbByLabel.classLabel), dbByLabel.mean_dBFS);
    %     xlabel('Interaction Label');
    %     ylabel('Mean dBFS');
    %     title('Mean dBFS by Interaction Label');
    %     grid on;
    %     saveas(fig, fullfile(resultsFolder, [baseName '_dbfs.png']));
    %     close(fig);
    % end
end

function compare_classifiers_light(segmentTable, turnPairs, interactionResults, resultsFolder, baseName, params)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% COMPARE_CLASSIFIERS_LIGHT
%
% PURPOSE:
% Compare v3 turn-pair classifier vs legacy simple/rules classifiers.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(segmentTable)
        return;
    end

    allLabels = ["MANtoMAN","MANtoFAN","FANtoMAN","FANtoFAN", ...
                 "MANtoCHN","CHNtoMAN","FANtoCHN","CHNtoFAN"];

    v3Counts = zeros(numel(allLabels), 1);
    if ~isempty(turnPairs) && height(turnPairs) > 0
        for i = 1:numel(allLabels)
            v3Counts(i) = sum(strcmp(turnPairs.classLabel, allLabels(i)));
        end
    end

    legacySegmentTable = table( ...
        segmentTable.speaker, segmentTable.startSec, segmentTable.endSec, segmentTable.durationSec, ...
        'VariableNames', {'speaker','startSec','endSec','durationSec'});

    results_simple = classify_aicm_interactions(legacySegmentTable, params.adjacencyWindowSec);
    results_rules  = classify_aicm_interactions_rules(legacySegmentTable, params.adjacencyWindowSec);

    valid_simple = ~ismissing(results_simple.classLabel) & results_simple.classLabel ~= "";
    valid_rules  = ~ismissing(results_rules.classLabel)  & results_rules.classLabel  ~= "";
    results_simple = results_simple(valid_simple, :);
    results_rules  = results_rules(valid_rules, :);

    simpleCounts = zeros(numel(allLabels), 1);
    rulesCounts  = zeros(numel(allLabels), 1);
    for i = 1:numel(allLabels)
        simpleCounts(i) = sum(results_simple.classLabel == allLabels(i));
        rulesCounts(i)  = sum(results_rules.classLabel  == allLabels(i));
    end

    segmentCounts = zeros(numel(allLabels), 1);
    if ~isempty(interactionResults) && height(interactionResults) > 0
        for i = 1:numel(allLabels)
            segmentCounts(i) = sum(interactionResults.classLabel == allLabels(i));
        end
    end

    labelCompare = table(allLabels', v3Counts, segmentCounts, simpleCounts, rulesCounts, ...
        'VariableNames', {'classLabel','V3TurnPairCount','V3SegmentCount','SimpleCount','RulesCount'});

    writetable(labelCompare, fullfile(resultsFolder, [baseName '_classifier_compare.csv']));

    fig = figure('Visible', 'off');
    bar(categorical(labelCompare.classLabel), ...
        [labelCompare.V3TurnPairCount labelCompare.RulesCount labelCompare.SimpleCount]);
    legend('V3 Turn-Pairs', 'Rules (legacy)', 'Simple (legacy)');
    title('Classifier Comparison');
    saveas(fig, fullfile(resultsFolder, [baseName '_classifier_compare.png']));
    close(fig);
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
    dBFSs = nan(nSegments, 1);
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
        dBFSs(i) = tableColOrNan(segmentTable, i, 'dBFS');
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
        f0means, f0stds, f0mins, f0maxs, f0ranges, dBFSs, pctUttVxs, syllableCounts, syllablesPerSecs, ...
        sourceLineIndices, ...
        'VariableNames', { ...
            'conversationId','speaker','startSec','endSec','isValidSpeech','WordCount','durationSec', ...
            'classLabel','fromSpeaker','gapSec','speechType', ...
            'f0mean','f0std','f0min','f0max','f0range','dBFS','pctUttVx','syllableCount','syllablesPerSec', ...
            'sourceLineIndex'});

    allSegmentsTable = sortrows(allSegmentsTable, {'conversationId','startSec','endSec'});
end

function allSegmentsTable = empty_all_segments_table_v3()
    allSegmentsTable = table( ...
        zeros(0,1), strings(0,1), zeros(0,1), zeros(0,1), false(0,1), zeros(0,1), zeros(0,1), ...
        strings(0,1), strings(0,1), zeros(0,1), strings(0,1), ...
        zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        zeros(0,1), ...
        'VariableNames', { ...
            'conversationId','speaker','startSec','endSec','isValidSpeech','WordCount','durationSec', ...
            'classLabel','fromSpeaker','gapSec','speechType', ...
            'f0mean','f0std','f0min','f0max','f0range','dBFS','pctUttVx','syllableCount','syllablesPerSec', ...
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
        'gapSec','speechType','f0mean','f0std','f0min','f0max','f0range', ...
        'dBFS','pctUttVx','syllableCount','syllablesPerSec'};

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
        zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        'VariableNames', { ...
            'conversationId','speaker','classLabel','startSec','endSec', ...
            'gapSec','speechType','f0mean','f0std','f0min','f0max','f0range', ...
            'dBFS','pctUttVx','syllableCount','syllablesPerSec'});
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

%% ======================== V3 INTERACTION CLASSIFIER ====================

function [segmentTable, interactionResults, turnPairs] = run_interaction_pipeline_v3(matByLine, params)
% RUN_INTERACTION_PIPELINE_V3
% Orchestrates v3 extraction, turn-pair classification, and segment-level output.

    if nargin < 2 || isempty(params)
        params = default_interaction_params_v3();
    end

    segmentTable = extract_aicm_segment_table_v3(matByLine, params);
    turnPairs = classify_aicm_turn_pairs_v3(segmentTable, params);
    interactionResults = turn_pairs_to_segment_table_v3(turnPairs, segmentTable, params);
end

function params = default_interaction_params_v3()
% DEFAULT_INTERACTION_PARAMS_V3 — tunable v3 classifier parameters.

    params = struct();
    params.adjacencyWindowSec = 5.0;
    params.minDurationSec = 0.10;
    params.requireSpeechEvidence = true;
    params.preferLENATurnCodes = true;
    params.useAdjacencyFallback = true;
    params.applyNoChnBetweenRule = true;
    params.segmentPrimaryLabelOnly = true;
    params.requireAicmLineNeighbor = true;
    params.supportedLabels = {'MANtoMAN','MANtoFAN','FANtoMAN','FANtoFAN', ...
                              'MANtoCHN','CHNtoMAN','FANtoCHN','CHNtoFAN'};
end

function segmentTable = extract_aicm_segment_table_v3(matByLine, params)
% EXTRACT_AICM_SEGMENT_TABLE_V3
% Per-conversation segment extraction with LENA metadata and speech validity.
% CHN/FAN/MAN lines are kept only when an immediate line neighbor is also
% CHN, FAN, or MAN (see requireAicmLineNeighbor).

    if nargin < 2 || isempty(params)
        params = default_interaction_params_v3();
    end
    requireLineNeighbor = true;
    if isfield(params, 'requireAicmLineNeighbor')
        requireLineNeighbor = logical(params.requireAicmLineNeighbor);
    end

    speakerList = {};
    startList = [];
    endList = [];
    durList = [];
    convIdList = [];
    segmentIdxList = [];
    segRoleList = {};
    turnCodeList = {};
    endCodeList = {};
    childUttCntList = [];
    adultWordCntList = [];
    isValidList = [];
    sourceLineList = [];

    for k = 1:length(matByLine)
        lineText = matByLine(k).text;
        if ~contains(lineText, 'type="AICM"')
            continue;
        end

        conversationId = parse_conversation_num_from_header_v3(lineText);
        cBlock = build_conversation_block(matByLine, k);
        segmentCounter = 0;

        for jj = 1:length(cBlock)
            kLine = cBlock(jj).text;
            segInfo = parse_speaker_segment_line_v3(kLine);

            if isempty(segInfo.speaker)
                continue;
            end

            if requireLineNeighbor && ~has_aicm_line_neighbor_v3(cBlock, jj)
                continue;
            end

            for mm = 1:length(segInfo.starts)
                segmentCounter = segmentCounter + 1;
                segStart = segInfo.starts(mm);
                segEnd = segInfo.ends(mm);
                segDur = segEnd - segStart;
                isValid = is_valid_speech_segment_v3(segInfo, mm, segDur, params);

                speakerList{end+1,1} = segInfo.speaker; %#ok<AGROW>
                startList(end+1,1) = segStart; %#ok<AGROW>
                endList(end+1,1) = segEnd; %#ok<AGROW>
                durList(end+1,1) = segDur; %#ok<AGROW>
                convIdList(end+1,1) = conversationId; %#ok<AGROW>
                segmentIdxList(end+1,1) = segmentCounter; %#ok<AGROW>
                segRoleList{end+1,1} = segInfo.segmentRole; %#ok<AGROW>
                turnCodeList{end+1,1} = segInfo.turnCode; %#ok<AGROW>
                endCodeList{end+1,1} = segInfo.endCode; %#ok<AGROW>
                childUttCntList(end+1,1) = segInfo.childUttCnt; %#ok<AGROW>
                adultWordCntList(end+1,1) = segInfo.adultWordCnt; %#ok<AGROW>
                isValidList(end+1,1) = isValid; %#ok<AGROW>
                sourceLineList(end+1,1) = k + jj; %#ok<AGROW>
            end
        end
    end

    if isempty(startList)
        segmentTable = empty_segment_table_v3();
        return;
    end

    segmentTable = table( ...
        string(speakerList), startList, endList, durList, convIdList, segmentIdxList, ...
        string(segRoleList), string(turnCodeList), string(endCodeList), ...
        childUttCntList, adultWordCntList, logical(isValidList), sourceLineList, ...
        'VariableNames', { ...
            'speaker','startSec','endSec','durationSec','conversationId','segmentIndex', ...
            'segmentRole','turnCode','endCode','childUttCnt','adultWordCnt', ...
            'isValidSpeech','sourceLineIndex'});

    segmentTable = sortrows(segmentTable, {'conversationId','startSec','endSec'});
end

function tf = is_aicm_target_speaker_v3(spkr)
% True for CHN, FAN, or MAN speaker labels.
    tf = any(strcmp(spkr, {'CHN', 'FAN', 'MAN'}));
end

function spkr = parse_speaker_label_from_line_v3(kLine)
% Parse spkr="..." from any ITS segment line (any speaker type).
    spkr = '';
    tok = regexp(kLine, 'spkr="([A-Z]+)"', 'tokens', 'once');
    if ~isempty(tok)
        spkr = tok{1};
    end
end

function hasNeighbor = has_aicm_line_neighbor_v3(cBlock, lineIdx)
% True when the immediately previous or next line in the conversation block
% has speaker CHN, FAN, or MAN. Non-target speakers (OLF, SIL, FAF, ...) break
% the chain even if their timestamps fall within adjacencyWindowSec.
    hasNeighbor = false;
    if lineIdx > 1
        prevSpkr = parse_speaker_label_from_line_v3(cBlock(lineIdx - 1).text);
        if is_aicm_target_speaker_v3(prevSpkr)
            hasNeighbor = true;
        end
    end
    if lineIdx < length(cBlock)
        nextSpkr = parse_speaker_label_from_line_v3(cBlock(lineIdx + 1).text);
        if is_aicm_target_speaker_v3(nextSpkr)
            hasNeighbor = true;
        end
    end
end

function conversationId = parse_conversation_num_from_header_v3(lineText)
    conversationId = NaN;
    tok = regexp(lineText, 'num="(\d+)"', 'tokens', 'once');
    if ~isempty(tok)
        conversationId = str2double(tok{1});
    end
end

function segInfo = parse_speaker_segment_line_v3(kLine)
    segInfo = struct( ...
        'speaker', '', 'starts', [], 'ends', [], ...
        'segmentRole', '', 'turnCode', '', 'endCode', '', ...
        'childUttCnt', 0, 'adultWordCnt', 0);

    ciTok = regexp(kLine, 'conversationInfo="\|([^"]+)"', 'tokens', 'once');
    if ~isempty(ciTok)
        parts = strsplit(ciTok{1}, '|');
        if numel(parts) >= 7
            segInfo.segmentRole = parts{2};
            segInfo.turnCode = parts{6};
            segInfo.endCode = parts{7};
        end
    end

    if contains(kLine, 'spkr="CHN"')
        segInfo.speaker = 'CHN';
        uttCntIndx = regexpi(kLine, 'childUttCnt="', 'end');
        uttCnt = 0;
        if ~isempty(uttCntIndx)
            uttCntStr = regexp(kLine(uttCntIndx+1:end), '^\d+', 'match', 'once');
            if ~isempty(uttCntStr)
                uttCnt = str2double(uttCntStr);
            end
        end
        segInfo.childUttCnt = uttCnt;

        validCnt = 0;
        segStarts = zeros(1, uttCnt);
        segEnds = zeros(1, uttCnt);
        for m = 1:uttCnt
            tkStart = regexp(kLine, ['startUtt' num2str(m) '="PT([\d\.]+)S"'], 'tokens', 'once');
            tkEnd = regexp(kLine, ['endUtt' num2str(m) '="PT([\d\.]+)S"'], 'tokens', 'once');
            if isempty(tkStart) || isempty(tkEnd)
                continue;
            end
            validCnt = validCnt + 1;
            segStarts(validCnt) = str2double(tkStart{1});
            segEnds(validCnt) = str2double(tkEnd{1});
        end
        segInfo.starts = segStarts(1:validCnt);
        segInfo.ends = segEnds(1:validCnt);
        return;
    end

    if contains(kLine, 'spkr="FAN"')
        segInfo.speaker = 'FAN';
        segInfo.adultWordCnt = parse_numeric_attribute_v3(kLine, 'femaleAdultWordCnt');
    elseif contains(kLine, 'spkr="MAN"')
        segInfo.speaker = 'MAN';
        segInfo.adultWordCnt = parse_numeric_attribute_v3(kLine, 'maleAdultWordCnt');
    else
        return;
    end

    tkStart = regexp(kLine, 'startTime="PT([\d\.]+)S"', 'tokens', 'once');
    tkEnd = regexp(kLine, 'endTime="PT([\d\.]+)S"', 'tokens', 'once');
    if isempty(tkStart) || isempty(tkEnd)
        segInfo.speaker = '';
        return;
    end

    segInfo.starts = str2double(tkStart{1});
    segInfo.ends = str2double(tkEnd{1});
end

function val = parse_numeric_attribute_v3(kLine, attrName)
    val = 0;
    pat = [attrName '="([\d\.]+)"'];
    tok = regexp(kLine, pat, 'tokens', 'once');
    if ~isempty(tok)
        val = str2double(tok{1});
    end
end

function isValid = is_valid_speech_segment_v3(segInfo, ~, durationSec, params)
    isValid = durationSec >= params.minDurationSec;
    if ~isValid || ~params.requireSpeechEvidence
        return;
    end

    switch segInfo.speaker
        case 'CHN'
            isValid = segInfo.childUttCnt > 0;
        case {'FAN', 'MAN'}
            hasTurnCode = ~isempty(segInfo.turnCode) && ~strcmp(segInfo.turnCode, 'NT');
            isValid = (segInfo.adultWordCnt > 0) || hasTurnCode;
        otherwise
            isValid = false;
    end
end

function segmentTable = empty_segment_table_v3()
    segmentTable = table( ...
        strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        strings(0,1), strings(0,1), strings(0,1), zeros(0,1), zeros(0,1), ...
        false(0,1), zeros(0,1), ...
        'VariableNames', { ...
            'speaker','startSec','endSec','durationSec','conversationId','segmentIndex', ...
            'segmentRole','turnCode','endCode','childUttCnt','adultWordCnt', ...
            'isValidSpeech','sourceLineIndex'});
end

function turnPairs = classify_aicm_turn_pairs_v3(segmentTable, params)
    if isempty(segmentTable) || height(segmentTable) == 0
        turnPairs = empty_turn_pairs_table_v3();
        return;
    end

    rows = struct( ...
        'conversationId', {}, 'fromSpeaker', {}, 'toSpeaker', {}, ...
        'classLabel', {}, 'gapSec', {}, 'labelSource', {}, ...
        'fromStartSec', {}, 'fromEndSec', {}, 'toStartSec', {}, 'toEndSec', {}, ...
        'fromSegmentIndex', {}, 'toSegmentIndex', {}, ...
        'fromTurnCode', {}, 'toTurnCode', {}, 'speechType', {});

    convIds = unique(segmentTable.conversationId);
    for c = 1:length(convIds)
        convId = convIds(c);
        blockSegments = segmentTable(segmentTable.conversationId == convId, :);
        blockSegments = sortrows(blockSegments, {'startSec','endSec'});
        blockSegments = blockSegments(blockSegments.isValidSpeech, :);

        if height(blockSegments) < 2
            continue;
        end

        blockPairs = find_turn_pairs_in_block_v3(blockSegments, params);
        rows = [rows, blockPairs]; %#ok<AGROW>
    end

    if isempty(rows)
        turnPairs = empty_turn_pairs_table_v3();
        return;
    end

    turnPairs = struct2table(rows);
    % struct2table stores scalar character fields as character vectors when
    % there is exactly one turn pair. Normalize every text field to an Nx1
    % string column so table(...) never interprets values such as 'MAN' as
    % parameter names.
    turnPairs = normalize_turn_pair_text_columns_v3(turnPairs);
    turnPairs = deduplicate_turn_pairs_v3(turnPairs);
    turnPairs = sortrows(turnPairs, {'conversationId','fromStartSec','toStartSec'});
end

function turnPairs = normalize_turn_pair_text_columns_v3(turnPairs)
    textVariables = {'fromSpeaker','toSpeaker','classLabel','labelSource', ...
        'fromTurnCode','toTurnCode','speechType'};

    for v = 1:numel(textVariables)
        varName = textVariables{v};
        normalizedValues = string(turnPairs.(varName));
        turnPairs.(varName) = reshape(normalizedValues, [], 1);
    end
end

function blockPairs = find_turn_pairs_in_block_v3(blockSegments, params)
    blockPairs = struct( ...
        'conversationId', {}, 'fromSpeaker', {}, 'toSpeaker', {}, ...
        'classLabel', {}, 'gapSec', {}, 'labelSource', {}, ...
        'fromStartSec', {}, 'fromEndSec', {}, 'toStartSec', {}, 'toEndSec', {}, ...
        'fromSegmentIndex', {}, 'toSegmentIndex', {}, ...
        'fromTurnCode', {}, 'toTurnCode', {}, 'speechType', {});

    n = height(blockSegments);
    windowSec = params.adjacencyWindowSec;
    for j = 2:n
        segmentB = blockSegments(j, :);
        [nearestIdx, gapSec] = find_nearest_prior_segment_v3(blockSegments, j, windowSec);

        if isempty(nearestIdx)
            continue;
        end

        segmentA = blockSegments(nearestIdx, :);
        if gapSec > windowSec
            continue;
        end

        [classLabel, labelSource] = assign_pair_label_v3(segmentA, segmentB, params);
        if isempty(classLabel)
            continue;
        end

        if params.applyNoChnBetweenRule && is_ads_label_v3(classLabel)
            if has_chn_between_segments_v3(blockSegments, nearestIdx, j)
                continue;
            end
        end

        speechType = label_to_speech_type_v3(classLabel);

        newRow = struct( ...
            'conversationId', segmentA.conversationId, ...
            'fromSpeaker', char(segmentA.speaker), ...
            'toSpeaker', char(segmentB.speaker), ...
            'classLabel', classLabel, ...
            'gapSec', gapSec, ...
            'labelSource', labelSource, ...
            'fromStartSec', segmentA.startSec, ...
            'fromEndSec', segmentA.endSec, ...
            'toStartSec', segmentB.startSec, ...
            'toEndSec', segmentB.endSec, ...
            'fromSegmentIndex', segmentA.segmentIndex, ...
            'toSegmentIndex', segmentB.segmentIndex, ...
            'fromTurnCode', char(segmentA.turnCode), ...
            'toTurnCode', char(segmentB.turnCode), ...
            'speechType', speechType);

        blockPairs(end+1) = newRow; %#ok<AGROW>
    end
end

function [classLabel, labelSource] = assign_pair_label_v3(segmentA, segmentB, params)
    classLabel = '';
    labelSource = '';
    spA = char(segmentA.speaker);
    spB = char(segmentB.speaker);

    if params.preferLENATurnCodes
        lenaLabel = map_turn_code_to_label_v3(char(segmentB.turnCode), spA, spB);
        if ~isempty(lenaLabel) && is_supported_label_v3(lenaLabel, params)
            classLabel = lenaLabel;
            labelSource = 'LENA_target';
            return;
        end
    end

    if params.preferLENATurnCodes
        lenaLabel = map_turn_code_to_label_v3(char(segmentA.turnCode), spA, spB);
        if ~isempty(lenaLabel) && is_supported_label_v3(lenaLabel, params)
            classLabel = lenaLabel;
            labelSource = 'LENA_source';
            return;
        end
    end

    if params.useAdjacencyFallback
        adjLabel = build_directional_label_v3(spA, spB);
        if is_supported_label_v3(adjLabel, params)
            classLabel = adjLabel;
            labelSource = 'adjacency';
        end
    end
end

function classLabel = map_turn_code_to_label_v3(turnCode, fromSpeaker, toSpeaker)
    classLabel = '';
    if isempty(turnCode) || strcmp(turnCode, 'NT')
        return;
    end

    switch turnCode
        case 'TIMR'
            if strcmp(toSpeaker, 'CHN')
                classLabel = 'MANtoCHN';
            elseif strcmp(fromSpeaker, 'MAN') && strcmp(toSpeaker, 'CHN')
                classLabel = 'MANtoCHN';
            end
        case 'TIFR'
            if strcmp(toSpeaker, 'CHN')
                classLabel = 'FANtoCHN';
            elseif strcmp(fromSpeaker, 'FAN') && strcmp(toSpeaker, 'CHN')
                classLabel = 'FANtoCHN';
            end
        case 'TIMI'
            if strcmp(fromSpeaker, 'MAN')
                classLabel = build_directional_label_v3(fromSpeaker, toSpeaker);
            end
        case {'TIFI', 'TIFE'}
            if strcmp(fromSpeaker, 'FAN')
                classLabel = build_directional_label_v3(fromSpeaker, toSpeaker);
            end
        otherwise
            classLabel = '';
    end

    if ~isempty(classLabel)
        expected = build_directional_label_v3(fromSpeaker, toSpeaker);
        if ~strcmp(classLabel, expected) && ~isempty(expected)
            cdsCodes = {'TIMR', 'TIFR'};
            if ~any(strcmp(turnCode, cdsCodes))
                classLabel = expected;
            end
        end
    end
end

function classLabel = build_directional_label_v3(fromSpeaker, toSpeaker)
    if isempty(fromSpeaker) || isempty(toSpeaker)
        classLabel = '';
        return;
    end
    classLabel = [fromSpeaker 'to' toSpeaker];
end

function tf = is_supported_label_v3(classLabel, params)
    tf = any(strcmp(classLabel, params.supportedLabels));
end

function tf = is_ads_label_v3(classLabel)
    adsLabels = {'MANtoMAN','MANtoFAN','FANtoMAN','FANtoFAN'};
    tf = any(strcmp(classLabel, adsLabels));
end

function speechType = label_to_speech_type_v3(classLabel)
    if is_ads_label_v3(classLabel)
        speechType = 'ADS';
    else
        speechType = 'CDS';
    end
end

function tf = has_chn_between_segments_v3(blockSegments, idxA, idxB)
    tf = false;
    if idxB <= idxA + 1
        return;
    end
    betweenSpeakers = blockSegments.speaker(idxA+1 : idxB-1);
    tf = any(strcmp(betweenSpeakers, 'CHN'));
end

function turnPairs = deduplicate_turn_pairs_v3(turnPairs)
    if isempty(turnPairs)
        return;
    end

    keys = strcat( ...
        string(turnPairs.conversationId), '|', ...
        string(turnPairs.fromSegmentIndex), '|', ...
        string(turnPairs.toSegmentIndex), '|', ...
        string(turnPairs.classLabel));

    [~, ~, ic] = unique(keys, 'stable');
    keepMask = false(height(turnPairs), 1);

    for k = 1:max(ic)
        groupIdx = find(ic == k);
        [~, bestLocal] = min(turnPairs.gapSec(groupIdx));
        keepMask(groupIdx(bestLocal)) = true;
    end

    turnPairs = turnPairs(keepMask, :);
end

function turnPairs = empty_turn_pairs_table_v3()
    turnPairs = table( ...
        zeros(0,1), strings(0,1), strings(0,1), strings(0,1), zeros(0,1), ...
        strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        zeros(0,1), zeros(0,1), strings(0,1), strings(0,1), strings(0,1), ...
        'VariableNames', { ...
            'conversationId','fromSpeaker','toSpeaker','classLabel','gapSec', ...
            'labelSource','fromStartSec','fromEndSec', ...
            'toStartSec','toEndSec','fromSegmentIndex','toSegmentIndex', ...
            'fromTurnCode','toTurnCode','speechType'});
end

function interactionResults = turn_pairs_to_segment_table_v3(turnPairs, ~, params)
    if isempty(turnPairs) || height(turnPairs) == 0
        interactionResults = empty_interaction_results_table_v3();
        return;
    end

    varNames = { ...
        'speaker','startSec','endSec','durationSec','classLabel', ...
        'gapSec','labelSource','conversationId', ...
        'segmentIndex','speechType'};

    fromRows = table( ...
        string(turnPairs.fromSpeaker), turnPairs.fromStartSec, turnPairs.fromEndSec, ...
        turnPairs.fromEndSec - turnPairs.fromStartSec, string(turnPairs.classLabel), ...
        turnPairs.gapSec, string(turnPairs.labelSource), ...
        turnPairs.conversationId, turnPairs.fromSegmentIndex, string(turnPairs.speechType), ...
        'VariableNames', varNames);

    toRows = table( ...
        string(turnPairs.toSpeaker), turnPairs.toStartSec, turnPairs.toEndSec, ...
        turnPairs.toEndSec - turnPairs.toStartSec, string(turnPairs.classLabel), ...
        turnPairs.gapSec, string(turnPairs.labelSource), ...
        turnPairs.conversationId, turnPairs.toSegmentIndex, string(turnPairs.speechType), ...
        'VariableNames', varNames);

    interactionResults = [fromRows; toRows];

    if params.segmentPrimaryLabelOnly
        interactionResults = keep_primary_label_per_segment_v3(interactionResults);
    end

    interactionResults = sortrows(interactionResults, {'conversationId','startSec','endSec'});
end

function tbl = keep_primary_label_per_segment_v3(tbl)
    keys = strcat(string(tbl.conversationId), '|', string(tbl.segmentIndex));
    [~, ~, ic] = unique(keys, 'stable');
    keepMask = false(height(tbl), 1);

    for k = 1:max(ic)
        groupIdx = find(ic == k);
        [~, bestLocal] = min(tbl.gapSec(groupIdx));
        keepMask(groupIdx(bestLocal)) = true;
    end

    tbl = tbl(keepMask, :);
end

function interactionResults = empty_interaction_results_table_v3()
    interactionResults = table( ...
        cell(0,1), zeros(0,1), zeros(0,1), zeros(0,1), cell(0,1), ...
        zeros(0,1), cell(0,1), zeros(0,1), zeros(0,1), cell(0,1), ...
        'VariableNames', { ...
            'speaker','startSec','endSec','durationSec','classLabel', ...
            'gapSec','labelSource','conversationId', ...
            'segmentIndex','speechType'});
end

function [nearestIdx, gapSec] = find_nearest_prior_segment_v3(blockSegments, currentIdx, maxGapSec)
    nearestIdx = [];
    gapSec = NaN;

    for i = (currentIdx - 1):-1:1
        g = blockSegments.startSec(currentIdx) - blockSegments.endSec(i);
        if g < 0
            continue;
        end
        if g <= maxGapSec
            nearestIdx = i;
            gapSec = g;
            return;
        else
            break;
        end
    end
end

function syllableCount = estimate_syllables(signal, fs)
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ESTIMATE_SYLLABLES
    %
    % PURPOSE:
    % Detects syllable nuclei based on intensity peaks in the amplitude 
    % envelope to estimate syllables-per-utterance.
    % It uses a Bandpass filter (0.3–5 kHz) to focus on the frequency range 
    % where vowel energy is strongest and then identifies peaks in the smoothed envelope
    %
    % INPUT:
    %   signal = numeric audio data (WAV segment)
    %   fs     = sampling rate (typically 16000)
    %
    % OUTPUT:
    %   syllableCount = estimated number of syllables in the segment
    %
    % NOTES:
    % - Uses a Bandpass filter (300-4000 Hz) to target vowel energy
    % - Employs the Hilbert transform for envelope extraction 
    % - Peak detection requires -20dB height and 100ms separation 
    % - Optimized for the rhythmic properties of child and adult speech 
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %The Syllable Counting Function
    %Add this helper function to the bottom of your script. It uses a Bandpass filter (0.3–5 kHz) to focus on the frequency range where vowel energy is strongest and then identifies peaks in the smoothed envelope.
    % estimate_syllables: Detects syllable nuclei based on intensity peaks.
    % Based on De Jong & Wempe (2009) logic for "off-the-shelf" estimation.
   
    % Basic validation: If segment is extremely short, return 0 or 1
    if isempty(signal) || length(signal) < 0.05 * fs
        syllableCount = 0;
        return;
    end

    % 1. Filter signal to the vowel-heavy range (approx 300 - 4000 Hz)
    [b, a] = butter(4, [300 4000] / (fs/2), 'bandpass');
    filteredSignal = filtfilt(b, a, signal);

    % 2. Extract Amplitude Envelope (Hilbert transform + Smoothing)
    envelope = abs(hilbert(filteredSignal));
    
    % Smooth the envelope with a 20ms window (standard for speech syllables)
    windowSize = round(0.020 * fs); 
    smoothedEnv = conv(envelope, ones(windowSize,1)/windowSize, 'same');

    % 3. Convert to Relative dB scale for peak finding
    envDB = 20 * log10(smoothedEnv + eps);
    envDB = envDB - max(envDB); % Normalize so peak is 0dB
    
    % 4. Robust Peak Detection
    len = length(envDB);
    % Minimum distance between peaks: ~100ms (standard syllable rate)
    % Min peak height: -20dB below the maximum intensity in the utterance
    desiredMinPeakDistance = round(0.1 * fs);  % 100ms separation
    
    % If the signal is too short for 100ms distance, use a smaller distance
    % or calculate the max possible distance (length - 1)
    if len <= desiredMinPeakDistance
        % Fallback for tiny segments: simply count if there's any audible energy
        % If it's too short for findpeaks, we estimate it as 1 syllable 
        % provided it met the initial 20ms length check.
        syllableCount = 1;
    else
        % Ensure MinPeakDistance is strictly less than signal length
        actualMinPeakDistance = min(desiredMinPeakDistance, len - 1);
        
        [peaks, ~] = findpeaks(envDB, 'MinPeakDistance', actualMinPeakDistance, 'MinPeakHeight', -20);
        syllableCount = length(peaks);
    end
end

function val = tableColOrNan(tbl, rowIdx, colName)
    if ismember(colName, tbl.Properties.VariableNames)
        val = tbl.(colName)(rowIdx);
    else
        val = NaN;
    end
end

 

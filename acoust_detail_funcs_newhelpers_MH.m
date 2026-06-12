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
% 6) Build AICM event table (speaker, start, end)
% 7) Classify directional interactions:
%       MANtoMAN, MANtoFAN, FANtoMAN, FANtoFAN
%       MANtoCHN, CHNtoMAN, FANtoCHN, CHNtoFAN
% 8) Run F0 extraction using shrp.m
% 9) Compute acoustic features:
%       F0 mean, F0 min, F0 max, F0 std, dBFS
% 10) Save results into .mat and .csv files
%%%
%%% NOTES:
% - Interaction classification is based on adjacency (within 2 seconds)
% - Directionality is preserved (e.g., MAN→CHN ≠ CHN→MAN)
% - A segment may belong to multiple interaction types
%%%
%%% Mark VanDam, Jan. 2013
%%% Updated: Mohamed A. Hanafy, March 2026
%%% Updates_2: Mohamed A. Hanafy, April 2026 (interaction classification + acoustic features)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% add the explanation for every column name  in th readme 

clear;
tic

ages = [2.53 2.41 2.59 2.36 2.37 2.72 2.10 2.41 2.35 2.23 ...
    2.39 2.63 2.53 2.42 2.44 2.41 2.24 2.94 2.29 2.45 2.49 2.46];

%% ================= USER INPUT- Folder Selection Tool =================
% Manually enter the base directory where ITS files are stored
baseDir = 'D:\OneDrive - University of Louisville\LENA_Project\scripts\script_MH\rawData'; % Specify your rawData folder here
% baseDir = input('\n\n\n\n   Enter directory where ITS files are stored: ', 's');  % Input the base directory

% % Folder Selection Tool 
% % printf('--- Action Required ---\n');
% fprintf('A window will now open. Please browse to and select your "ITS" folder.\n\n');
% baseDir = uigetdir('D:\LENA_Project', 'Select the rawData folder');
% if isequal(baseDir, 0)
%     error('User cancelled folder selection.');
% else
%     disp(['Folder selected: ', baseDir]);
% end

%% ================= PARAMETERS =================
rate = 16000;
frame_length = 20;
TimeStep = 3;
SHR_Threshold = 0.4;
Ceiling = 1250;
med_smooth = 0;
CHECK_VOICING = 1;
adjacencyWindowSec = 5;
trimEdgeFrames = 2;

%% ================= SETUP =================
scriptPath = fileparts(mfilename('fullpath'));
addpath(scriptPath);

if exist('shrp', 'file') ~= 2
    error('shrp.m not found on MATLAB path. Add shrp.m to the script folder or MATLAB path.');
end

%% ================= FIND FILES =================
allItsFiles = dir(fullfile(baseDir, '**', '*.its'));
if isempty(allItsFiles)
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
for ik = 2:2    %for ik = 1:numel(allItsFiles)
    currDir = allItsFiles(ik).folder;
    fname = allItsFiles(ik).name;

    cd(currDir)
    fprintf('\n---------------------------------------------------\n');
    fprintf('Working on ITS file %d of %d\n', ik, numel(allItsFiles));
    disp(['Working on file: ' fname ' in directory: ' currDir]);

    [subjName, matByLine] = read_its_file_original(fname);

    [tCHN, tCHN2FAN, tCHN2MAN, tFAN, tMAN] = parse_intervals_original(matByLine);
    eventTable = extract_aicm_event_table(matByLine);
    % NOTE:
        % Two versions of interval analysis are available:
        % 1) analyze_interval_original           -> original indexing
        % 2) analyze_interval_original_1based    -> corrected indexing (recommended)
        %
        % Change the function call inside analyze_category_original if needed.
    
   % NOTE:
        % Two versions of the interaction classifier are available:
        % 1) classify_aicm_interactions           -> original (simple adjacency)
        % 2) classify_aicm_interactions_rules     -> updated (New rules)
        %
        % Change the function call below depending on which version you want to use.
   % interactionResults = classify_aicm_interactions(eventTable, adjacencyWindowSec);
    interactionResults = classify_aicm_interactions_rules(eventTable, adjacencyWindowSec);
    %% -------- RESET ARRAYS --------
    clear matByLine;
    disp(['tCHN= ' num2str(length(tCHN)) '  tFAN= ' num2str(length(tFAN)), ...
        'tMAN= ' num2str(length(tMAN))])

    [dataF0c2f, dataF0c2m, dataF0c, dataF0f, dataF0m] = initialize_outputs_original( ...
        tCHN2FAN, tCHN2MAN, tCHN, tFAN, tMAN);

    dataF0c2f = analyze_category_original('C2F', tCHN2FAN, fname, [200 600], ...
        dataF0c2f, ages(ik), subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0c2m = analyze_category_original('C2M', tCHN2MAN, fname, [200 600], ...
        dataF0c2m, ages(ik), subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0c = analyze_category_original('C', tCHN, fname, [200 600], ...
        dataF0c, ages(ik), subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0f = analyze_category_original('F', tFAN, fname, [120 400], ...
        dataF0f, ages(ik), subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    dataF0m = analyze_category_original('M', tMAN, fname, [50 250], ...
        dataF0m, ages(ik), subjName, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

    interactionResults = add_acoustics_to_interaction_table(interactionResults, fname, rate, frame_length, TimeStep, ...
        SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
    
    save_outputs_original(resultsFolder, subjName, fname, dataF0c, dataF0c2f, dataF0c2m, dataF0f, dataF0m, interactionResults, eventTable);
    baseName = [subjName '_' fname(1:end-4)];

    run_evaluation_visualization_light(interactionResults, resultsFolder, baseName);
    % Optional comparison
    compare_both_classifiers_light(eventTable, resultsFolder, baseName, adjacencyWindowSec);
    disp(' ');
    disp('Done.');
    disp(['file: ' subjName '_' fname(1:end-4) ', here: ' resultsFolder])
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
        row = analyze_interval_original(intervals, q, fname, F0MinMax, rate, frame_length, TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
        %row = analyze_interval_original_1based(intervals, q, fname, F0MinMax, rate, frame_length, TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);

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
        % -------------------------------------
    
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

    [f0t, f0] = shrp(cWav, rate, F0MinMax, frame_length, ...
        TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING);

    fx = nonzeros(f0);
    
    % Requirement check (Check valid data)

    if numel(fx) <= 2
        return;
    end
    
   
    % Clean data (trim edges)
    % cut out the first and last few milliseconds of values in every F0 vector 
    % since it could introduce error
    % Because:
    % - At the start of an utterance → unstable pitch detection
    % - At the end → fading / noise / voicing errors
    if numel(fx) > (2 * trimEdgeFrames)
        fx = fx((trimEdgeFrames + 1):(end - trimEdgeFrames));
    end
    
    if isempty(fx)
        return;
    end   

    % Only continue if we have at least 3 voiced F0 values
    fmean = mean(fx);
    fstd  = std(fx);
    durUtt = (length(cWav)/rate)*1000;
    durVx  = length(fx)*TimeStep;
    durPct = durVx / durUtt;
    fmin = min(fx);
    fmax = max(fx);
    f0_range = fmax - fmin;
    
    rmsVal = rms(cWav);
    if rmsVal > 0
        dBFS = 20 * log10(rmsVal);
    else
        dBFS = -Inf;
    end
    
    % --- SYLLABLE CALCULATION ---
    sCount = estimate_syllables(cWav, rate);
    % -------------------------------------
    
    row = struct('durUtt', durUtt, ...
                 'pctUttVx', durPct, ...
                 'f0mean', fmean, ...
                 'f0std', fstd, ...
                 'f0min', fmin, ...
                 'f0max', fmax, ...
                 'f0range', f0_range, ...
                 'dBFS', dBFS, ...
                 'syllableCount', sCount, ...
                 'syllablesPerSec', sCount / (durUtt/1000));
   
end

function save_outputs_original(resultsFolder, subjName, fname, dataF0c, dataF0c2f, dataF0c2m, dataF0f, dataF0m, interactionResults, eventTable)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
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
    save([subjName '_' fname(1:end-4) '_CHN'], 'dataF0c');
    save([subjName '_' fname(1:end-4) '_CHN2FAN'], 'dataF0c2f');
    save([subjName '_' fname(1:end-4) '_CHN2MAN'], 'dataF0c2m');
    save([subjName '_' fname(1:end-4) '_FAN'], 'dataF0f');
    save([subjName '_' fname(1:end-4) '_MAN'], 'dataF0m');
    save([subjName '_' fname(1:end-4) '_AICM_INTERACTIONS'], 'interactionResults', 'eventTable');

    % Create unified detail table combining both interactions and events
    unifiedDetailTable = create_unified_detail_table(eventTable, interactionResults);
    writetable(unifiedDetailTable, [subjName '_' fname(1:end-4) '_AICM_INTERACTIONS_Events.csv']);
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
    % Add new preallocated arrays for syllables
    syllableCount = nan(nRows,1); 
    syllablesPerSec = nan(nRows,1);

    for q = 1:nRows
        currSpeaker = char(interactionResults.speaker(q));
        F0MinMax = choose_f0_range(currSpeaker); 
        % read the audio segment to use it for syllables
        s1 = floor(intervals(q,1) * rate) + 1;
        s2 = floor(intervals(q,2) * rate);
        fnWav = [fname(1:end-3) 'wav'];
        cWav = audioread(fnWav, [s1 s2]);

        % 2. run syllable and F0 analysis
        sCount = estimate_syllables(cWav, rate);
        syllableCount(q) = sCount;
        syllablesPerSec(q) = sCount / (length(cWav)/rate);
        row = analyze_interval_original(intervals, q, fname, F0MinMax, rate, frame_length, ...
            TimeStep, SHR_Threshold, Ceiling, med_smooth, CHECK_VOICING, trimEdgeFrames);
        
%         row = analyze_interval_original_1based(intervals, q, fname, F0MinMax, rate, frame_length, ...
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

    %% ---- Plot: F0 mean ----
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
    %% ---- Plot: dBFS ----
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

function compare_both_classifiers_light(eventTable, resultsFolder, baseName, adjacencyWindowSec)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% COMPARE_BOTH_CLASSIFIERS_LIGHT
%
% PURPOSE:
% Compare simple vs rules classifier (lightweight, loop-safe)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(eventTable)
        return;
    end

    results_simple = classify_aicm_interactions(eventTable, adjacencyWindowSec);
    results_rules  = classify_aicm_interactions_rules(eventTable, adjacencyWindowSec);

    valid_simple = ~ismissing(results_simple.classLabel) & results_simple.classLabel ~= "";
    valid_rules  = ~ismissing(results_rules.classLabel)  & results_rules.classLabel  ~= "";

    results_simple = results_simple(valid_simple,:);
    results_rules  = results_rules(valid_rules,:);

    allLabels = ["MANtoMAN","MANtoFAN","FANtoMAN","FANtoFAN", ...
                 "MANtoCHN","CHNtoMAN","FANtoCHN","CHNtoFAN"];

    simpleCounts = zeros(numel(allLabels),1);
    rulesCounts  = zeros(numel(allLabels),1);

    for i = 1:numel(allLabels)
        simpleCounts(i) = sum(results_simple.classLabel == allLabels(i));
        rulesCounts(i)  = sum(results_rules.classLabel  == allLabels(i));
    end

    labelCompare = table(allLabels', simpleCounts, rulesCounts, ...
        'VariableNames', {'classLabel','SimpleCount','RulesCount'});

    writetable(labelCompare, fullfile(resultsFolder, [baseName '_classifier_compare.csv']));

    %% ---- Plot ----
    fig = figure('Visible','off');
    bar(categorical(labelCompare.classLabel), ...
        [labelCompare.SimpleCount labelCompare.RulesCount]);
    legend('Simple','Rules');
    title('Classifier Comparison');
    saveas(fig, fullfile(resultsFolder, [baseName '_classifier_compare.png']));
    close(fig);
end

function unifiedTable = create_unified_detail_table(eventTable, interactionResults)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% CREATE_UNIFIED_DETAIL_TABLE
%
% PURPOSE:
% Combine eventTable and interactionResults into a single unified detail table
% with a dataType column indicating whether each row is a RawEvent or ClassifiedInteraction.
%
% INPUT:
%   eventTable         = table of raw speaker events
%   interactionResults = table of classified interactions with acoustic features
%
% OUTPUT:
%   unifiedTable = table with all events and interactions combined
%
% NOTES:
% - Raw events show only speaker, timing, and sourceIndex
% - Classified interactions include acoustic features (f0mean, f0std, etc.)
% - Empty cells indicate missing data for that row type
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    if isempty(eventTable) && isempty(interactionResults)
        unifiedTable = table(strings(0,1), strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
            strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
            'VariableNames', {'dataType','speaker','startSec','endSec','durationSec','classLabel','f0mean','f0std','f0min','f0max','f0range','dBFS','pctUttVx','syllableCount','syllablesPerSec','sourceIndex'});
        return;
    end

    % Initialize output arrays
    dataTypes = {};
    speakers = {};
    startSecs = [];
    endSecs = [];
    durationSecs = [];
    classLabels = {};
    f0means = [];
    f0stds = [];
    f0mins = [];
    f0maxs = [];
    f0ranges = [];
    dBFSs = [];
    pctUttVxs = [];
    syllableCounts = [];
    syllablesPerSecs = [];
    sourceIndices = [];

    % Add raw events from eventTable
    if ~isempty(eventTable)
        nEvents = height(eventTable);
        for i = 1:nEvents
            dataTypes{end+1,1} = 'RawEvent'; %#ok<AGROW>
            speakers{end+1,1} = char(eventTable.speaker(i)); %#ok<AGROW>
            startSecs(end+1,1) = eventTable.startSec(i); %#ok<AGROW>
            endSecs(end+1,1) = eventTable.endSec(i); %#ok<AGROW>
            durationSecs(end+1,1) = eventTable.durationSec(i); %#ok<AGROW>
            classLabels{end+1,1} = ''; %#ok<AGROW>
            f0means(end+1,1) = NaN; %#ok<AGROW>
            f0stds(end+1,1) = NaN; %#ok<AGROW>
            f0mins(end+1,1) = NaN; %#ok<AGROW>
            f0maxs(end+1,1) = NaN; %#ok<AGROW>
            f0ranges(end+1,1) = NaN; %#ok<AGROW>
            dBFSs(end+1,1) = NaN; %#ok<AGROW>
            pctUttVxs(end+1,1) = NaN; %#ok<AGROW>
            syllableCounts(end+1,1) = NaN; %#ok<AGROW>
            syllablesPerSecs(end+1,1) = NaN; %#ok<AGROW>
            sourceIndices(end+1,1) = eventTable.sourceIndex(i); %#ok<AGROW>
        end
    end

    % Add classified interactions from interactionResults
    if ~isempty(interactionResults)
        nInteractions = height(interactionResults);
        for i = 1:nInteractions
            dataTypes{end+1,1} = 'ClassifiedInteraction'; %#ok<AGROW>
            speakers{end+1,1} = char(interactionResults.speaker(i)); %#ok<AGROW>
            startSecs(end+1,1) = interactionResults.startSec(i); %#ok<AGROW>
            endSecs(end+1,1) = interactionResults.endSec(i); %#ok<AGROW>
            durationSecs(end+1,1) = interactionResults.durationSec(i); %#ok<AGROW>
            classLabels{end+1,1} = char(interactionResults.classLabel(i)); %#ok<AGROW>
            f0means(end+1,1) = interactionResults.f0mean(i); %#ok<AGROW>
            f0stds(end+1,1) = interactionResults.f0std(i); %#ok<AGROW>
            f0mins(end+1,1) = interactionResults.f0min(i); %#ok<AGROW>
            f0maxs(end+1,1) = interactionResults.f0max(i); %#ok<AGROW>
            f0ranges(end+1,1) = interactionResults.f0range(i); %#ok<AGROW>
            dBFSs(end+1,1) = interactionResults.dBFS(i); %#ok<AGROW>
            pctUttVxs(end+1,1) = interactionResults.pctUttVx(i); %#ok<AGROW>
            syllableCounts(end+1,1) = interactionResults.syllableCount(i); %#ok<AGROW>
            syllablesPerSecs(end+1,1) = interactionResults.syllablesPerSec(i); %#ok<AGROW>
            sourceIndices(end+1,1) = NaN; %#ok<AGROW>
        end
    end

    % Create unified table
    unifiedTable = table(string(dataTypes), string(speakers), startSecs, endSecs, durationSecs, ...
        string(classLabels), f0means, f0stds, f0mins, f0maxs, f0ranges, dBFSs, pctUttVxs, syllableCounts, syllablesPerSecs, sourceIndices, ...
        'VariableNames', {'dataType','speaker','startSec','endSec','durationSec','classLabel','f0mean','f0std','f0min','f0max','f0range','dBFS','pctUttVx','syllableCount','syllablesPerSec','sourceIndex'});

    % Sort by time for readability
    unifiedTable = sortrows(unifiedTable, {'startSec','endSec'});
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

 
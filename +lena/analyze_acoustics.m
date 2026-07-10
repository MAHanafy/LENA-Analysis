function result = analyze_acoustics(result, cfg)
%ANALYZE_ACOUSTICS Run the unchanged acoustic feature algorithms.

[dataF0c2f, dataF0c2m, dataF0c, dataF0f, dataF0m] = initialize_outputs_original( ...
    result.tCHN2FAN, result.tCHN2MAN, result.tCHN, result.tFAN, result.tMAN);

dataF0c2f = analyze_category_original('C2F', result.tCHN2FAN, result.fname, [200 600], ...
    dataF0c2f, result.age, result.subjectName, cfg.rate, cfg.frame_length, cfg.TimeStep, ...
    cfg.SHR_Threshold, cfg.Ceiling, cfg.med_smooth, cfg.CHECK_VOICING, cfg.trimEdgeFrames);

dataF0c2m = analyze_category_original('C2M', result.tCHN2MAN, result.fname, [200 600], ...
    dataF0c2m, result.age, result.subjectName, cfg.rate, cfg.frame_length, cfg.TimeStep, ...
    cfg.SHR_Threshold, cfg.Ceiling, cfg.med_smooth, cfg.CHECK_VOICING, cfg.trimEdgeFrames);

dataF0c = analyze_category_original('C', result.tCHN, result.fname, [200 600], ...
    dataF0c, result.age, result.subjectName, cfg.rate, cfg.frame_length, cfg.TimeStep, ...
    cfg.SHR_Threshold, cfg.Ceiling, cfg.med_smooth, cfg.CHECK_VOICING, cfg.trimEdgeFrames);

dataF0f = analyze_category_original('F', result.tFAN, result.fname, [120 400], ...
    dataF0f, result.age, result.subjectName, cfg.rate, cfg.frame_length, cfg.TimeStep, ...
    cfg.SHR_Threshold, cfg.Ceiling, cfg.med_smooth, cfg.CHECK_VOICING, cfg.trimEdgeFrames);

dataF0m = analyze_category_original('M', result.tMAN, result.fname, [50 250], ...
    dataF0m, result.age, result.subjectName, cfg.rate, cfg.frame_length, cfg.TimeStep, ...
    cfg.SHR_Threshold, cfg.Ceiling, cfg.med_smooth, cfg.CHECK_VOICING, cfg.trimEdgeFrames);

result.segmentTable = add_acoustics_to_segment_table(result.segmentTable, result.fname, ...
    cfg.rate, cfg.frame_length, cfg.TimeStep, cfg.SHR_Threshold, cfg.Ceiling, ...
    cfg.med_smooth, cfg.CHECK_VOICING, cfg.trimEdgeFrames);
result.interactionResults = sync_acoustics_from_segment_table( ...
    result.segmentTable, result.interactionResults);

result.dataF0c2f = dataF0c2f;
result.dataF0c2m = dataF0c2m;
result.dataF0c = dataF0c;
result.dataF0f = dataF0f;
result.dataF0m = dataF0m;
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


function fig = visualize_aicm_stream(aicmEventsFile, varargin)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% VISUALIZE_AICM_STREAM
%
% Plot AICM speaker timing on a streaming audio waveform.
%
% Vertical triggers (time axis = horizontal):
%   S_M / E_M  - Male adult (MAN) start / end
%   S_F / E_F  - Female adult (FAN) start / end
%   S_C / E_C  - Child (CHN) start / end
%
% Colors:
%   All start triggers (S_*)     -> green
%   All end triggers   (E_*)     -> blue
%   Interaction class labels     -> red
%
% INPUT:
%   aicmEventsFile - path to *_AICM_EVENTS.csv (or *_AICM_INTERACTIONS.mat)
%
% Name-value options:
%   'InteractionsFile' - *_AICM_INTERACTIONS.csv (default: sibling file)
%   'WavFile'          - paired .wav path (default: auto-detect from base name)
%   'TimeRange'        - [tStart tEnd] seconds (default: event span + padding)
%   'ConversationId'   - zoom to one AICM block (overrides TimeRange)
%   'SavePath'         - save figure to PNG path
%   'Visible'          - true/false (default true)
%
% EXAMPLE:
%   visualize_aicm_stream('results_20260618/.../file_AICM_EVENTS.csv');
%   visualize_aicm_stream(eventsCsv, 'ConversationId', 377, 'WavFile', 'path/to/file.wav');
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    p = inputParser;
    addRequired(p, 'aicmEventsFile', @(x) ischar(x) || isstring(x));
    addParameter(p, 'InteractionsFile', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'WavFile', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'TimeRange', [], @(x) isempty(x) || (isnumeric(x) && numel(x) == 2));
    addParameter(p, 'ConversationId', [], @(x) isempty(x) || isnumeric(x));
    addParameter(p, 'SavePath', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'Visible', true, @islogical);
    parse(p, aicmEventsFile, varargin{:});
    opts = p.Results;

    aicmEventsFile = char(aicmEventsFile);
    [eventTable, interactionsTable, baseName, resultsFolder] = load_aicm_tables(aicmEventsFile, char(opts.InteractionsFile));

    if ~isempty(opts.ConversationId)
        convId = opts.ConversationId;
        eventTable = eventTable(eventTable.conversationId == convId, :);
        if ~isempty(interactionsTable) && ismember('conversationId', interactionsTable.Properties.VariableNames)
            interactionsTable = interactionsTable(interactionsTable.conversationId == convId, :);
        end
    end

    if isempty(eventTable)
        error('No AICM events found to visualize.');
    end

    timeRange = opts.TimeRange;
    if isempty(timeRange)
        padSec = 2;
        timeRange = [min(eventTable.startSec) - padSec, max(eventTable.endSec) + padSec];
        timeRange(1) = max(0, timeRange(1));
    end

    wavFile = char(opts.WavFile);
    if isempty(wavFile)
        wavFile = find_paired_wav(aicmEventsFile, baseName, resultsFolder);
    end

    [tAudio, yAudio, fs] = read_audio_window(wavFile, timeRange);

    colorStart = [0 0.65 0];      % green
    colorEnd   = [0 0.45 0.95];   % blue
    colorClass = [0.85 0 0];      % red

    fig = figure('Name', ['AICM stream: ' baseName], 'Visible', onoff(opts.Visible));
    ax = axes(fig); %#ok<LAXES>
    hold(ax, 'on');

    if ~isempty(yAudio)
        plot(ax, tAudio, yAudio, 'Color', [0.25 0.25 0.25], 'LineWidth', 0.5);
    else
        plot(ax, timeRange, [0 0], 'Color', [0.8 0.8 0.8]);
        text(ax, mean(timeRange), 0, 'WAV not found — showing triggers only', ...
            'HorizontalAlignment', 'center', 'Color', [0.45 0.45 0.45]);
    end

    speakers = unique(eventTable.speaker, 'stable');
    labelRows = containers.Map();
    for i = 1:numel(speakers)
        labelRows(char(speakers(i))) = i;
    end
    nRows = max(1, numel(speakers));

    hStart = gobjects(0);
    hEnd = gobjects(0);
    hClass = gobjects(0);

    yLim = ylim(ax);
    if diff(yLim) < eps
        yLim = [-1 1];
    end
    ySpan = diff(yLim);
    labelBand = 0.06 * ySpan;

    for i = 1:height(eventTable)
        spk = char(eventTable.speaker(i));
        code = speaker_code(spk);
        rowIdx = labelRows(spk);

        tStart = eventTable.startSec(i);
        tEnd = eventTable.endSec(i);

        hStart(end + 1) = xline(ax, tStart, '-', 'Color', colorStart, 'LineWidth', 1.2); %#ok<AGROW>
        hEnd(end + 1) = xline(ax, tEnd, '-', 'Color', colorEnd, 'LineWidth', 1.2); %#ok<AGROW>

        yText = yLim(2) - labelBand * (rowIdx - 0.5) / nRows;
        text(ax, tStart, yText, ['S_' code], ...
            'Color', colorStart, 'FontSize', 7, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
            'Clipping', 'on');
        text(ax, tEnd, yText, ['E_' code], ...
            'Color', colorEnd, 'FontSize', 7, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
            'Clipping', 'on');
    end

    if ~isempty(interactionsTable)
        for i = 1:height(interactionsTable)
            if ~ismember('classLabel', interactionsTable.Properties.VariableNames)
                break;
            end
            lbl = interactionsTable.classLabel(i);
            if ismissing(lbl) || (isstring(lbl) && strlength(lbl) == 0)
                continue;
            end

            tClass = interactionsTable.startSec(i);
            hClass(end + 1) = xline(ax, tClass, '--', 'Color', colorClass, 'LineWidth', 1.4); %#ok<AGROW>

            yClass = yLim(1) + 0.12 * ySpan + mod(i - 1, 3) * 0.04 * ySpan;
            text(ax, tClass, yClass, char(lbl), ...
                'Color', colorClass, 'FontSize', 8, 'FontWeight', 'bold', ...
                'Rotation', 90, 'HorizontalAlignment', 'left', ...
                'VerticalAlignment', 'bottom', 'Clipping', 'on');
        end
    end

    xlim(ax, timeRange);
    xlabel(ax, 'Time (s)');
    ylabel(ax, 'Amplitude');
    title(ax, sprintf('AICM stream — %s  [%.1f – %.1f s]', baseName, timeRange(1), timeRange(2)));
    grid(ax, 'on');

    legendEntries = {'Waveform'};
    legendHandles = plot(ax, nan, nan, 'Color', [0.25 0.25 0.25]);
    if ~isempty(hStart)
        legendHandles(end + 1) = hStart(1); %#ok<AGROW>
        legendEntries{end + 1} = 'Start (S_*), green';
    end
    if ~isempty(hEnd)
        legendHandles(end + 1) = hEnd(1); %#ok<AGROW>
        legendEntries{end + 1} = 'End (E_*), blue';
    end
    if ~isempty(hClass)
        legendHandles(end + 1) = hClass(1); %#ok<AGROW>
        legendEntries{end + 1} = 'Class label, red';
    end
    legend(ax, legendHandles, legendEntries, 'Location', 'northeastoutside');

    hold(ax, 'off');

    if ~isempty(opts.SavePath)
        saveas(fig, char(opts.SavePath));
    end
end


function code = speaker_code(spk)
    switch upper(strtrim(spk))
        case 'MAN'
            code = 'M';
        case 'FAN'
            code = 'F';
        case 'CHN'
            code = 'C';
        otherwise
            code = upper(spk(1:min(1, numel(spk))));
    end
end


function [eventTable, interactionsTable, baseName, resultsFolder] = load_aicm_tables(eventsFile, interactionsFile)
    resultsFolder = fileparts(eventsFile);
    [~, stem, ext] = fileparts(eventsFile);

    if strcmpi(ext, '.mat')
        S = load(eventsFile);
        if isfield(S, 'eventTable')
            eventTable = S.eventTable;
        else
            error('MAT file does not contain eventTable: %s', eventsFile);
        end
        if isfield(S, 'interactionResults')
            interactionsTable = S.interactionResults;
        else
            interactionsTable = table();
        end
        baseName = regexprep(stem, '_AICM_INTERACTIONS$', '');
    else
        eventTable = readtable(eventsFile, 'TextType', 'string');
        baseName = regexprep(stem, '_AICM_EVENTS$', '');

        if isempty(interactionsFile)
            interactionsFile = fullfile(resultsFolder, [baseName '_AICM_INTERACTIONS.csv']);
        end
        if exist(interactionsFile, 'file')
            interactionsTable = readtable(interactionsFile, 'TextType', 'string');
        else
            interactionsTable = table();
        end
    end
end


function wavFile = find_paired_wav(eventsFile, baseName, resultsFolder)
    wavFile = '';
    candidates = { ...
        fullfile(resultsFolder, [baseName '.wav']), ...
        fullfile(resultsFolder, [baseName '.WAV']), ...
        fullfile(fileparts(resultsFolder), [baseName '.wav']), ...
        fullfile(fileparts(resultsFolder), [baseName '.WAV'])};

    for i = 1:numel(candidates)
        if exist(candidates{i}, 'file')
            wavFile = candidates{i};
            return;
        end
    end

    hits = dir(fullfile(fileparts(resultsFolder), '**', [baseName '.wav']));
    if isempty(hits)
        hits = dir(fullfile(fileparts(resultsFolder), '**', [baseName '.WAV']));
    end
    if ~isempty(hits)
        wavFile = fullfile(hits(1).folder, hits(1).name);
    end
end


function [tAudio, yAudio, fs] = read_audio_window(wavFile, timeRange)
    tAudio = [];
    yAudio = [];
    fs = [];

    if isempty(wavFile) || ~exist(wavFile, 'file')
        return;
    end

    info = audioinfo(wavFile);
    fs = info.SampleRate;
    totalSamples = info.TotalSamples;

    s1 = max(1, floor(timeRange(1) * fs) + 1);
    s2 = min(totalSamples, ceil(timeRange(2) * fs));

    if s2 <= s1
        return;
    end

    yAudio = audioread(wavFile, [s1 s2]);
    if size(yAudio, 2) > 1
        yAudio = mean(yAudio, 2);
    end

    nSamples = numel(yAudio);
    maxPlotPoints = 250000;
    if nSamples > maxPlotPoints
        decim = ceil(nSamples / maxPlotPoints);
        yAudio = yAudio(1:decim:end);
        tAudio = (s1 - 1 + (0:numel(yAudio) - 1) * decim) / fs;
    else
        tAudio = ((s1 - 1):(s1 - 2 + nSamples)) / fs;
    end
end


function v = onoff(flag)
    if flag
        v = 'on';
    else
        v = 'off';
    end
end

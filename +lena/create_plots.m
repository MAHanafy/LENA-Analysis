function create_plots(result, cfg)
%CREATE_PLOTS Create the unchanged evaluation and classifier-comparison plots.

if isfield(cfg, 'createPlots') && ~cfg.createPlots
    return;
end

run_evaluation_visualization_light( ...
    result.interactionResults, result.resultsFolder, result.baseName);
compare_classifiers_light(result.segmentTable, result.turnPairs, ...
    result.interactionResults, result.resultsFolder, result.baseName, ...
    cfg.interaction);
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


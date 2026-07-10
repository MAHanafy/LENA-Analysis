function [segmentTable, interactionResults, turnPairs] = classify_interactions(matByLine, params)
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

    if isscalar(rows)
        % A single pair is a scalar struct whose character fields have
        % different lengths (for example, 'FAN' and 'FANtoCHN'). Treat the
        % struct as one record instead of interpreting field lengths as rows.
        turnPairs = struct2table(rows, 'AsArray', true);
    else
        turnPairs = struct2table(rows);
    end
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

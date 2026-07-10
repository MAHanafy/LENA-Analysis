function result = process_recording(recording, cfg)
%PROCESS_RECORDING Parse, classify, and analyze one paired ITS/WAV recording.

cd(recording.folder)
fprintf('\n---------------------------------------------------\n');
fprintf('Working on ITS file %d of %d\n', recording.index, recording.total);
disp(['Working on file: ' recording.name ' in directory: ' recording.folder]);

[subjName, matByLine] = read_its_file_original(recording.name);
[tCHN, tCHN2FAN, tCHN2MAN, tFAN, tMAN] = parse_intervals_original(matByLine);
[segmentTable, interactionResults, turnPairs] = ...
    lena.classify_interactions(matByLine, cfg.interaction);
clear matByLine;

disp(['tCHN= ' num2str(length(tCHN)) '  tFAN= ' num2str(length(tFAN)), ...
    'tMAN= ' num2str(length(tMAN))])

result = struct();
result.currDir = recording.folder;
result.fname = recording.name;
result.subjectName = subjName;
result.baseName = build_output_base_name(subjName, recording.name);
result.age = recording.age;
result.tCHN = tCHN;
result.tCHN2FAN = tCHN2FAN;
result.tCHN2MAN = tCHN2MAN;
result.tFAN = tFAN;
result.tMAN = tMAN;
result.segmentTable = segmentTable;
result.interactionResults = interactionResults;
result.turnPairs = turnPairs;

result = lena.analyze_acoustics(result, cfg);
end

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


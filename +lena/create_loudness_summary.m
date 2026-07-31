function summaryTable = create_loudness_summary(allSegmentsTable)
%CREATE_LOUDNESS_SUMMARY Summarize loudness variability by requested groups.

metricNames = {'loudnessStd','loudnessRange','loudnessIQR'};
summaryTable = empty_summary_table();
if nargin < 1 || isempty(allSegmentsTable) || height(allSegmentsTable) == 0
    return;
end

summaryTable = append_group_stats(summaryTable, allSegmentsTable, "overall", "ALL", metricNames);

if ismember('speaker', allSegmentsTable.Properties.VariableNames)
    speakers = unique(string(allSegmentsTable.speaker));
    speakers = speakers(strlength(strtrim(speakers)) > 0);
    for speakerIndex = 1:numel(speakers)
        speaker = speakers(speakerIndex);
        rows = string(allSegmentsTable.speaker) == speaker;
        summaryTable = append_group_stats(summaryTable, allSegmentsTable(rows, :), ...
            "speaker", speaker, metricNames);
    end
end

if ismember('classLabel', allSegmentsTable.Properties.VariableNames)
    labels = string(allSegmentsTable.classLabel);
    classLabels = unique(labels(strlength(strtrim(labels)) > 0));
    for labelIndex = 1:numel(classLabels)
        classLabel = classLabels(labelIndex);
        rows = labels == classLabel;
        summaryTable = append_group_stats(summaryTable, allSegmentsTable(rows, :), ...
            "classLabel", classLabel, metricNames);
    end
end

if ~isempty(summaryTable)
    summaryTable = sortrows(summaryTable, {'level','group','metric'});
end
end

function outputTable = append_group_stats(outputTable, sourceTable, levelName, groupName, metricNames)
for metricIndex = 1:numel(metricNames)
    metricName = metricNames{metricIndex};
    if ~ismember(metricName, sourceTable.Properties.VariableNames)
        continue;
    end
    values = sourceTable.(metricName);
    values = values(isfinite(values));
    if isempty(values)
        continue;
    end
    rowTable = table(levelName, groupName, string(metricName), numel(values), ...
        mean(values), median(values), std(values), min(values), max(values), ...
        'VariableNames', {'level','group','metric','nSegments','mean','median','std','min','max'});
    outputTable = [outputTable; rowTable]; %#ok<AGROW>
end
end

function summaryTable = empty_summary_table()
summaryTable = table(strings(0,1), strings(0,1), strings(0,1), ...
    zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
    'VariableNames', {'level','group','metric','nSegments','mean','median','std','min','max'});
end

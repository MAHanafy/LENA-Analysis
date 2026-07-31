function resultTable = read_all_segments_csv(csvPath)
%READ_ALL_SEGMENTS_CSV Import an All-Segments CSV with unambiguous dates.

importOptions = detectImportOptions(csvPath, 'VariableNamingRule', 'preserve');
if ismember('Date', importOptions.VariableNames)
    importOptions = setvartype(importOptions, 'Date', 'string');
end

resultTable = readtable(csvPath, importOptions);
if ~ismember('Date', resultTable.Properties.VariableNames)
    return;
end

dateText = string(resultTable.('Date'));
parsedDates = NaT(size(dateText));
isoMask = contains(dateText, '-');
parsedDates(isoMask) = datetime(dateText(isoMask), 'InputFormat', 'yyyy-MM-dd');
parsedDates(~isoMask) = datetime(dateText(~isoMask), 'InputFormat', 'M/d/yyyy');
parsedDates.Format = 'M/d/yyyy';
resultTable.('Date') = parsedDates;
end

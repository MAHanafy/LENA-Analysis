function tests = test_lena_pipeline
%TEST_LENA_PIPELINE Regression tests for the modular refactor.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
testFile = mfilename('fullpath');
repoRoot = fileparts(fileparts(testFile));
addpath(repoRoot);
testCase.TestData.repoRoot = repoRoot;
end

function testConfigMatchesHistoricalDefaults(testCase)
cfg = lena.config();

verifyEqual(testCase, cfg.rate, 16000);
verifyEqual(testCase, cfg.frame_length, 20);
verifyEqual(testCase, cfg.TimeStep, 3);
verifyEqual(testCase, cfg.SHR_Threshold, 0.4);
verifyEqual(testCase, cfg.Ceiling, 1250);
verifyEqual(testCase, cfg.med_smooth, 0);
verifyEqual(testCase, cfg.CHECK_VOICING, 1);
verifyEqual(testCase, cfg.trimEdgeFrames, 2);
verifyEqual(testCase, cfg.dBSPLCalibrationOffset, 97);
verifyEqual(testCase, cfg.interaction.adjacencyWindowSec, 5.0);
verifyEqual(testCase, cfg.interaction.minDurationSec, 0.10);
verifyTrue(testCase, cfg.interaction.requireSpeechEvidence);
verifyTrue(testCase, cfg.interaction.preferLENATurnCodes);
verifyTrue(testCase, cfg.interaction.useAdjacencyFallback);
verifyTrue(testCase, cfg.interaction.applyNoChnBetweenRule);
verifyTrue(testCase, cfg.interaction.segmentPrimaryLabelOnly);
verifyTrue(testCase, cfg.interaction.requireAicmLineNeighbor);
verifyEqual(testCase, cfg.interaction.supportedLabels, ...
    {'MANtoMAN','MANtoFAN','FANtoMAN','FANtoFAN', ...
     'MANtoCHN','CHNtoMAN','FANtoCHN','CHNtoFAN'});
end

function testFindRecordingsSupportsOldAndNewNames(testCase)
fixture = testCase.applyFixture( ...
    matlab.unittest.fixtures.TemporaryFolderFixture);
subjectFolder = fullfile(fixture.Folder, 'AM28');
mkdir(subjectFolder);

newName = 'AM28_010213_e20110124_120018_003264.its';
oldName = 'e20101221_110132_003524.its';
createEmptyFile(fullfile(subjectFolder, newName));
createEmptyFile(fullfile(subjectFolder, oldName));

cfg = lena.config();
recordings = lena.find_recordings(subjectFolder, cfg);
verifyNumElements(testCase, recordings, 2);

names = string({recordings.name});
newRecording = recordings(names == newName);
oldRecording = recordings(names == oldName);

verifyEqual(testCase, newRecording.subjectName, 'AM28');
verifyEqual(testCase, newRecording.baseName, ...
    'AM28_010213_e20110124_120018_003264');
verifyEqual(testCase, oldRecording.subjectName, 'e20101221');
verifyEqual(testCase, oldRecording.baseName, 'e20101221_110132_003524');
end

function testRepresentativeFanToChildPair(testCase)
cfg = lena.config();
params = cfg.interaction;
params.preferLENATurnCodes = false;

lines = {
    '<Conversation num="7" type="AICM">'
    '<Segment spkr="FAN" startTime="PT0.0S" endTime="PT1.0S" femaleAdultWordCnt="3"/>'
    '<Segment spkr="CHN" childUttCnt="1" startUtt1="PT1.2S" endUtt1="PT2.0S"/>'
    '</Conversation>'
    };
matByLine = struct('text', lines);

[segmentTable, interactionResults, turnPairs] = ...
    lena.classify_interactions(matByLine, params);

verifyEqual(testCase, height(segmentTable), 2);
verifyEqual(testCase, height(turnPairs), 1);
verifyEqual(testCase, height(interactionResults), 2);
verifyEqual(testCase, string(turnPairs.classLabel(1)), "FANtoCHN");
verifyEqual(testCase, string(interactionResults.classLabel), ...
    ["FANtoCHN"; "FANtoCHN"]);
verifyEqual(testCase, string(interactionResults.speaker), ["FAN"; "CHN"]);
verifyClass(testCase, turnPairs.fromSpeaker, 'string');
verifyClass(testCase, turnPairs.toSpeaker, 'string');
end

function testEmptyClassifierSchemasRemainStable(testCase)
cfg = lena.config();
matByLine = struct('text', '<Its></Its>');

[segmentTable, interactionResults, turnPairs] = ...
    lena.classify_interactions(matByLine, cfg.interaction);

verifyEmpty(testCase, segmentTable);
verifyEmpty(testCase, interactionResults);
verifyEmpty(testCase, turnPairs);
verifyTrue(testCase, all(ismember( ...
    {'speaker','startSec','endSec','conversationId','segmentIndex'}, ...
    segmentTable.Properties.VariableNames)));
verifyTrue(testCase, all(ismember( ...
    {'classLabel','speechType','conversationId','segmentIndex'}, ...
    interactionResults.Properties.VariableNames)));
verifyTrue(testCase, all(ismember( ...
    {'fromSpeaker','toSpeaker','classLabel','gapSec'}, ...
    turnPairs.Properties.VariableNames)));
end

function testEmptySessionDiagnosticExplainsNeighborRejection(testCase)
cfg = lena.config();
lines = {
    '<Conversation num="175" type="AICM">'
    '<Segment spkr="MAN" maleAdultWordCnt="3" startTime="PT1.0S" endTime="PT2.0S" />'
    '<Segment spkr="OLF" startTime="PT2.0S" endTime="PT3.0S" />'
    '<Segment spkr="CHN" childUttCnt="1" startUtt1="PT3.0S" endUtt1="PT4.0S" startTime="PT3.0S" endTime="PT4.0S" />'
    '</Conversation>'
    };
matByLine = struct('text', lines);

[segmentTable, interactionResults, turnPairs, diagnostic] = ...
    lena.classify_interactions(matByLine, cfg.interaction);

verifyEmpty(testCase, segmentTable);
verifyEmpty(testCase, interactionResults);
verifyEmpty(testCase, turnPairs);
verifyEqual(testCase, diagnostic.aicmConversationCount, 1);
verifyEqual(testCase, diagnostic.candidateSegmentCount, 2);
verifyEqual(testCase, diagnostic.rejectedNoImmediateNeighborCount, 2);
verifySubstring(testCase, diagnostic.reason, "immediately adjacent");
end

function testHistoricalEntryPointIsRetained(testCase)
compatibilityFile = fullfile(testCase.TestData.repoRoot, ...
    'acoust_detail_funcs_newhelpers_MH.m');
legacyFile = fullfile(testCase.TestData.repoRoot, 'legacy', ...
    'acoust_detail_funcs_original.m');

verifyTrue(testCase, isfile(compatibilityFile));
verifyTrue(testCase, isfile(legacyFile));
verifySubstring(testCase, fileread(compatibilityFile), 'run_lena_analysis');
end

function testAcousticHelpersAreConsolidated(testCase)
analysisFile = fullfile(testCase.TestData.repoRoot, '+lena', 'analyze_acoustics.m');
analysisText = fileread(analysisFile);

verifySubstring(testCase, analysisText, 'function dBSPL = dbfs_to_dbspl');
verifySubstring(testCase, analysisText, 'function rangeST = f0_range_semitones');
verifySubstring(testCase, analysisText, 'function stats = compute_loudness_variability_stats');
verifySubstring(testCase, analysisText, 'dBFS(finiteMask) + calibrationOffset');
verifySubstring(testCase, analysisText, '12 * log2');
verifyFalse(testCase, contains(analysisText, 'loudnessCV'));
end

function testOutputHelpersAreConsolidated(testCase)
saveFile = fullfile(testCase.TestData.repoRoot, '+lena', 'save_results.m');
saveText = fileread(saveFile);

verifySubstring(testCase, saveText, 'function resultTable = read_all_segments_csv');
verifySubstring(testCase, saveText, 'function summaryTable = create_loudness_summary');
verifySubstring(testCase, saveText, '"speaker", speaker, metricNames');
verifySubstring(testCase, saveText, '"classLabel", classLabel, metricNames');
end

function testSubjectWorkbookMergeRunsAsFinalization(testCase)
fixture = testCase.applyFixture( ...
    matlab.unittest.fixtures.TemporaryFolderFixture);
subjectFolder = fullfile(fixture.Folder, 'S1AC');
sessionFolders = {fullfile(subjectFolder, 'session1'), fullfile(subjectFolder, 'session2')};

for sessionIndex = 1:numel(sessionFolders)
    mkdir(sessionFolders{sessionIndex});
    sourceTable = table("file" + sessionIndex, "S1AC", sessionIndex, ...
        datetime(2015, 4, 12 + sessionIndex, 'Format', 'M/d/yyyy'), sessionIndex, ...
        "CHN", "FANtoCHN", sessionIndex, 2 * sessionIndex, 3 * sessionIndex, ...
        'VariableNames', {'file name','subject name','Session ID','Date', ...
        'conversationId','speaker','classLabel','loudnessStd','loudnessRange','loudnessIQR'});
    csvPath = fullfile(sessionFolders{sessionIndex}, ...
        sprintf('session%d_AICM_INTERACTIONS_All_Segments.csv', sessionIndex));
    writetable(sourceTable, csvPath);
end

finalResult = struct('subjectResultsFolder', subjectFolder, 'subjectName', 'S1AC');
finalResult = lena.save_results(finalResult, fixture.Folder, lena.config(), true);
outputXlsx = finalResult.subjectWorkbook;
allSegments = readtable(outputXlsx, 'Sheet', 'All_Segments', ...
    'VariableNamingRule', 'preserve');
loudnessSummary = readtable(outputXlsx, 'Sheet', 'Loudness_Summary', ...
    'VariableNamingRule', 'preserve');

verifyEqual(testCase, height(allSegments), 2);
verifyTrue(testCase, any(string(loudnessSummary.level) == "speaker"));
verifyTrue(testCase, any(string(loudnessSummary.level) == "classLabel"));
end

function createEmptyFile(filePath)
fileId = fopen(filePath, 'w');
if fileId < 0
    error('Could not create test fixture: %s', filePath);
end
fclose(fileId);
end

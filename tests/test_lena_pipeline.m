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

function testHistoricalEntryPointIsRetained(testCase)
compatibilityFile = fullfile(testCase.TestData.repoRoot, ...
    'acoust_detail_funcs_newhelpers_MH.m');
legacyFile = fullfile(testCase.TestData.repoRoot, 'legacy', ...
    'acoust_detail_funcs_original.m');

verifyTrue(testCase, isfile(compatibilityFile));
verifyTrue(testCase, isfile(legacyFile));
verifySubstring(testCase, fileread(compatibilityFile), 'run_lena_analysis');
end

function testAcousticConversions(testCase)
verifyEqual(testCase, lena.f0_range_semitones(100, 200), 12, 'AbsTol', 1e-12);
verifyTrue(testCase, isnan(lena.f0_range_semitones(0, 200)));
verifyEqual(testCase, lena.dbfs_to_dbspl([-97 -20 -Inf]), [0 77 -Inf]);
end

function createEmptyFile(filePath)
fileId = fopen(filePath, 'w');
if fileId < 0
    error('Could not create test fixture: %s', filePath);
end
fclose(fileId);
end

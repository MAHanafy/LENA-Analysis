function cfg = config()
%CONFIG Return the parameters used by the LENA analysis pipeline.
% Keep these values synchronized with the historical monolithic script.

cfg.ages = [2.53 2.41 2.59 2.36 2.37 2.72 2.10 2.41 2.35 2.23 ...
    2.39 2.63 2.53 2.42 2.44 2.41 2.24 2.94 2.29 2.45 2.49 2.46];

cfg.rate = 16000;
cfg.frame_length = 20;
cfg.TimeStep = 3;
cfg.SHR_Threshold = 0.4;
cfg.Ceiling = 1250;
cfg.med_smooth = 0;
cfg.CHECK_VOICING = 1;
cfg.trimEdgeFrames = 2;

cfg.interaction.adjacencyWindowSec = 5.0;
cfg.interaction.minDurationSec = 0.10;
cfg.interaction.requireSpeechEvidence = true;
cfg.interaction.preferLENATurnCodes = true;
cfg.interaction.useAdjacencyFallback = true;
cfg.interaction.applyNoChnBetweenRule = true;
cfg.interaction.segmentPrimaryLabelOnly = true;
cfg.interaction.requireAicmLineNeighbor = true;
cfg.interaction.supportedLabels = {'MANtoMAN','MANtoFAN','FANtoMAN','FANtoFAN', ...
    'MANtoCHN','CHNtoMAN','FANtoCHN','CHNtoFAN'};

cfg.nameCorrespondencesFile = ...
    'F:\SynologyDrive\Cougar_union\Name_Correspondences_correct_final.xlsx';
cfg.defaultBaseDir = 'F:\SynologyDrive\Cougar_union\HA';
cfg.createPlots = true;
end

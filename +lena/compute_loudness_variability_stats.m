function stats = compute_loudness_variability_stats(signal, fs, frameLengthMs, frameStepMs, minRms)
%COMPUTE_LOUDNESS_VARIABILITY_STATS Compute frame-level dBFS variability.

if nargin < 5 || isempty(minRms)
    minRms = 1e-6;
end
if nargin < 4 || isempty(frameStepMs)
    frameStepMs = 10;
end
if nargin < 3 || isempty(frameLengthMs)
    frameLengthMs = 20;
end

emptyStats = struct('loudnessStd', NaN, 'loudnessRange', NaN, ...
    'loudnessIQR', NaN, 'nValidFrames', 0);
if isempty(signal)
    stats = emptyStats;
    return;
end

frameSamples = round(frameLengthMs / 1000 * fs);
stepSamples = round(frameStepMs / 1000 * fs);
if frameSamples <= 0 || stepSamples <= 0
    stats = emptyStats;
    return;
end

if numel(signal) < frameSamples
    frameSamples = numel(signal);
    stepSamples = 1;
    nFrames = 1;
else
    nFrames = floor((numel(signal) - frameSamples) / stepSamples) + 1;
end

dbfsValues = nan(nFrames, 1);
for frameIndex = 1:nFrames
    startIndex = (frameIndex - 1) * stepSamples + 1;
    endIndex = startIndex + frameSamples - 1;
    frame = signal(startIndex:endIndex);
    frameRms = rms(frame);
    if frameRms > minRms
        dbfsValues(frameIndex) = 20 * log10(frameRms);
    end
end

validDbfs = dbfsValues(isfinite(dbfsValues));
if isempty(validDbfs)
    stats = emptyStats;
    return;
end

stats = struct('loudnessStd', std(validDbfs), ...
    'loudnessRange', max(validDbfs) - min(validDbfs), ...
    'loudnessIQR', prctile(validDbfs, 75) - prctile(validDbfs, 25), ...
    'nValidFrames', numel(validDbfs));
end

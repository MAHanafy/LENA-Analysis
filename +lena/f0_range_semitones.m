function rangeST = f0_range_semitones(f0min, f0max)
%F0_RANGE_SEMITONES Convert a positive F0 minimum and maximum to semitones.

rangeST = nan(size(f0min));
validMask = isfinite(f0min) & isfinite(f0max) & f0min > 0 & f0max > 0;
rangeST(validMask) = 12 * log2(f0max(validMask) ./ f0min(validMask));
end

function dBSPL = dbfs_to_dbspl(dBFS)
%DBFS_TO_DBSPL Convert dBFS to estimated dB SPL using a 97 dB offset.

dBSPL = dBFS;
finiteMask = isfinite(dBFS);
dBSPL(finiteMask) = dBFS(finiteMask) + 97;
end

-- pex: checkwater b1770a4d
-- No change: it waited only in Cold.IncreaseCold's stage spell, which no longer blocks
-- (Survival_NeedBase.ApplyNeedStagePlayerEffects). `checkingWater` now never spans a tick.
return function(C) end

-- pex: checkheat 109ba6e1
-- pex: onupdate 30068e26
-- pex: onupdategametime 4fa2c0c2
-- No change: they waited only in Cold.DecreaseCold's stage spell, which no longer blocks
-- (Survival_NeedBase.ApplyNeedStagePlayerEffects). Nothing after the calls reads the spell.
return function(C) end

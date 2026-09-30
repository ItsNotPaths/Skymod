-- The Cure Disease archetype: every disease on the target ends.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeCureDisease", nil)

function C:OnEffectStart(target, caster) target:DispelTagged("disease") end

return C

-- The Cure Poison archetype: every poison on the target ends.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeCurePoison", nil)

function C:OnEffectStart(target, caster) target:DispelTagged("poison") end

return C

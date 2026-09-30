-- The Banish archetype: a summoned or raised target goes. The level cap is the effect's own
-- magichit.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeBanish", nil)

function C:OnEffectStart(target, caster)
  if target:IsCommandedActor() then target:Kill(caster) end
end

return C

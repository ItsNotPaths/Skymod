-- The Command Summoned archetype: the caster takes over a summoned or raised target until the
-- effect ends.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeCommandSummoned", nil)

function C:OnEffectStart(target, caster)
  if target:IsCommandedActor() then self:Command(target) end
end

return C

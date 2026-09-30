-- The Reanimate archetype: a dead target rises and fights for the caster until the effect ends,
-- then dies again. The level cap is the effect's own magichit.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeReanimate", nil)
C.__vars = { raised = rt.form("Actor") }

function C:OnEffectStart(target, caster)
  if not target:IsDead() then return end
  target:Resurrect()
  self:Command(target)
  self.raised = target
end

function C:OnEffectFinish(target, caster)
  self.raised:Kill()
end

return C

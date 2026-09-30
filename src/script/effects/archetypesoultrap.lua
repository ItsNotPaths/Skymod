-- The Soul Trap archetype: a target that dies while the effect runs gives its soul to the caster.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeSoulTrap", nil)

function C:OnEffectFinish(target, caster)
  if target:IsDead() then caster:TrapSoul(target) end
end

return C

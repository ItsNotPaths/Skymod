-- The Disarm archetype: the target puts away its weapon.
-- (hole disarm-drop :tags (magic combat) :sev polish) a disarmed weapon is unequipped, not dropped: nothing drops an item into the world yet.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeDisarm", nil)

function C:OnEffectStart(target, caster)
  local weapon = target:GetEquippedWeapon()
  if weapon then target:UnequipItem(weapon) end
end

return C

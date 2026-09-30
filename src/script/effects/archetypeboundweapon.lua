-- The Bound Weapon archetype: its weapon appears in the target's hand until the effect ends.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeBoundWeapon", nil)
C.__vars = { Weapon = rt.form("Weapon") }
C.__autoprop["weapon"] = "Weapon"

function C:OnEffectStart(target, caster)
  target:AddItem(self.Weapon, 1, true)
  target:EquipItem(self.Weapon, false, true)
end

function C:OnEffectFinish(target, caster)
  target:RemoveItem(self.Weapon, target:GetItemCount(self.Weapon), true)
end

return C

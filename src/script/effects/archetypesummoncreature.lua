-- The Summon Creature archetype: its actor appears where the effect lands and fights for the
-- caster until the effect ends, then goes.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeSummonCreature", nil)
C.__vars = { Summon = rt.form("ActorBase"), summoned = rt.form("Actor") }
C.__autoprop["summon"] = "Summon"

function C:OnEffectStart(target, caster)
  self.summoned = target:PlaceActorAtMe(self.Summon)
  self:Command(self.summoned)
end

function C:OnEffectFinish(target, caster)
  self.summoned:Disable()
  self.summoned:Delete()
end

return C

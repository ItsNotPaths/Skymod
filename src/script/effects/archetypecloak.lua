-- The Cloak archetype: its spell hits each actor hostile to the target within m of it, once a
-- second, while the effect runs (a zone that follows the target).
local rt = require('skymod.rt')
local C = rt.class("ArchetypeCloak", nil)
C.__vars = { Spell = rt.form("Spell"), zone = rt.form("ObjectReference") }
C.__autoprop["spell"] = "Spell"

function C:OnEffectStart(target, caster)
  self.zone = rt.zone { at = target, follow = target, shape = { sphere = self:GetMagnitude() },
    caster = target, spell = self.Spell, every = 1 }
end

function C:OnEffectFinish(target, caster)
  self.zone:Delete()
end

return C

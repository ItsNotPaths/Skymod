-- The Stagger archetype: the target is pushed away from the caster, harder for a larger m (10 per
-- point, a guess). The stagger itself, a moment it cannot act, is an actor state (actor-states).
local rt = require('skymod.rt')
local C = rt.class("ArchetypeStagger", nil)

function C:OnEffectStart(target, caster)
  caster:PushActorAway(target, 10 * self:GetMagnitude())
end

return C

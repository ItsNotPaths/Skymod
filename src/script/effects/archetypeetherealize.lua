-- The Etherealize archetype: the target is a ghost while the effect runs; no weapon or other
-- actor's spell hits it.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeEtherealize", nil)

function C:OnEffectStart(target, caster) target:SetGhost(true) end
function C:OnEffectFinish(target, caster) target:SetGhost(false) end

return C

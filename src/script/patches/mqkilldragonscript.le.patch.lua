-- pex: deathsequence 13bbd8a5
-- LE without Dragonborn: DeathSequence(dragonRef) waited through about twenty beats and always gave
-- the soul to the player. It now starts the run on the dragon's own dragonActorSCRIPT.
local rt = require('skymod.rt')

return function(C)
    function C:DeathSequence(dragon)
        if dragon:IsInFaction(self.NoDragonAbsorb) then return end
        local d = rt.cast(dragon, "dragonactorscript")
        -- (hole dragon-actor-script :tags script :sev gap) a dragon without dragonActorSCRIPT has no instance to run on
        if d == rt.None then
            rt.static("Debug", "Trace", "DeathSequence: " .. tostring(dragon) .. " has no dragonActorSCRIPT")
            return
        end
        d:BeginDeathSequence(self)
    end
end

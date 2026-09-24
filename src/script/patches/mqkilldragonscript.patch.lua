-- pex: deathsequence e71b714a
-- DeathSequence waited through about twenty beats per dying dragon. It now picks the variant and
-- starts the run on the dragon's own dragonActorSCRIPT. MQ06DeathSequence keeps its S6 split form.
local rt = require('skymod.rt')

return function(C)
    function C:DeathSequence(dragon, absorber, miraakAppears)
        local player = rt.static("Game", "GetPlayer")
        if player:IsInLocation(self.DLC2ApocryphaLocation) or player:GetWorldSpace() == self.DLC2ApocryphaWorld then
            if absorber == rt.None then
                self:MQ06DeathSequence(dragon, self.DLC2MiraakMQ06Ref, false)
                return
            end
        else
            if absorber == rt.None then absorber = player end
            if miraakAppears then
                self.DLC2SoulSteal:MiraakAppears(dragon)
                return
            end
        end
        if dragon:IsInFaction(self.NoDragonAbsorb) then return end
        local d = rt.cast(dragon, "dragonactorscript")
        -- HOLE(script, gap): a dragon without dragonActorSCRIPT has no instance to run on
        if d == rt.None then
            rt.static("Debug", "Trace", "DeathSequence: " .. tostring(dragon) .. " has no dragonActorSCRIPT")
            return
        end
        d:BeginDeathSequence(self, absorber)
    end
end

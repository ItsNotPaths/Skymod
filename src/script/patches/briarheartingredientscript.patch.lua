-- pex: oncontainerchanged ee2ced23
-- OnContainerChanged polled Utility.IsInMenuMode before swapping the heart armor. No script runs
-- inside a world-pausing menu (script-api.md section 7), so the poll always reads false the moment
-- this handler is running; the loop drops out with no clock.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "briarheart: " .. msg) end

return function(C)
    function C:OnContainerChanged(akNewContainer, akOldContainer)
        local oldHost = rt.cast(akOldContainer, "actor")
        if oldHost and oldHost:IsEquipped(self.ArmorBriarHeart) then
            if oldHost:GetItemCount(self.ArmorBriarHeartEmpty) < 1 then
                oldHost:AddItem(self.ArmorBriarHeartEmpty, 1)
            end
            if not oldHost:IsDead() then
                oldHost:Kill(rt.cast(akNewContainer, "actor"))
            end
            oldHost:EquipItem(self.ArmorBriarHeartEmpty, true, true)
            oldHost:UnequipItem(self.ArmorBriarHeart, true, true)
        end

        local newHost = rt.cast(akNewContainer, "actor")
        if newHost and newHost:IsEquipped(self.ArmorBriarHeartEmpty) then
            if newHost:GetItemCount(self.ArmorBriarHeart) < 1 then
                newHost:AddItem(self.ArmorBriarHeart, 1)
            end
            if newHost:IsDead() and not newHost:IsEquipped(self.ArmorBriarHeart) then
                newHost:EquipItem(self.ArmorBriarHeart, true, true)
            end
        end
        trace("done, old " .. tostring(akOldContainer) .. " new " .. tostring(akNewContainer))
    end
end

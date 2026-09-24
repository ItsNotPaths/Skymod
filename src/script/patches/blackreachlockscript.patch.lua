-- pex: setopen 5efc0641
-- SetOpen waited out any run already busy, then waited 2 s between the open animation and
-- activating the linked stair. Both become states: Busy drops a second start, the wait is a timer.
local rt = require('skymod.rt')

return function(C)
    C.__vars.openT = rt.timer(0.0)
    C.__vars.TickRate = rt.float(0.1)

    function C:SetOpen(abOpen)
        if self:GetState() == "busy" then return end -- a second start is dropped
        self.isAnimating = true
        self.DweBREntranceStair = self:GetLinkedRef()
        self:GotoState("busy")
        rt.static("Debug", "Trace", tostring(self) .. " Unlocking")
        self:PlayAnimation(self.openAnim)
        self.openT = 2.0
    end
    rt.params(C, "SetOpen", { {"abOpen", true} })

    local Busy = rt.state(C, "busy")
    function Busy:OnTick()
        if self.openT > 0 then return end
        self.DweBREntranceStair:Activate(self.DweBREntranceStair, false)
        self:GotoState("done")
        self.isAnimating = false
        local abls = rt.cast(self, "alftandblackreachlockscript")
        if abls ~= rt.cast(rt.None, "alftandblackreachlockscript") then
            abls.isOpen = true
        end
    end
end

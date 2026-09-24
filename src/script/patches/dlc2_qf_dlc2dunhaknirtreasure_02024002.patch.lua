-- pex: fragment_23 11f5ad3e
-- Fragment_23 closed the exit, shook the camera, waited 1 s, added the dread music, waited 1 s
-- more, then started Haknir's battle. The class already ticks (S6 split, fragment_1's timer); we
-- call that first, then carry our own two waits as a stage field.
local rt = require('skymod.rt')

local Frag23 = rt.sequence("Idle", "Dread", "Battle")

return function(C)
	C.__vars.frag23 = Frag23.Idle
	C.__vars.frag23T = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:fragment_23()
		if self.frag23 ~= Frag23.Idle then return end -- a run happens once
		self:SetObjectiveCompleted(70)
		self.dlc2dunhaknirrotatingdoorcollision:Enable(false)
		self.dlc2dunhaknirrotatingdoorcollision2:Enable(false)
		self.haknirrotatingdoor:Activate(self.haknirrotatingdoor)
		rt.static("Game", "ShakeController", 0.5, 0.5, 3)
		rt.static("Game", "ShakeCamera", rt.None, 0.5, 3)
		self.ambrumbleshakegreybeards:Play(rt.static("Game", "GetPlayer"))
		self.frag23, self.frag23T = Frag23.Dread, 1.0
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.frag23T > 0 then return end
		if self.frag23 == Frag23.Dread then
			self.musdread:Add()
			self.frag23, self.frag23T = Frag23.Battle, 1.0
		elseif self.frag23 == Frag23.Battle then
			local haknir = self.alias_haknir:GetActorRef()
			rt.cast(haknir, "dlc2dunhaknirbossbattlescript"):StartBattlePhase(0)
			self:SetObjectiveDisplayed(90)
			self.frag23 = Frag23.Idle
		end
	end
end

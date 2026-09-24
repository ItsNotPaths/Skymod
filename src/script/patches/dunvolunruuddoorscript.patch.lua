-- pex: ready.onactivate 8d097059
-- OnActivate ran a door-open cycle (0.5s open, activate the linked door if the player followed,
-- 1.0s, close) when stage 30 was done, then always checked the relics and, once both were in, a
-- 5s "solved" busy cycle. Both cycles are now one stage field; the relic check runs right after
-- the door cycle settles, as Papyrus reached it only after that cycle's waits returned.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.Stage = rt.sequence("Idle", "Opening", "Closing", "Solving")
	C.__vars.stage = C.Stage.Idle
	C.__vars.stageT = rt.timer(0.0)
	C.__vars.pendingActor = rt.form("ObjectReference")
	local Ready = rt.state(C, "ready")

	local function relic_check(self)
		if self.player:GetItemCount(self.relic01base) >= 1 then
			self.player:RemoveItem(self.relic01base, self.player:GetItemCount(self.relic01base))
			self.relic01static:Enable()
			self.door01:PlayGamebryoAnimation("left")
			self.relic01in = true
		end
		if self.player:GetItemCount(self.relic02base) >= 1 then
			self.player:RemoveItem(self.relic02base, self.player:GetItemCount(self.relic02base))
			self.door01:PlayGamebryoAnimation("left")
			self.relic02static:Enable()
			self.relic02in = true
		end
		if self.relic01in and self.relic02in then
			self.door01:PlayGamebryoAnimation("right")
			self.door02:PlayGamebryoAnimation("right")
			self:GotoState("busy")
			self.stage = C.Stage.Solving
			self.stageT = 5.0
		else
			self.defaultlacktheitemmsg:Show()
		end
	end

	function Ready:OnActivate(actronaut)
		if self.myquest:GetStage() < 10 then
			self.myquest:SetStage(10)
			self.defaultlacktheitemmsg:Show()
		end
		if self.myquest:GetStageDone(30) then
			self.door01:PlayGamebryoAnimation("forward")
			self.door02:PlayGamebryoAnimation("forward")
			self:GotoState("busy")
			self.pendingActor = actronaut
			self.stage = C.Stage.Opening
			self.stageT = 0.5
			return -- relic check runs once this cycle closes, below
		end
		if self.myquest:GetStage() >= 10 then relic_check(self) end
	end

	function C:OnTick()
		if self.stage == C.Stage.Idle or self.stageT > 0 then return end
		if self.stage == C.Stage.Opening then
			if self.player:GetParentCell() == self:GetParentCell() then
				self:GetLinkedRef():Activate(self.pendingActor)
			end
			self.stage = C.Stage.Closing
			self.stageT = 1.0
			return
		end
		if self.stage == C.Stage.Closing then
			self.door01:PlayGamebryoAnimation("backward")
			self.door02:PlayGamebryoAnimation("backward")
			self:GotoState("ready")
			self.stage = C.Stage.Idle
			if self.myquest:GetStage() >= 10 then relic_check(self) end
			return
		end
		if self.stage == C.Stage.Solving then
			self:GotoState("ready")
			self.myquest:SetStage(30)
			self.stage = C.Stage.Idle
		end
	end
end

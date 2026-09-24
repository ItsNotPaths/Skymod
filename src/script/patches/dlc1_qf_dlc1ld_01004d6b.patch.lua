-- pex: fragment_32 8326aab7 e9dcf20b
-- pex: fragment_50 882acde1
-- pex: fragment_80 30d5ff27
-- Stage fragments that waited on Katria's fades (DLC1LD_GhostScript) or on a 0.5 s pause. Each
-- fragment's rest is now a stage stepped by OnTick next to the split fragment's tick, and waits
-- while Katria's `fade` is not Idle.
local rt = require('skymod.rt')

return function(C)
	C.F32 = rt.sequence("Idle", "CatchingUp", "Waiting", "Fading")
	C.F50 = rt.sequence("Idle", "Warping")
	local F32, F50 = C.F32, C.F50
	local v = C.__vars
	v.f32, v.f32_t = F32.Idle, rt.timer(0.0)
	v.f50 = F50.Idle
	v.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick

	local function player() return rt.static("Game", "GetPlayer") end
	local function katria(self) return rt.cast(self.Alias_Katria:GetActorRef(), "DLC1LD_GhostScript") end
	local function katria_settled(self)
		local k = katria(self)
		return not k or k.fade.name == "Idle"
	end

	function C:Fragment_32()
		if self.f32 ~= F32.Idle then return end
		local k, p = katria(self), player()
		if self:GetStageDone(30) then
			self.f32 = F32.CatchingUp
			k:CatchUp(p:GetDistance(self.KatriaMoveTarget13) > 768 and p or self.KatriaMoveTarget13)
		elseif p:GetDistance(self.KatriaPuzzleChairMarker) > 768 then
			self.f32 = F32.Waiting
			self.f32_t = 0.5
			k:Disable(false)
			k:MoveTo(p)
			k:FadeInNoWait()
		else
			self.f32 = F32.Fading
			self:SetStage(76)
			k:Disable()
			k:EvaluatePackage()
			k:MoveToPackageLocation()
			k:FadeIn()
		end
		self:OnTick()
	end

	local function f32_tick(self)
		if self.f32 == F32.CatchingUp and katria_settled(self) then
			self.f32 = F32.Idle
			self:SetStage(80)
		elseif self.f32 == F32.Waiting and self.f32_t <= 0 or self.f32 == F32.Fading and katria_settled(self) then
			self.f32 = F32.Idle
			self:SetStage(77)
			self.DLC1LD_12b_KatriaCommentImpressed:Start()
			self:SetStage(80)
		end
	end

	function C:Fragment_50()
		if self.f50 ~= F50.Idle then return end
		rt.cast(self, "DLC1LD_D2QuestScript"):StopScenes()
		if not self:GetStageDone(30) then return end
		local k = katria(self)
		if k:IsInCombat() then return end -- Papyrus checked again at once, with the same answer
		self.f50 = F50.Warping
		k:Warp(self.KatriaMoveTarget7)
	end

	local function f50_tick(self)
		if self.f50 ~= F50.Warping or not katria_settled(self) then return end
		self.f50 = F50.Idle
		if katria(self):IsInCombat() then return end
		self.DLC1LD_07_KatriaCommentSealedDoor:Start()
		rt.cast(self.DoorSuccessTrigger, "DLC1LD_DoorTriggerToggleScript"):EnableDoorTrigger()
	end

	-- the fade-out, move and fade-in were its last lines
	function C:Fragment_80()
		if not self:GetStageDone(22) then katria(self):Warp(self.KatriaMoveTarget3) end
	end

	function C:OnTick()
		split_tick(self)
		f32_tick(self)
		f50_tick(self)
	end
end

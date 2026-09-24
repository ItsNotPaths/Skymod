-- pex: ready.onactivate 8a21b246
-- pex: turnvalve 0032cf5a
-- The valve turned and waited for Trans01 or Trans02, then the activation switched the steam and
-- went back to Ready. Now the event does both; its name says which turn ended.
local rt = require('skymod.rt')

return function(C)
	local Ready, Animating = rt.state(C, "Ready"), rt.state(C, "Animating")
	local function steam(self, name) return rt.cast(self[name], "DLC1LD_BthalftSteamManagerScript") end

	function C:TurnValve()
		local n = self.isTrigger2 and "02" or "01"
		self.OBJPipeValveWheelRotateMarker:Play(self)
		self:RegisterForAnimationEvent(self, "Trans" .. n)
		self:PlayAnimation("trigger" .. n)
	end

	function Ready:OnActivate(obj)
		self:GotoState("Animating")
		self:TurnValve()
	end

	-- the steam switch that followed TurnValve in Papyrus; `mine` is this valve's side
	local function switch(self, mine, other)
		local q = self.DLC1LD_Bthalft
		if steam(self, mine):IsSteamDisabled() then
			steam(self, mine):EnableSteam()
			steam(self, "DLC1LD_FXSteamCenter"):EnableSteam()
			return
		end
		steam(self, mine):DisableSteam()
		if q:GetStage() == 45 then q:SetStage(46) end
		if not steam(self, other):IsSteamDisabled() then return end
		if q:GetStage() == 46 then q:SetStage(1) end
		steam(self, "DLC1LD_FXSteamCenter"):DisableSteam()
		steam(self, "DLC1LD_FXSteamForge"):DisableSteam()
		if q:GetStage() == 46 then q:SetStage(47) end
		if q:GetStageDone(58) and not q:GetStageDone(59) then q:SetStage(59) end
	end

	function Animating:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "Trans02" then
			self.isTrigger2 = false
		elseif asEventName == "Trans01" then
			self.isTrigger2 = true
		else
			return
		end
		if self.isRightValve then
			switch(self, "DLC1LD_FXSteamRight", "DLC1LD_FXSteamLeft")
		else
			switch(self, "DLC1LD_FXSteamLeft", "DLC1LD_FXSteamRight")
		end
		self:GotoState("Ready")
	end
end

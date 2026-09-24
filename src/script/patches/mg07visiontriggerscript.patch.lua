-- pex: ontriggerenter ee88c6f1
-- Four blocks, each `MoveTo`+`Enable` then a wait for that alias's 3D, gated by SceneCounter
-- thresholds checked once each. They run in Papyrus source order, one blocking the next, so this
-- is one stage per alias; a stage whose threshold fails has no wait and falls straight through in
-- the same tick, as the original's zero-iteration while loop would.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "AwaitAtmah", "AwaitGirduin", "AwaitElvali", "AwaitTakes")
	C.__vars.stage = C.Stage.Idle
	C.__vars.TickRate = rt.float(0.1)

	local function player() return rt.static("Game", "GetPlayer") end
	local function counter(self) return rt.cast(self.MG07, "mg07questscript").SceneCounter end

	function C:OnTriggerEnter(ActionRef)
		if self.stage ~= C.Stage.Idle then return end -- a run under way drops a re-entry
		if ActionRef ~= player() then return end
		if self.MG07:GetStage() < 10 then return end
		self.MG07SavosGhostAlias:GetReference():MoveTo(self.MarkerSavos, 0.0, 0.0, 0.0, true)
		self.MG07SavosGhostAlias:GetReference():Enable(true)
		self.MG07GhostEnableParentAlias:GetReference():Enable(true)
		self.stage = C.Stage.AwaitAtmah
		if counter(self) <= 5 then
			self.MG07HafnarGhostAlias:GetReference():MoveTo(self.MarkerHafnar, 0.0, 0.0, 0.0, true)
			self.MG07HafnarGhostAlias:GetReference():Enable(true)
			self.MG07AtmahGhostAlias:GetReference():MoveTo(self.MarkerAtmah, 0.0, 0.0, 0.0, true)
			self.MG07AtmahGhostAlias:GetReference():Enable(true)
		end
		self:OnTick()
	end

	function C:OnTick()
		if self.stage == C.Stage.AwaitAtmah then
			if counter(self) <= 5 and self.MG07AtmahGhostAlias and not self.MG07AtmahGhostAlias:GetReference():Is3DLoaded() then return end
			self.stage = C.Stage.AwaitGirduin
			if counter(self) <= 2 then
				self.MG07GirduinGhostAlias:GetReference():MoveTo(self.MarkerGirduin, 0.0, 0.0, 0.0, true)
				self.MG07GirduinGhostAlias:GetReference():Enable()
			end
		end
		if self.stage == C.Stage.AwaitGirduin then
			if counter(self) <= 2 and self.MG07GirduinGhostAlias and not self.MG07GirduinGhostAlias:GetReference():Is3DLoaded() then return end
			self.stage = C.Stage.AwaitElvali
			if counter(self) <= 3 then
				self.MG07ElvaliGhostAlias:GetReference():MoveTo(self.MarkerElvali, 0.0, 0.0, 0.0, true)
				self.MG07ElvaliGhostAlias:GetReference():Enable()
			end
		end
		if self.stage == C.Stage.AwaitElvali then
			if counter(self) <= 3 and self.MG07ElvaliGhostAlias and not self.MG07ElvaliGhostAlias:GetReference():Is3DLoaded() then return end
			self.stage = C.Stage.AwaitTakes
			if counter(self) <= 4 then
				self.MG07TakesGhostAlias:GetReference():MoveTo(self.MarkerTakes, 0.0, 0.0, 0.0, true)
				self.MG07TakesGhostAlias:GetReference():Enable()
			end
		end
		if self.stage == C.Stage.AwaitTakes then
			if counter(self) <= 4 and self.MG07TakesGhostAlias and not self.MG07TakesGhostAlias:GetReference():Is3DLoaded() then return end
			local MG07Script = rt.cast(self.MG07, "mg07questscript")
			MG07Script.SceneCounter = MG07Script.SceneCounter + 1
			self.VisionScene:Start()
			self:Disable()
			self.stage = C.Stage.Idle
		end
	end
end

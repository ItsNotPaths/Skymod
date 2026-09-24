-- pex: setnewhome 4921ba70
-- SetNewHome: two short waits (0.1s to toggle the moving package, 0.01s more before an optional
-- warp) become one timer and a two-step sequence. Message.Show at the end is not rewritten: it
-- yields transparently (script-rewrite.md, "Menus that pause the world").
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "PetFramework: " .. msg) end

return function(C)
	C.Home = rt.sequence("Idle", "Toggling", "Warping")
	C.__vars.homeStage = C.Home.Idle
	C.__vars.homeT = rt.timer(0.0)
	C.__vars.pendingHome = rt.form("ReferenceAlias")
	C.__vars.pendingWarp = rt.bool(false)
	local S = C.Home
	rt.params(C, "SetNewHome", { { "newLocation" }, { "dismiss", true }, { "doWarp", false } })

	local function finish(self)
		self.PetFramework_PetDismissMessage:Show()
		self.PetFramework_ParentQuest:DecrementPetCount()
		trace("Pet Count: " .. tostring(self.PetFramework_ParentQuest:GetCurrentPetCount()))
	end

	function C:SetNewHome(newLocation, dismiss, doWarp)
		if self.homeStage ~= S.Idle then
			trace("SetNewHome dropped: a move is under way")
			return
		end
		trace("Set New Home called from actor proxy")
		self:WaitForPlayer(false)
		self.MovingTogglePackageOn = true
		self.PetRefAlias:GetActorReference():EvaluatePackage()
		self.PetHomeMarker:ForceRefTo(newLocation:GetReference())
		if dismiss then
			self.PetRefAlias:GetActorReference():SetFactionRank(self.PetFramework_PetFollowingFaction, 0)
		end
		self.pendingHome, self.pendingWarp = newLocation, doWarp
		self.homeStage = S.Toggling
		self.homeT = 0.1
	end

	function C:OnTick()
		if self.homeStage == S.Idle or self.homeT > 0 then return end
		if self.homeStage == S.Toggling then
			self.MovingTogglePackageOn = false
			self.PetRefAlias:GetActorReference():EvaluatePackage()
			if self.pendingWarp then
				self.homeStage = S.Warping
				self.homeT = self.homeT + 0.01
				return
			end
			self.homeStage = S.Idle
			return finish(self)
		end
		self.PetRefAlias:GetReference():MoveTo(self.pendingHome:GetReference(), 0.0, 0.0, 0.0, false)
		self.homeStage = S.Idle
		finish(self)
	end
end

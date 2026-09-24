-- pex: loadedclosed.onbeginstate bbfc59c8
-- pex: loadedclosed.openup e3677b99
-- pex: loadedopened.inscribe 30b7165f
-- pex: loadedopened.onanimationevent eeadd98c
-- The stand waited on its buttons one after another (Open waits for the button's "Done"), on the
-- inscribed copy's 3D, and on its own "Close". Now OnTick polls those facts: a button's state, the
-- 3D, the animation. `raising` is the button being raised, `old_version` the copy to hide.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "OpeningUp", "Inscribing", "Closing")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.raising = rt.int(0)
	C.__vars.old_version = rt.form("ObjectReference")
	C.__vars.TickRate = rt.float(0.1)
	local LoadedClosed, LoadedOpened, Busy = rt.state(C, "loadedClosed"), rt.state(C, "loadedOpened"), rt.state(C, "busy")

	local function button(self, n) return rt.cast(self["Button" .. n], "DA04ButtonScript") end
	local function settled(self, n) return button(self, n):GetState() ~= "Busy" end

	function LoadedClosed:OnBeginState()
		self.raising = 1
		button(self, 1):Open()
		self:OnTick()
	end

	function LoadedClosed:OnTick()
		if self.raising == 1 and settled(self, 1) then
			self.raising = 2
			button(self, 2):Open()
		end
		if self.raising == 2 and settled(self, 2) then self.raising = 0 end
	end

	function LoadedClosed:OpenUp()
		self:GotoState("busy")
		self.step = S.OpeningUp
		button(self, 3):Open()
		self:OnTick()
	end

	function LoadedOpened:Inscribe()
		self:GotoState("busy")
		for n = 1, 4 do button(self, n):Close() end
		self.InscribedVersion:Enable()
		self.old_version = self:GetReference()
		self:ForceRefTo(self.InscribedVersion)
		self.step = S.Inscribing
		self:OnTick()
	end

	function LoadedOpened:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self:GetReference() or asEventName ~= "LoopDone" then return end
		self:GotoState("busy")
		self.step = S.Closing
		self:GetReference():PlayAnimation("Close")
	end

	function Busy:OnTick()
		local ref = self:GetReference()
		if self.step == S.OpeningUp and settled(self, 3) then
			self.step = S.Idle
			ref:PlayAnimation("Open")
			self:GotoState("loadedOpened")
		elseif self.step == S.Inscribing and self.InscribedVersion:Is3DLoaded() then
			self.step = S.Idle
			self.old_version:Disable()
			ref:PlayAnimation("StartClose")
			self:GotoState("loadedInscribed")
		elseif self.step == S.Closing and not ref:IsAnimRunning("Close") then
			self.step = S.Idle
			ref:PlayAnimation("StartDown")
			self:UnregisterForAnimationEvent(ref, "LoopDone")
			self:GotoState("loadedClosed")
		end
	end
end

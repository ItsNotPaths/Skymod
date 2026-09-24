-- pex: displayfish 29f369fc
-- pex: positionfishanddisablephysics a729717c
-- PositionFishAndDisablePhysics polled Is3DLoaded on the dropped fish, then set its motion type and
-- moved it to a size-matched marker. DisplayFish ran that inline, then cleared BlockActivation once
-- it returned. Now the fish ref is a fact (pendingFish); OnTick finishes the positioning and the
-- BlockActivation(false)/ForceRefTo tail that used to follow the call in DisplayFish.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.pendingFish = rt.form("ObjectReference")

	function C:DisplayFish(akFish)
		local theFish = self.plaquecontainer:DropObject(akFish, 1)
		if not theFish then return end
		self:GetLinkedRef(self.ccbgssse001_fishplaqueactivatorkw):MoveTo{ akTarget = self, abMatchRotation = false }
		self:PositionFishAndDisablePhysics(theFish)
	end

	function C:PositionFishAndDisablePhysics(akFishOnDisplayRef)
		if not akFishOnDisplayRef then return end
		if self.pendingFish then return end -- a second start while one is under way is dropped
		akFishOnDisplayRef:MoveTo(self.playerref)
		akFishOnDisplayRef:BlockActivation(true)
		self.pendingFish = akFishOnDisplayRef
	end

	function C:OnTick()
		local f = self.pendingFish
		if not f then return end
		if not f:Is3DLoaded() then return end
		self.pendingFish = rt.None

		f:SetMotionType(rt.get(self, "Motion_Keyframed"), false)
		local akFishForm = f:GetBaseObject()
		local displayMarker
		if self.ccbgssse001_fishplaquesmallfishlist:HasForm(akFishForm) then
			displayMarker = self:GetLinkedRef(self.ccbgssse001_fishplaquesmallfishmarkerkw)
		elseif self.ccbgssse001_fishplaquelargefishlist:HasForm(akFishForm) then
			displayMarker = self:GetLinkedRef(self.ccbgssse001_fishplaquelargefishmarkerkw)
		elseif self.ccbgssse001_fishplaquexlargefishlist:HasForm(akFishForm) then
			displayMarker = self:GetLinkedRef(self.ccbgssse001_fishplaquexlargefishmarkerkw)
		end
		f:MoveTo(displayMarker)

		-- DisplayFish's own tail, moved here since it must follow positioning, not the start of it.
		self.plaquefishalias:ForceRefTo(f)
		f:BlockActivation(false)
	end
end

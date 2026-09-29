-- pex: waitingforpickup.onactivate 2a892a26
-- pex: waitingforplacement.onactivate 640a641d
-- Placing or taking a gem played PlaceX or TakeX and waited for "Done" in BusyState before
-- lighting the portal (or giving the gem back). Now the event finishes it; `moving_gem` is the
-- gem in the socket's hands and `placing` says which way. With several gems it asks which, and
-- OnTick in BusyState places the answer.
local rt = require('skymod.rt')

local COLORS = { "Blue", "Green", "Orange", "Purple", "White" } -- LinkCustom01..05 in this order

return function(C)
	C.__vars.moving_gem = rt.form("Form")
	C.__vars.placing = rt.bool(false)
	C.__vars.asking = rt.bool(false)
	local Placement, Pickup, Busy = rt.state(C, "WaitingForPlacement"), rt.state(C, "WaitingForPickup"), rt.state(C, "BusyState")

	local function player() return rt.static("Game", "GetPlayer") end
	local function gem(self, i) return self["PortalGem" .. COLORS[i] .. "Key"] end
	local function slot(self, i) return self:GetLinkedRef(self["LinkCustom0" .. (i + 1)]) end
	local function index_of(self, g)
		for i = 0, 4 do if gem(self, i) == g then return i end end
	end

	local function place(self, i)
		player():RemoveItem(gem(self, i), 1)
		self.moving_gem = gem(self, i)
		self.placing = true
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Place" .. COLORS[i])
	end

	function Placement:OnActivate(akActionRef)
		if akActionRef ~= player() then return end
		self:GotoState("BusyState")
		local count = player():GetItemCount(self.PortalGemKeyList)
		if count == 0 then
			self.PortalGemPlaceMessageDENIED:Show()
			return self:GotoState("WaitingForPlacement")
		end
		if count == 1 then
			for i = 0, 4 do
				if player():GetItemCount(gem(self, i)) == 1 then return place(self, i) end
			end
			return -- as Papyrus: no single gem matched, the socket stays busy
		end
		self.asking = true
		self.PortalGemPlaceMessage:Show()
	end

	function Busy:OnTick()
		if not self.asking then return end
		self.MessageOption = self.PortalGemPlaceMessage:Answer()
		if self.MessageOption < 0 then return self.PortalGemPlaceMessage:Show() end
		self.asking = false
		if self.MessageOption >= 0 and self.MessageOption <= 4 then return place(self, self.MessageOption) end
		if self.MessageOption == 5 then self:GotoState("WaitingForPlacement") end
	end

	function Pickup:OnActivate(akActionRef)
		if akActionRef ~= player() then return end
		self:GotoState("BusyState")
		local i = index_of(self, self.CurrentlyPlacedGem)
		if not i then return end
		rt.static("Sound", "StopInstance", self.PortalLoopInstance)
		slot(self, i):DisableNoWait()
		self:GetLinkedRef():DisableNoWait()
		self.moving_gem = gem(self, i)
		self.placing = false
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Take" .. COLORS[i])
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" or not self.moving_gem then return end
		local g = self.moving_gem
		self.moving_gem = rt.None
		if self.placing then
			slot(self, index_of(self, g)):Enable()
			self.PortalLoopInstance = self.OBJParagonAmbienceLPMSD:Play(self:GetLinkedRef(self.LinkCustom10))
			self:GetLinkedRef():Enable()
			self.CurrentlyPlacedGem = g
			self:GotoState("WaitingForPickup")
		else
			player():AddItem(g, 1)
			self.CurrentlyPlacedGem = rt.None
			self:GotoState("WaitingForPlacement")
		end
	end
end

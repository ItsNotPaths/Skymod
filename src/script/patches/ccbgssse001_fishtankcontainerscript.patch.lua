-- pex: onactivate df9a3d21
-- pex: updatefish b5bd4e08
-- pex: updatesinglefish e7ef2632
-- OnActivate opened the loot menu, waited 0.25 s, then called UpdateFish. Opening the loot menu
-- here is not one of the three menu-pausing natives (script-api.md section 7), so the 0.25 s is a
-- plain timer, not menu-gated. UpdateFish placed three fish in turn, each waiting for its own 3D
-- load then a random settle delay; the three slots do not depend on each other, so they now run
-- side by side, gated by the class's own "UpdatingFish" busy state.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.activateT = rt.timer(nil)
	C.__vars.slot1t = rt.timer(nil)
	C.__vars.slot2t = rt.timer(nil)
	C.__vars.slot3t = rt.timer(nil)
	C.__vars.slot1settled = rt.bool(false)
	C.__vars.slot2settled = rt.bool(false)
	C.__vars.slot3settled = rt.bool(false)

	local function start_slot(self, n)
		local s = string.format("%02d", n)
		local ref = self["placedfishref" .. s]
		if ref then
			ref:StopPathing()
			ref:Disable()
			ref:Delete()
			self["placedfishref" .. s] = nil
		end
		self["slot" .. n .. "settled"] = false
		self["slot" .. n .. "t"] = nil
		local target = self["placedfishform" .. s]
		if not target then return end
		local marker = self:GetLinkedRef(self["ccbgssse001_fishtankmarkerkw" .. s])
		local placed = marker:PlaceAtMe(target)
		self["placedfishref" .. s] = placed
		placed:StartPathing(marker)
	end

	local function slot_busy(self, n)
		local s = string.format("%02d", n)
		return self["placedfishref" .. s] and not self["slot" .. n .. "settled"]
	end

	function C:UpdateFish()
		if self:GetState() == "UpdatingFish" then return end -- a second start is dropped
		if not self:Is3DLoaded() then
			self.queuedupdate = true
			return
		end
		self:GotoState("UpdatingFish")
		for n = 1, 3 do start_slot(self, n) end
	end

	function C:OnActivate(akActionRef)
		self.ccbgssse001_fishtankroomleftmsg:Show(self.maxfishallowed - self.currentfishcount)
		if self.fishtankactivated:GetValueInt() == 0 then
			self.fishtankfirsttimemsg:Show()
			self.fishtankactivated:SetValue(1)
		end
		self:Activate(rt.static("Game", "GetPlayer"), true)
		self.activateT = 0.25
	end

	function C:OnTick()
		if self.activateT then
			if self.activateT > 0 then return end
			self.activateT = nil
			self:UpdateFish()
			return
		end
		if self:GetState() ~= "UpdatingFish" then return end
		for n = 1, 3 do
			local s = string.format("%02d", n)
			local ref = self["placedfishref" .. s]
			if ref and not self["slot" .. n .. "settled"] then
				local t = self["slot" .. n .. "t"]
				if t == nil then
					if ref:Is3DLoaded() then
						ref:SetScale(0.75) -- on load, before the settle wait, as in Papyrus
						self["slot" .. n .. "t"] = rt.static("Utility", "RandomFloat", 0.0, 0.3)
					end
				elseif t <= 0 then
					self["slot" .. n .. "settled"] = true
				end
			end
		end
		if not (slot_busy(self, 1) or slot_busy(self, 2) or slot_busy(self, 3)) then
			self:GotoState("")
		end
	end
end

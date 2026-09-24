-- pex: fragment_17 ddd15635
-- pex: fragment_35 87fcfbce
-- pex: fragment_36 3b000c9b
-- pex: fragment_38 c2f9d71c
-- pex: fragment_39 b340be31
-- pex: fragment_40 4c4fd407
-- Each fragment played a wayshrine light beam and waited for its "EndAnim", activated the shrine
-- with its prelate, and (all but 40) waited 5 s before enabling fast travel again. Now a stage
-- per fragment, stepped by OnTick after the split fragments' ticks.
local rt = require('skymod.rt')

local SHRINES = {
	fragment_17 = { "pDLC1Lightbeam00Ref", "pDLC1VQ07Wayshrine00Ref", "Alias_DLC1VQ07Prelate00Alias", true },
	fragment_35 = { "pDLC1Lightbeam01Ref", "pDLC1VQ07Wayshrine01Ref", "Alias_DLC1VQ07Prelate01Alias", true },
	fragment_36 = { "pDLC1Lightbeam02Ref", "pDLC1VQ07Wayshrine02Ref", "Alias_DLC1VQ07Prelate02Alias", true },
	fragment_38 = { "pDLC1Lightbeam03Ref", "pDLC1VQ07Wayshrine03Ref", "Alias_DLC1VQ07Prelate03Alias", true },
	fragment_39 = { "pDLC1Lightbeam04Ref", "pDLC1VQ07Wayshrine04Ref", "Alias_DLC1VQ07Prelate04Alias", true },
	fragment_40 = { "pDLC1WayshrineBeamDarkfallRef", "pDLC1VQ07DarkfallWayshrine01Ref", "Alias_DLC1VQ07GeleborAlias", false },
}

return function(C)
	C.Shrine = rt.sequence("Idle", "Beam", "Travel")
	local S = C.Shrine
	local split_tick = C.__fn.ontick

	for frag, s in pairs(SHRINES) do
		C.__vars[frag .. "_step"] = S.Idle
		C.__vars[frag .. "_t"] = rt.timer(0.0)
		C.__fn[frag] = function(self)
			if self.vars[frag .. "_step"] ~= S.Idle then return end
			self[s[0]]:PlayAnimation("playanim01")
			self.vars[frag .. "_step"] = S.Beam
		end
	end

	local function shrine_tick(self, frag, s)
		local step = self.vars[frag .. "_step"]
		if step == S.Beam and not self[s[0]]:IsAnimRunning("playanim01") then
			self[s[1]]:Activate(self[s[2]]:GetActorRef())
			if not s[3] then
				self.vars[frag .. "_step"] = S.Idle
				return
			end
			self.vars[frag .. "_step"] = S.Travel
			self.vars[frag .. "_t"] = 5.0
		elseif step == S.Travel and self.vars[frag .. "_t"] <= 0 then
			self.vars[frag .. "_step"] = S.Idle
			rt.static("Game", "EnableFastTravel")
		end
	end

	function C:OnTick()
		split_tick(self)
		for frag, s in pairs(SHRINES) do shrine_tick(self, frag, s) end
	end
end

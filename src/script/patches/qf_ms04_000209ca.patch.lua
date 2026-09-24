-- pex: fragment_40 b2d00efd
-- pex: fragment_54 7e33e7fd
-- pex: fragment_55 fbb2b259
-- pex: fragment_56 72498d5c
-- pex: fragment_57 2c191679
-- pex: fragment_58 9341c375
-- pex: fragment_59 95c80bd5
-- pex: fragment_60 f1b64e91
-- pex: fragment_61 51d3dbed
-- pex: fragment_62 a1c69ee9
-- pex: fragment_63 2147ae89
-- pex: fragment_64 297a7d5d
-- pex: fragment_65 921aede3
-- pex: fragment_66 6228a922
-- pex: fragment_67 8bf51db9
-- pex: fragment_68 40809e9a
-- pex: fragment_69 919d9688
-- pex: fragment_70 43f1f5d4
-- pex: fragment_71 6eee041b
-- pex: fragment_72 dea1bf19
-- pex: fragment_73 a021d772
-- pex: fragment_77 d1487bf1
-- pex: fragment_78 83f27214
-- pex: fragment_79 6bc4e0e3
-- pex: fragment_80 9e9aca84
-- Each vision fragment faded the four ghosts in or out one after another (0.1 s each), then set
-- the next stage or moved them off screen. Now a run named for the fragment fades each ghost in
-- turn, waiting on its state, and does the fragment's tail once the last one has settled.
local rt = require('skymod.rt')

local GHOSTS = { "WTR", "FDF", "Breya", "Drennen" }
local THREE = { "WTR", "FDF", "Breya" }

return function(C)
	local function ref(self, alias) return self["Alias_MS04" .. alias]:GetRef() end

	local function move(self, who, markers)
		for _, g in ipairs(who) do ref(self, g):MoveTo(ref(self, markers .. g .. "Marker")) end
	end

	local function set_enabled(self, on, ...)
		for _, a in ipairs({ ... }) do
			if on then ref(self, a):Enable() else ref(self, a):Disable() end
		end
	end

	local function spheres(self, on) set_enabled(self, on, "Vision4DwarvenSphere1", "Vision4DwarvenSphere2") end
	local function centurions(self, on) set_enabled(self, on, "DwarvenCenturion1", "DwarvenCenturion2") end

	-- fade in after moving `who` to vision n's markers, then set `stage`
	local function show(n, who, stage, before, after)
		return {
			shown = true,
			before = function(self)
				move(self, who, "Vision" .. n)
				if before then before(self) end
			end,
			after = function(self)
				if after then after(self) end
				self:SetStage(stage)
			end,
		}
	end

	local function hide(after) return { shown = false, after = after } end
	local function offscreen(n, who) return function(self) move(self, who, "OffScreenCell" .. n) end end

	local RUNS = {
		Fragment_66 = show(2, GHOSTS, 200),
		Fragment_67 = show(3, { "WTR", "Drennen" }, 250),
		Fragment_68 = show(4, { "WTR", "Breya", "Drennen" }, 300, function(self) spheres(self, true) end),
		Fragment_69 = show(5, { "FDF", "Breya" }, 350),
		Fragment_70 = show(6, GHOSTS, 400),
		Fragment_71 = show(7, { "Breya" }, 450),
		Fragment_72 = show(8, { "WTR", "Breya" }, 500),
		Fragment_73 = show(9, { "WTR", "FDF", "Drennen" }, 550),
		Fragment_80 = show(10, GHOSTS, 600),
		Fragment_79 = show(11, THREE, 650),
		Fragment_78 = show(12, THREE, 700),
		Fragment_77 = show(13, { "FDF", "Breya" }, 750, nil, function(self) centurions(self, true) end),
		Fragment_40 = hide(offscreen(1, GHOSTS)),
		Fragment_54 = hide(offscreen(1, GHOSTS)),
		Fragment_55 = hide(offscreen(1, GHOSTS)),
		Fragment_56 = hide(function(self)
			spheres(self, false)
			offscreen(2, GHOSTS)(self)
		end),
		Fragment_57 = hide(offscreen(2, GHOSTS)),
		Fragment_58 = hide(offscreen(2, GHOSTS)),
		Fragment_59 = hide(offscreen(2, GHOSTS)),
		Fragment_60 = hide(offscreen(2, GHOSTS)),
		Fragment_61 = hide(offscreen(2, GHOSTS)),
		Fragment_62 = hide(function(self)
			offscreen(3, THREE)(self)
			ref(self, "Drennen"):Disable()
		end),
		Fragment_63 = hide(offscreen(3, THREE)),
		Fragment_64 = hide(offscreen(3, THREE)),
		Fragment_65 = hide(function(self)
			centurions(self, false)
			offscreen(3, THREE)(self)
			self:SetStage(800)
		end),
	}

	C.Fade = rt.sequence("Idle",
		"Fragment_66", "Fragment_67", "Fragment_68", "Fragment_69", "Fragment_70", "Fragment_71",
		"Fragment_72", "Fragment_73", "Fragment_80", "Fragment_79", "Fragment_78", "Fragment_77",
		"Fragment_40", "Fragment_54", "Fragment_55", "Fragment_56", "Fragment_57", "Fragment_58",
		"Fragment_59", "Fragment_60", "Fragment_61", "Fragment_62", "Fragment_63", "Fragment_64",
		"Fragment_65")
	C.__vars.fade = C.Fade.Idle
	C.__vars.fadeGhost = rt.int(0) -- the ghost the run waits on, an index into GHOSTS
	local Fading = rt.state(C, "Fading")

	local function ghost(self)
		return rt.cast(ref(self, GHOSTS[self.fadeGhost]), "MS04MemmoryEffectScript")
	end

	local function fade_ghost(self)
		local g = ghost(self)
		if RUNS[self.fade.name].shown then g:FadeIn() else g:FadeOut() end
	end

	for name, run in pairs(RUNS) do
		C[name] = function(self)
			if self.fade ~= C.Fade.Idle then return end -- a run happens once; visions never overlap
			if run.before then run.before(self) end
			self.fade = C.Fade[name]
			self.fadeGhost = 0
			self:GotoState("Fading")
			fade_ghost(self)
		end
	end

	function Fading:OnTick()
		local g = ghost(self)
		if g and g:GetState() ~= "" then return end
		if self.fadeGhost < #GHOSTS - 1 then
			self.fadeGhost = self.fadeGhost + 1
			return fade_ghost(self)
		end
		local run = RUNS[self.fade.name]
		self.fade = C.Fade.Idle
		self:GotoState("")
		run.after(self)
	end
end

-- pex: ready.onactivate 81b07fe2 1302dd3b
-- pex: scanforrecipes bac4b688 98342ff2
-- ScanForRecipes scanned a formlist (no wait), and on a match waited 0.33 s before giving the
-- item and swapping the recipe book; the match index is a fact (`scanI`) that survives the wait.
-- OnActivate (ready state) tries the Sigil lists first if installed (an extra 0.1 s gap after),
-- then the normal lists unless the Sigil scan already found something; `oaStage` carries which
-- scan is in flight. The class already ticks (S6 split, FillDynamicList's timer); call it first.
local rt = require('skymod.rt')

local OA = rt.sequence("Idle", "Sigil", "SigilGap", "Regular")

return function(C)
	C.__vars.scanBusy = rt.bool(false)
	C.__vars.scanFound = rt.bool(false)
	C.__vars.scanRecipes = rt.form("FormList")
	C.__vars.scanResults = rt.form("FormList")
	C.__vars.scanI = rt.int(0)
	C.__vars.scanT = rt.timer(0.0)
	C.__vars.oaStage = OA.Idle
	C.__vars.oaT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:ScanForRecipes(Recipes, Results)
		if self.scanBusy then return end -- a run happens once
		local i, t, foundIdx = 0, Recipes:GetSize(), nil
		while i < t do
			local currentRecipe = rt.cast(Recipes:GetAt(i), "formlist")
			if currentRecipe ~= rt.None and self:scanSubList(currentRecipe) then
				self:removeIngredients(currentRecipe)
				foundIdx = i
				break
			end
			i = i + 1
		end
		if foundIdx then
			self.scanRecipes, self.scanResults, self.scanI = Recipes, Results, foundIdx
			self.scanBusy, self.scanT = true, 0.33
		else
			self.scanFound = false
		end
	end

	local Ready = rt.state(C, "ready")
	function Ready:OnActivate(actronaut)
		self:GotoState("busy")
		if self.sigilstoneinstalled then
			self:ScanForRecipes(self.sigilrecipelist, self.sigilresultlist)
			self.oaStage = OA.Sigil
		else
			self:ScanForRecipes(self.recipelist, self.resultlist)
			self.oaStage = OA.Regular
		end
	end

	local function finish_scan(self)
		self.scanBusy = false
		local i, Results = self.scanI, self.scanResults
		local player = rt.static("Game", "GetPlayer")
		local resultList = rt.cast(Results:GetAt(i), "formlist")
		if resultList ~= rt.None then
			player:AddItem(resultList:GetAt(0), resultList:GetSize())
		else
			player:AddItem(Results:GetAt(i))
		end
		local book = self.recipebookliststatic:GetAt(i)
		if self:GetLinkedRef():GetItemCount(book) > 0 then
			self:GetLinkedRef():RemoveItem(book)
			player:AddItem(book)
		end
		if self.lastsummonedobject then
			local dead = rt.cast(self.lastsummonedobject, "actor"):IsDead()
			if dead then
				self.lastsummonedobject:RemoveAllItems(self.dropbox, false, true)
				self.lastsummonedobject:Disable()
				self.lastsummonedobject:Delete()
			end
		end
		self.scanFound = true
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)

		if self.scanBusy and self.scanT <= 0 then finish_scan(self) end

		if self.oaStage == OA.Sigil then
			if self.scanBusy then return end
			self.oaStage, self.oaT = OA.SigilGap, 0.1
		elseif self.oaStage == OA.SigilGap then
			if self.oaT > 0 then return end
			if not self.sigilstoneinstalled or not self.scanFound then
				self:ScanForRecipes(self.recipelist, self.resultlist)
				self.oaStage = OA.Regular
			else
				self.oaStage = OA.Idle
				self:GotoState("ready")
			end
		elseif self.oaStage == OA.Regular then
			if self.scanBusy then return end
			self.oaStage = OA.Idle
			self:GotoState("ready")
		end
	end
end

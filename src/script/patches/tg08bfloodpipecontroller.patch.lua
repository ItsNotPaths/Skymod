-- pex: broken.onbeginstate 42c9fba1
-- pex: intact.onbeginstate 26708315
-- pex: submerged.onbeginstate 85683ac3
-- pex: tg08enablelinkchain 511ee93b
-- pex: tg08enablewaterstream 387a543b
-- pex: onactivate 3b33c331
-- pex: tg08matchtranslatelinkchain f7663013
-- pex: tg08matchwaterstream cf2ff2de
-- Four functions blocked on Utility.Wait: enabling a chain of linked refs, dropping the water
-- stream to the plane, and matching each back up to its rest position. They are now start-and-
-- return machines (rt.sequence stages), and each OnBeginState waits on the ones it starts by
-- polling the stage, the way the Papyrus call itself used to block.
local rt = require('skymod.rt')

local Chain = rt.sequence("Idle", "Waiting")                              -- TG08EnableLinkChain
local Match = rt.sequence("Idle", "Stopping", "Rising", "Settling")       -- TG08MatchTranslateLinkChain
local Stream = rt.sequence("Idle", "Falling")                             -- TG08EnableWaterStream
local StreamMatch = rt.sequence("Idle", "Stopping", "Settling")           -- TG08MatchWaterStream
local Broken = rt.sequence("Idle", "AwaitSource", "Exploding", "StartStream", "AwaitStream",
    "PreSplash", "AwaitSplash", "Tail")
local Intact = rt.sequence("Idle", "AwaitChain", "Tail")

-- run advances one machine: while its wait is up, run the step for its stage. A step returns the
-- next stage, or nil to stay put (it may set a new wait first).
local function run(self, stage, wait, steps)
    while steps[self[stage]] and (not wait or self[wait] <= 0) do
        local nxt = steps[self[stage]](self)
        if not nxt then return end
        self[stage] = nxt
    end
end

-- ── TG08MatchTranslateLinkChain: per link, snap to the water plane, then rise to heightTarget ──
-- Papyrus redeclares afXAngle/afYAngle/afZAngle inside the While body, so they are 0 for the
-- first TranslateTo of every link, never carried from the one before.

local function match_link(self)
    local link = self.matchLink
    if not link then return Match.Idle end
    self.matchPos.x, self.matchPos.y = link:GetPositionX(), link:GetPositionY()
    self.matchPos.z = self.waterPlane:GetPositionZ()
    link:StopTranslation()
    self.matchWait = 0.2
    return Match.Stopping
end

local match_steps = {
    [Match.Stopping] = function(self)
        local p = self.matchPos
        self.matchLink:TranslateTo(p.x, p.y, p.z, 0.0, 0.0, 0.0, 5000.0, self.afMaxRotationSpeed)
        self.TG08MatchTranslateLinkChainTimer = 3.0
        return Match.Rising
    end,
    [Match.Rising] = function(self)
        local off = math.abs(self.matchPos.z - self.matchLink:GetPositionZ())
        if off >= 80 and self.TG08MatchTranslateLinkChainTimer >= 0 then return nil end -- wait(0.0): next tick
        self.matchLink:StopTranslation()
        self.matchWait = 0.2
        return Match.Settling
    end,
    [Match.Settling] = function(self)
        local link, p = self.matchLink, self.matchPos
        p.z = self.HeightTarget:GetPositionZ()
        link:TranslateTo(p.x, p.y, p.z, link:GetAngleX(), link:GetAngleY(), link:GetAngleZ(),
            self.afSpeed, self.afMaxRotationSpeed)
        self.matchLink = link:GetLinkedRef()
        return match_link(self)
    end,
}

-- ── TG08MatchWaterStream: drop to the plane, then rise to heightTarget ──
-- Papyrus sets TG08EnableWaterStreamTimer here but polls TG08MatchWaterStreamTimer, which nothing
-- ever sets; that condition is always false, so the shipped While body runs zero times. Reproduced
-- faithfully: the step between the two TranslateTo calls never gates on position.

local stream_match_steps = {
    [StreamMatch.Stopping] = function(self)
        local p = self.streamMatchPos
        self.streamMatchLink:TranslateTo(p.x, p.y, p.z, 0.0, 0.0, 0.0, 5000.0, self.afMaxRotationSpeed)
        self.streamMatchWait = 0.4 -- two Wait(0.2) with nothing between
        return StreamMatch.Settling
    end,
    [StreamMatch.Settling] = function(self)
        local link, p = self.streamMatchLink, self.streamMatchPos
        -- sic: the original passes HeightTarget's Z POSITION as the Z ANGLE here
        link:TranslateTo(p.x, p.y, p.z, link:GetAngleX(), link:GetAngleY(), self.HeightTarget:GetPositionZ(),
            self.afSpeed, self.afMaxRotationSpeed)
        return StreamMatch.Idle
    end,
}

-- ── TG08EnableWaterStream: drop the stream to the water plane, then match it ──

local stream_steps = {
    [Stream.Falling] = function(self)
        local off = math.abs(self.streamZ - self.streamLink:GetPositionZ())
        if off >= 30 and self.TG08EnableWaterStreamTimer >= 0 then return nil end
        self:TG08MatchWaterStream(self.WaterStream) -- the property, not the link, as in the original
        return Stream.Idle
    end,
}

-- ── TG08EnableLinkChain: the walk is immediate; only the wait for the last link is not ──
-- Four targets (Source/Intact/Splash/Sub) can each have a chain enable in flight at once, so each
-- gets its own chain/chainWait/chainTop/chainLast fields, keyed by this suffix.

local CHAIN_SUFFIXES = { "Source", "Intact", "Splash", "Sub" }
local CHAIN_TARGET_PROP = { Source = "SourcePipe", Intact = "IntactPipe", Splash = "Splash", Sub = "SubmergedEffect" }

local function make_chain_steps(suffix)
    return {
        [Chain.Waiting] = function(self)
            local last, top = self["chainLast" .. suffix], self["chainTop" .. suffix]
            if not last:IsEnabled() and self.TG08EnableLinkChainTimer >= 0 then
                self["chainWait" .. suffix] = 0.3
                return nil
            end
            if top == self.Splash then
                self.initialTranslationComplete = true
                self:TG08MatchTranslateLinkChain(top)
            end
            return Chain.Idle
        end,
    }
end

local chain_steps_by_suffix = {}
for _, suffix in ipairs(CHAIN_SUFFIXES) do
    chain_steps_by_suffix[suffix] = make_chain_steps(suffix)
end

local function chain_suffix_of(self, link)
    for _, suffix in ipairs(CHAIN_SUFFIXES) do
        if link == self[CHAIN_TARGET_PROP[suffix]] then return suffix end
    end
    return CHAIN_SUFFIXES[0] -- every call site passes one of the four; unreachable otherwise
end

-- ── intact OnBeginState: only the enable-chain call blocks the two disables after it ──

local intact_steps = {
    [Intact.AwaitChain] = function(self)
        if self.chainIntact ~= Chain.Idle or self.match ~= Match.Idle then return nil end
        return Intact.Tail
    end,
    [Intact.Tail] = function(self)
        if self.WaterStreamON then
            self.WaterStreamON = false
            self:TG08DisableLinkChain(self.WaterStream)
        end
        if self.SplashON then
            self.SplashON = false
            self:TG08DisableLinkChain(self.Splash)
        end
        return Intact.Idle
    end,
}

-- ── broken OnBeginState ──

local broken_steps = {
    [Broken.AwaitSource] = function(self)
        if self.chainSource ~= Chain.Idle or self.match ~= Match.Idle then return nil end
        if not self.IntactPipeON then return Broken.StartStream end
        self.IntactPipeON = false
        self.IntactPipe:PlaceAtMe(self.TG08PipeExplosion, 1, false, false)
        self.brokenWait = 0.2
        return Broken.Exploding
    end,
    [Broken.Exploding] = function(self)
        self:TG08DisableLinkChain(self.IntactPipe)
        return Broken.StartStream
    end,
    [Broken.StartStream] = function(self)
        if not self.WaterStreamON then
            self.WaterStreamON = true
            self:TG08EnableWaterStream(self.WaterStream)
        end
        return Broken.AwaitStream
    end,
    [Broken.AwaitStream] = function(self)
        if self.stream ~= Stream.Idle or self.streamMatch ~= StreamMatch.Idle then return nil end
        self.brokenWait = 0.1
        return Broken.PreSplash
    end,
    [Broken.PreSplash] = function(self)
        if self.SplashON then return Broken.Idle end
        self.SplashON = true
        self:TG08EnableLinkChain(self.Splash)
        return Broken.AwaitSplash
    end,
    [Broken.AwaitSplash] = function(self)
        if self.chainSplash ~= Chain.Idle or self.match ~= Match.Idle then return nil end
        self.brokenWait = 0.1
        return Broken.Tail
    end,
    [Broken.Tail] = function(self) return Broken.Idle end,
}

return function(C)
    local V = C.__vars
    -- absolute deadlines (GetCurrentRealTime() + n) become timers set to n
    V["::tg08enablelinkchaintimer_var"] = rt.timer(0.0)
    V["::tg08matchtranslatelinkchaintimer_var"] = rt.timer(0.0)
    V["::tg08enablewaterstreamtimer_var"] = rt.timer(0.0)

    for _, suffix in ipairs(CHAIN_SUFFIXES) do
        V["chain" .. suffix], V["chainWait" .. suffix] = Chain.Idle, rt.timer(0.0)
        V["chainTop" .. suffix], V["chainLast" .. suffix] = rt.form("ObjectReference"), rt.form("ObjectReference")
    end
    V.match, V.matchWait = Match.Idle, rt.timer(0.0)
    V.matchLink, V.matchPos = rt.form("ObjectReference"), rt.vec3()
    V.stream, V.streamLink, V.streamZ = Stream.Idle, rt.form("ObjectReference"), rt.float(0.0)
    V.streamMatch, V.streamMatchWait = StreamMatch.Idle, rt.timer(0.0)
    V.streamMatchLink, V.streamMatchPos = rt.form("ObjectReference"), rt.vec3()
    V.broken, V.brokenWait = Broken.Idle, rt.timer(0.0)
    V.intactStage = Intact.Idle
    V.syncStream = rt.bool(false) -- onActivate's MatchWaterStream, due once the splash match ends

    function C:TG08EnableLinkChain(link)
        local top, last = link, rt.None
        while link do
            link:Enable(false)
            last = link
            link = link:GetLinkedRef()
        end
        local suffix = chain_suffix_of(self, top)
        if self["chain" .. suffix] ~= Chain.Idle then return end -- this target's own chain already waits
        self["chainTop" .. suffix], self["chainLast" .. suffix] = top, last
        self.TG08EnableLinkChainTimer = 5.0
        self["chain" .. suffix], self["chainWait" .. suffix] = Chain.Waiting, 0.0
        run(self, "chain" .. suffix, "chainWait" .. suffix, chain_steps_by_suffix[suffix])
    end

    function C:TG08MatchTranslateLinkChain(link)
        if self.match ~= Match.Idle then return end -- dropped: one runs
        self.matchLink = link
        self.match = match_link(self)
    end

    function C:TG08EnableWaterStream(link)
        if self.stream ~= Stream.Idle then return end
        self.streamLink, self.streamZ = link, self.waterPlane:GetPositionZ()
        link:TranslateTo(link:GetPositionX(), link:GetPositionY(), self.streamZ,
            link:GetAngleX(), link:GetAngleY(), link:GetAngleZ(), self.waterFallSpeed, self.afMaxRotationSpeed)
        self.TG08EnableWaterStreamTimer = 8.0
        self.stream = Stream.Falling
    end

    function C:TG08MatchWaterStream(link)
        if self.streamMatch ~= StreamMatch.Idle then return end -- dropped: one runs
        local p = self.streamMatchPos
        p.x, p.y, p.z = link:GetPositionX(), link:GetPositionY(), self.waterPlane:GetPositionZ()
        self.streamMatchLink = link
        link:StopTranslation()
        self.streamMatch, self.streamMatchWait = StreamMatch.Stopping, 0.2
    end

    local Broke = rt.state(C, "broken")
    function Broke:OnBeginState()
        if self.broken ~= Broken.Idle then return end -- broken again while breaking: dropped
        if not self.SourcePipeON then
            self.SourcePipeON = true
            self:TG08EnableLinkChain(self.SourcePipe)
        end
        self.broken = Broken.AwaitSource
        run(self, "broken", "brokenWait", broken_steps)
    end

    local Intct = rt.state(C, "intact")
    function Intct:OnBeginState()
        if self.intactStage ~= Intact.Idle then return end -- entered again mid-wait: dropped
        if self.SourcePipeON then
            self.SourcePipeON = false
            self:TG08DisableLinkChain(self.SourcePipe)
        end
        if not self.IntactPipeON then
            self.IntactPipeON = true
            self:TG08EnableLinkChain(self.IntactPipe)
        end
        self.intactStage = Intact.AwaitChain
        run(self, "intactStage", nil, intact_steps)
    end

    local Sub = rt.state(C, "submerged")
    function Sub:OnBeginState()
        if self.WaterStreamON then
            self.WaterStreamON = false
            self:TG08DisableLinkChain(self.WaterStream)
        end
        if self.SplashON then
            self.SplashON = false
            self:TG08DisableLinkChain(self.Splash)
        end
        if not self.SubmergedEffectON then
            self.SubmergedEffectON = true
            self:TG08EnableLinkChain(self.SubmergedEffect) -- tail call: nothing follows
        end
    end

    function C:OnActivate(akActivator)
        if self.stateString ~= "SyncTranslate" then
            self:LocalGoToState(self.stateString)
        elseif self.initialTranslationComplete then
            if self.syncStream or self.match ~= Match.Idle then return end -- dropped: a match runs
            self:TG08MatchTranslateLinkChain(self.Splash)
            self.syncStream = true
        end
    end

    function C:OnTick()
        -- callees first, so a caller sees a callee finish in the tick it finishes
        run(self, "streamMatch", "streamMatchWait", stream_match_steps)
        run(self, "match", "matchWait", match_steps)
        run(self, "stream", nil, stream_steps)
        for _, suffix in ipairs(CHAIN_SUFFIXES) do
            run(self, "chain" .. suffix, "chainWait" .. suffix, chain_steps_by_suffix[suffix])
        end
        run(self, "broken", "brokenWait", broken_steps)
        run(self, "intactStage", nil, intact_steps)
        if self.syncStream and self.match == Match.Idle then
            self.syncStream = false
            self:TG08MatchWaterStream(self.WaterStream)
        end
    end
end

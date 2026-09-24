-- pex: fragment_7 75f7a1a5
-- Fragment_7 calls WICourier(Script).RemoveRefFromContainer, which no longer blocks
-- (wicourierscript.patch.lua). Its own writes afterward (objectives, guard factions,
-- SpawnInitialCrabs) touch none of the courier's item state, so Fragment_7 stays as converted.
return function(C)
end

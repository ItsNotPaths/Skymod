-- pex: onitemadded fb985ff9
-- OnItemAdded waited only through DisplayFish, which now returns at once; the Message.Show after it
-- pauses the world (script-api.md section 7). Unchanged.
return function(C) end

-- pex: transferholdcontrol bdfeecb9
-- TransferHoldControl: no change. It waited only inside setOwner, which now returns at once, and
-- nothing after its SetHoldOwnerByInt calls depends on the resets (its caller calls it last).
return function(C) end

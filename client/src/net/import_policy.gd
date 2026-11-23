class_name ImportPolicy
extends RefCounted
## Host policy for character imports. Imports carry played_offline;
## the host may allow or refuse them (stack amendment 3a).


static func allows(played_offline: bool, allow_offline_imports: bool) -> bool:
	if played_offline:
		return allow_offline_imports
	return true

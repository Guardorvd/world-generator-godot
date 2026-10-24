class_name GameContext
extends RefCounted
## The only process default is this composition root. Services themselves are instances.
## --script tools use the same locator; independent simulations pass ServiceScope explicitly.
static var _scope: ServiceScope
static var scope: ServiceScope:
	get:
		if _scope == null:
			_scope = ServiceScope.new()
		return _scope

static func reset() -> void:
	scope.reset()

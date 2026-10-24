class_name WorldStreamingState
extends RefCounted
## Состояние открытого окна и внешнего стриминга; не владеет WorldData.
var outer: OuterLand
var territory_center := Vector2i.ZERO
var available_rect := Rect2i()
var territory_revision := 0
var region_index := {}

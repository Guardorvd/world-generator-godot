extends RefCounted
## Дорожная сеть V2 (docs/ROAD_NETWORK_V2_PLAN_2026_11_21.md): петли и ответвления после остова V1.
## Включается флагом StageTrails.network_v2 (по умолчанию выключен). Ядро — C# (Roads.Network через
## Grid.native_grid()), публикация — общим конвейером StageTrails._add_trail.

## Версия результата V2: входит в ключ слоя places только при включённом флаге (WorldCache._road_layer_suffixes).
const VERSION := 1


## Суффикс ключа слоя places: пусто при выключенном флаге (ключ побайтно прежний).
static func cache_suffix(enabled: bool) -> String:
	return "|net=v2.%d" % VERSION if enabled else ""

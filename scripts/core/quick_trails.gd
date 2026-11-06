class_name QuickTrails
extends RefCounted
## Быстрый режим сети трасс (только для разработки): сеть строится на средней части мира и короче обычной,
## остальной мир — как обычно. Включается ключом запуска `-- --quick-trails` и только вне сборки для игрока
## (`OS.has_feature("template")` — экспортные шаблоны): в обычной игре и в сборке игрока режим недоступен и ни на что не влияет.
## Быстрый мир не должен попасть в обычный кэш и в обычные сохранения: у него своя папка кэша и своя папка сохранений.
## `trail_network_cost_test -- --part` строит ту же область с теми же пределами длины, поэтому тест и игра согласованы.

const FLAG := "--quick-trails"
const LABEL := "быстрый режим трасс"
const CACHE_DIR := "user://world_cache_quick"
const SAVES_DIR := "user://saves_quick"
## Длина сети: цель и предел собранных метров вместо обычных 12000 и 18000 м (trail_world_network.gd)
const LENGTH_TARGET := 2000.0
const WORK_LIMIT := 3000.0


static func active() -> bool:
	return not OS.has_feature("template") and OS.get_cmdline_user_args().has(FLAG)


## Средняя треть мира по каждой стороне
static func area(full: Rect2i) -> Rect2i:
	return Rect2i(full.position + full.size / 3, full.size / 3)


## Пределы сети для options у TrailWorldNetwork.build
static func options() -> Dictionary:
	return {length_target = LENGTH_TARGET, work_limit = WORK_LIMIT}


static func cache_dir() -> String:
	return CACHE_DIR if active() else "user://world_cache"


static func saves_dir() -> String:
	return SAVES_DIR if active() else "user://saves"

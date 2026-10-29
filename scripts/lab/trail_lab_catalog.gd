class_name TrailLabCatalog
extends RefCounted
## Готовые трассы Trail Lab: форма курса (Fixture.course), тип полотна, профиль составителя (TrailComposer.PROFILES,
## пусто — свои элементы формы) и полигон (Fixture.GROUNDS). Строятся тем же путём, что кнопка «Построить» в F2;
## ручное построение остаётся там. Первая — прежний полигон из четырёх полос с базовыми элементами (клавиши 1–4).
## Новые трассы — только в конец: номер плитки = номер в списке.

const LIST := [
	{title = "Полигон элементов", shape = 0, kind = "mountain", style = "", ground = "flat"},
	{title = "S-повороты · скоростная · холмы", shape = 1, kind = "mountain", style = "flow", ground = "hills"},
	{title = "S-повороты · прогулочная", shape = 1, kind = "trail", style = "leisure", ground = "flat"},
	{title = "Серпантин · горная · горы", shape = 2, kind = "mountain", style = "mountain", ground = "mountain"},
	{title = "Серпантин · техническая · холмы", shape = 2, kind = "trail", style = "technical", ground = "hills"},
	{title = "Кольцо · скоростная", shape = 3, kind = "mountain", style = "flow", ground = "flat"},
	{title = "Кольцо · спокойный поток · холмы", shape = 3, kind = "mountain", style = "calm_flow", ground = "hills"},
	{title = "Спираль · лесная", shape = 4, kind = "trail", style = "forest", ground = "flat"},
	{title = "Спираль · смешанная · горы", shape = 4, kind = "mountain", style = "mixed", ground = "mountain"},
	{title = "Восьмёрка · техническая", shape = 5, kind = "trail", style = "technical", ground = "flat"},
	{title = "Восьмёрка · скоростная · холмы", shape = 5, kind = "mountain", style = "flow", ground = "hills"},
	{title = "Flow-трасса · свои элементы", shape = 6, kind = "mountain", style = "", ground = "flat"},
	{title = "Flow-трасса · скоростная · горы", shape = 6, kind = "mountain", style = "flow", ground = "mountain"},
	{title = "Технический лес · свои элементы", shape = 7, kind = "trail", style = "", ground = "flat"},
	{title = "Технический лес · лесная · холмы", shape = 7, kind = "trail", style = "forest", ground = "hills"},
	{title = "Байк-парк · прыжки, настил, контруклон", shape = 8, kind = "mountain", style = "", ground = "flat"},
	{title = "Маршрут · смешанная", shape = 9, kind = "mountain", style = "mixed", ground = "flat"},
	{title = "Маршрут · горная · горы", shape = 9, kind = "mountain", style = "mountain", ground = "mountain"},
	{title = "Маршрут · прогулочная дорога · холмы", shape = 9, kind = "road", style = "leisure", ground = "hills"},
	{title = "Маршрут · узкая техническая · горы", shape = 9, kind = "trail", style = "technical", ground = "mountain"},
]


## Определения трассы номер index (пусто, если номера нет); заголовок курса — из списка.
static func routes(index: int, fixture: Script) -> Array[TrailDefinition]:
	if index < 0 or index >= LIST.size(): return []
	var spec: Dictionary = LIST[index]
	var kit: Array[TrailDefinition] = []
	# копии: полосы полигона — загруженные ресурсы, правка в лаборатории не должна менять их
	for d: TrailDefinition in fixture.course(spec.shape, spec.kind, spec.style, spec.ground):
		var copy := d.duplicate(true) as TrailDefinition
		if spec.shape != 0: copy.title = spec.title
		kit.append(copy)
	return kit

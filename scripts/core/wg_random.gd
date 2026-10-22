class_name WGRandom
extends RefCounted
## Генератор случайных чисел mulberry32 и хеши с сидом.
## Повторяет js/core/random.js бит в бит: вся арифметика 32-битная, числа хранятся без знака.

const MASK := 0xFFFFFFFF

var _a: int


func _init(seed_num: int) -> void:
	_a = seed_num & MASK


## Начать поток заново с другого зерна (без нового объекта: так дешевле в циклах по клеткам)
func reset(seed_num: int) -> void:
	_a = seed_num & MASK


## Следующее число в [0, 1)
func next_float() -> float:
	_a = (_a + 0x6d2b79f5) & MASK
	var a := _a
	var t := imul(a ^ (a >> 15), 1 | a)
	t = ((t + imul(t ^ (t >> 7), 61 | t)) & MASK) ^ t
	return float((t ^ (t >> 14)) & MASK) / 4294967296.0


## Независимое зерно системы. domain — постоянный смысловой ключ, а не номер в списке.
static func derive(seed_num: int, domain: String) -> int:
	return hash_string("%08x:%s" % [seed_num & MASK, domain])


## Независимый поток объекта в мировых координатах; создание не расходует другие потоки.
static func at(seed_num: int, domain: String, x: int = 0, y: int = 0) -> WGRandom:
	return WGRandom.new(hash_cell(derive(seed_num, domain), x, y, 0))


## Math.imul: младшие 32 бита произведения (результат без знака)
static func imul(a: int, b: int) -> int:
	a &= MASK
	b &= MASK
	return ((a & 0xFFFF) * b + ((((a >> 16) * b) & 0xFFFF) << 16)) & MASK


## Хеш строки (по кодам UTF-16, как charCodeAt в JS)
static func hash_string(s: String) -> int:
	var buf := s.to_utf16_buffer()
	var n := buf.size() >> 1
	var h := (1779033703 ^ n) & MASK
	for i: int in n:
		var c := buf[i * 2] | (buf[i * 2 + 1] << 8)
		h = imul(h ^ c, 3432918353)
		h = ((h << 13) | (h >> 19)) & MASK
	h = imul(h ^ (h >> 16), 2246822507)
	h = imul(h ^ (h >> 13), 3266489909)
	return (h ^ (h >> 16)) & MASK


## Зерно места (с 8.4): сид мира, клетка (x, y) в общих координатах мира и слой (что раскладывается).
## Одно и то же место даёт одни и те же числа, в каком бы порядке ни считались участки
## Множители меньше 2³¹, поэтому произведения помещаются в 64-битное целое без imul: так хеш можно развернуть
## в цикле по клеткам (StageVegetation.place_chunk)
static func hash_cell(seed_num: int, x: int, y: int, layer: int) -> int:
	var h := ((x * 73856093 + y * 19349663 + layer * 83492791) ^ seed_num) & MASK
	h = (((h >> 16) ^ h) * 0x45d9f3b) & MASK
	h = (((h >> 16) ^ h) * 0x45d9f3b) & MASK
	return (h >> 16) ^ h


## Быстрый хеш целочисленных координат -> [0, 1)
static func hash2(x: int, y: int, seed_num: int) -> float:
	var h := ((imul(x, 374761393) + imul(y, 668265263)) & MASK) ^ (seed_num & MASK)
	h = imul(h ^ (h >> 13), 1274126177)
	return float((h ^ (h >> 16)) & MASK) / 4294967296.0

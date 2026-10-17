class_name WGRandom
extends RefCounted
## Генератор случайных чисел mulberry32 и хеши с сидом.
## Повторяет js/core/random.js бит в бит: вся арифметика 32-битная, числа хранятся без знака.

const MASK := 0xFFFFFFFF

var _a: int


func _init(seed_num: int) -> void:
	_a = seed_num & MASK


## Следующее число в [0, 1)
func next_float() -> float:
	_a = (_a + 0x6d2b79f5) & MASK
	var a := _a
	var t := imul(a ^ (a >> 15), 1 | a)
	t = ((t + imul(t ^ (t >> 7), 61 | t)) & MASK) ^ t
	return float((t ^ (t >> 14)) & MASK) / 4294967296.0


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
	for i in n:
		var c := buf[i * 2] | (buf[i * 2 + 1] << 8)
		h = imul(h ^ c, 3432918353)
		h = ((h << 13) | (h >> 19)) & MASK
	h = imul(h ^ (h >> 16), 2246822507)
	h = imul(h ^ (h >> 13), 3266489909)
	return (h ^ (h >> 16)) & MASK


## Быстрый хеш целочисленных координат -> [0, 1)
static func hash2(x: int, y: int, seed_num: int) -> float:
	var h := ((imul(x, 374761393) + imul(y, 668265263)) & MASK) ^ (seed_num & MASK)
	h = imul(h ^ (h >> 13), 1274126177)
	return float((h ^ (h >> 16)) & MASK) / 4294967296.0

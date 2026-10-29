class_name Util
extends RefCounted
## Мелкие общие помощники, которые раньше были написаны в нескольких файлах одинаково.


## Доля пути к цели за кадр dt при плавном приближении со скоростью rate (1/с): lerp(a, b, damp(rate, dt))
static func damp(rate: float, dt: float) -> float:
	return 1.0 - exp(-dt * rate)


## SHA-256 от байтов (контрольная сумма файлов кэша и площадок)
static func sha256(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


## Расстояние для подписи: «350 м» или «1.2 км»
static func distance_text(m: float) -> String:
	return "%d м" % roundi(m) if m < 1000.0 else "%.1f км" % (m / 1000.0)

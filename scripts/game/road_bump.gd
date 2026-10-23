class_name RoadBump
extends RefCounted
## 11.5: мелкая неровность дорожного полотна — одно поле в мировых координатах на каждое покрытие.
## Геометрия дорог и меш не меняются: поле поднимает только точки касания колёс (подвеска,
## BikeRide._step_wheels) и рисуется светом в шейдере рельефа (та же формула в terrain.gdshader,
## road_bump()). Поэтому кочка, которую видно, — та же, на которой трясёт.
## Отдельный файл, а не RoadSurface: тот входит в ключ кэша мира, а это поле генерация не читает.

## По номеру покрытия RoadSurface: высота кочек (м) и длина волны (м). Гравий — частая мелкая дрожь,
## камень — крупные редкие удары, грунтовка и песок — пологие волны, лесная тропа — корни.
const LIST := [
	Vector2.ZERO,
	Vector2(0.010, 0.45),   # гравий
	Vector2(0.018, 1.3),    # грунтовка
	Vector2(0.007, 1.6),    # укатанная земля
	Vector2(0.032, 0.8),    # камень
	Vector2(0.014, 2.2),    # песок
	Vector2(0.026, 0.7),    # лесная тропа
	Vector2(0.022, 1.1),    # травяная колея
]
const STEEP := Vector2(0.06, 0.30)  # уклон, с которого полотно размыто сильнее
const STEEP_GAIN := 1.2             # на крутом кочки до 2,2 раза выше


## Форма поля 0..1 (кочки только вверх), x/z — мировые метры. Совпадает с road_bump() в шейдере.
static func shape(x: float, z: float, wave: float) -> float:
	var k := TAU / wave
	var qx := (0.8 * x + 0.6 * z) * k
	var qy := (-0.6 * x + 0.8 * z) * k
	var u := qx + 1.3 * sin(qy * 0.37)
	var v := qy * 0.71 + qx * 0.29 + 2.1
	var n := 0.6 * sin(u) + 0.4 * sin(v * 1.9)
	return maxf(n, 0.0) ** 2


## Подъём точки касания над полотном, м. grade — уклон пути (подъём на метр).
static func height(x: float, z: float, surface: int, grade: float) -> float:
	if surface <= 0 or surface >= LIST.size():
		return 0.0
	var b: Vector2 = LIST[surface]
	return b.x * (1.0 + STEEP_GAIN * smoothstep(STEEP.x, STEEP.y, absf(grade))) * shape(x, z, b.y)

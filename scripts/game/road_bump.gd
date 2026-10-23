class_name RoadBump
extends RefCounted
## 11.5: мелкая неровность дорожного полотна — одно поле в мировых координатах на каждое покрытие.
## Геометрия дорог и меш не меняются: поле поднимает или опускает только точки касания колёс (подвеска,
## BikeRide._step_wheels) и рисуется светом в шейдере рельефа (та же формула в terrain.gdshader,
## road_field()). Поэтому кочка, которую видно, — та же, на которой трясёт.
## 12.3: вторая версия. Раньше это были две синусоиды везде одной силы — одинаковая рябь. Теперь:
##  - участки: медленное поле (десятки метров) делит дорогу на ровные и разбитые куски, кочки на них
##    от трети до полутора раз и с другим рисунком (вторая волна под углом);
##  - колеи: две продольные канавки по поперечной координате полотна (UV2.x, как у меша), местами;
##  - ямы: редкие выбоины в клетках 2,5 м по целочисленному хешу (один и тот же в шейдере и здесь);
##  - трещины: только рисунок в шейдере (сетка трещин тоньше пятна контакта колеса).
## Колея и яма уходят ниже полотна на 2–5 см: колесо в них проседает, на краю получает удар.
## Отдельный файл, а не RoadSurface: тот входит в ключ кэша мира, а это поле генерация не читает.

## По номеру покрытия RoadSurface: высота кочек (м), длина волны (м), глубина колеи (м), доля клеток с ямой.
## Гравий — частая мелкая дрожь и выбоины, камень — крупные удары, грунтовка и песок — пологие волны
## и глубокие колеи, лесная тропа — корни, травяная колея — две колеи.
const LIST := [
	Vector4.ZERO,
	Vector4(0.010, 0.45, 0.015, 0.10),  # гравий
	Vector4(0.018, 1.3, 0.035, 0.14),   # грунтовка
	Vector4(0.007, 1.6, 0.015, 0.05),   # укатанная земля
	Vector4(0.032, 0.8, 0.0, 0.05),     # камень (выпавшие камни)
	Vector4(0.014, 2.2, 0.045, 0.0),    # песок
	Vector4(0.026, 0.7, 0.012, 0.0),    # лесная тропа
	Vector4(0.022, 1.1, 0.040, 0.03),   # травяная колея
]
## Трещины по покрытию, 0..1 (только вид): сухая укатанная земля и камень, немного грунтовка
const CRACKS := [0.0, 0.0, 0.3, 0.9, 0.6, 0.0, 0.0, 0.0]
const STEEP := Vector2(0.06, 0.30)  # уклон, с которого полотно размыто сильнее
const STEEP_GAIN := 1.2             # на крутом кочки до 2,2 раза выше
const RUT_AT := 0.47                # колеи на этой доле полуширины от оси (как колея меша RoadRefinement)
const RUT_W := 0.13
const HOLE_CELL := 2.5              # м, клетка ямы
const HOLE_DEPTH := 0.09            # глубина ямы на метр её радиуса
const M32 := 0xFFFFFFFF


## Медленные поля участков 0..1: x — разбитость, y — где колеи. Совпадают с road_patch() в шейдере.
static func patch(x: float, z: float) -> Vector2:
	return Vector2(
		0.5 + 0.5 * (0.55 * sin(0.083 * x + 0.047 * z + 1.7) + 0.45 * sin(-0.039 * x + 0.091 * z + 4.1)),
		0.5 + 0.5 * (0.6 * sin(0.061 * x - 0.037 * z + 0.4) + 0.4 * sin(0.027 * x + 0.083 * z + 2.6)))


## Форма волны 0..1 (только вверх), x/z — мировые метры. Совпадает с road_wave() в шейдере.
static func shape(x: float, z: float, wave: float) -> float:
	var k := TAU / wave
	var qx := (0.8 * x + 0.6 * z) * k
	var qy := (-0.6 * x + 0.8 * z) * k
	var u := qx + 1.3 * sin(qy * 0.37)
	var v := qy * 0.71 + qx * 0.29 + 2.1
	var n := 0.6 * sin(u) + 0.4 * sin(v * 1.9)
	return maxf(n, 0.0) ** 2


## Целочисленный хеш клетки (32 бита, как uint в шейдере)
static func cell_hash(ix: int, iz: int, salt: int) -> int:
	var h := (((ix & M32) * 73856093) & M32) ^ (((iz & M32) * 19349663) & M32) ^ salt
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & M32
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & M32
	return h ^ (h >> 16)


## Глубина ямы 0..1 доли её глубины в точке и радиус ямы (0 — ямы нет). Совпадает с road_hole() в шейдере.
static func hole(x: float, z: float, chance: float, rough: float) -> Vector2:
	var ix := floori(x / HOLE_CELL)
	var iz := floori(z / HOLE_CELL)
	var h := cell_hash(ix, iz, 12301)
	if float(h & 0xFFFF) / 65536.0 >= chance * rough:
		return Vector2.ZERO
	var g := cell_hash(ix, iz, 4517)
	var cx := (ix + 0.25 + 0.5 * float(g & 0xFFFF) / 65536.0) * HOLE_CELL
	var cz := (iz + 0.25 + 0.5 * float((g >> 16) & 0xFFFF) / 65536.0) * HOLE_CELL
	var r := 0.25 + 0.3 * float((h >> 16) & 0xFFFF) / 65536.0
	var q := ((x - cx) * (x - cx) + (z - cz) * (z - cz)) / (r * r)
	return Vector2((1.0 - q) * (1.0 - q), r) if q < 1.0 else Vector2.ZERO


## Высота точки касания над полотном, м (колея и яма — ниже нуля). grade — уклон пути,
## across — поперечная координата полотна (−1..1 от оси до кромки, RoadRefinement.sample).
static func height(x: float, z: float, surface: int, grade: float, across := 0.0) -> float:
	if surface <= 0 or surface >= LIST.size():
		return 0.0
	var b: Vector4 = LIST[surface]
	var p := patch(x, z)
	var rough := lerpf(0.35, 1.6, smoothstep(0.25, 0.75, p.x))
	var bumps := shape(x, z, b.y) + 0.7 * smoothstep(0.3, 0.8, 1.0 - p.y) * shape(0.28 * x - 0.96 * z, 0.96 * x + 0.28 * z, b.y * 0.57)
	var out := b.x * rough * (1.0 + STEEP_GAIN * smoothstep(STEEP.x, STEEP.y, absf(grade))) * bumps
	var a := absf(across)
	if b.z > 0.0 and a < 1.0:
		out -= b.z * smoothstep(0.35, 0.7, p.y) * exp(-pow((a - RUT_AT) / RUT_W, 2.0))
	if b.w > 0.0 and a < 0.75:
		var pit := hole(x, z, b.w, smoothstep(0.3, 0.8, p.x) * 1.5)
		out -= pit.x * pit.y * HOLE_DEPTH
	return out

class_name WorldAtmosphereConfig
extends Resource
## Вложенный профиль пасмурного неба, осенней палитры, долинного тумана и 3D LUT для типа мира (Фаза 10).
## Тип 1 (mountain_valley) держит atmosphere = null и полностью сохраняет прежнее солнечное поведение.

@export_group("Пасмурное небо и облачность")
## Нижняя граница дневной облачности в типе мира (предотвращает ясные солнечные окна).
@export_range(0.0, 1.0, 0.01) var cloud_cover_min: float = 0.78
## Верхняя граница дневной облачности при медленной смене погодных волн.
@export_range(0.0, 1.0, 0.01) var cloud_cover_max: float = 0.92
## Сплошная пасмурная пелена неба днём (поднимает потолок eff_cov > 0.74; ночью гаснет для звёзд).
@export_range(0.0, 1.0, 0.01) var overcast_deck: float = 0.86
## Сланцево-серый зенит пасмурного дневного неба.
@export var overcast_zenith: Color = Color(0.33, 0.38, 0.43)
## Молочно-сизый серый горизонт и базовый цвет дальнего тумана.
@export var overcast_horizon: Color = Color(0.57, 0.62, 0.65)
## Приглушённый холодно-серый тон облачной массы.
@export var overcast_cloud_color: Color = Color(0.60, 0.64, 0.67)
## Рассеянный холодно-серебристый оттенок пасмурного дневного света.
@export var overcast_sun_color: Color = Color(0.84, 0.87, 0.90)
## Холодный влажный заполняющий свет пасмурного неба.
@export var overcast_ambient: Color = Color(0.49, 0.54, 0.58)
## Доля смешивания палитры DayCycle к пасмурному профилю днём.
@export_range(0.0, 1.0, 0.01) var sky_overcast_blend: float = 0.84
## Множитель яркости околосолнечного ореола (подавляет солнечное слепящее пятно).
@export_range(0.0, 1.0, 0.01) var sun_halo_mul: float = 0.20
## Доля периодических локальных разрывов в сплошной пелене неба (0 — сплошная пелена Типа 1).
@export_range(0.0, 1.0, 0.01) var cloud_break_strength: float = 0.0
## Сила осязаемых рассеянных лучей сквозь разрывы пелены (0 — как в Типе 1).
@export_range(0.0, 1.0, 0.01) var cloud_break_shafts: float = 0.0
## Усиление свечения объёмного тумана и солнечного рассеяния в просветах облаков.
@export_range(0.0, 2.0, 0.01) var volumetric_shaft_energy: float = 0.0

@export_group("Освещение и тени")
## Множитель энергии прямого солнца днём (мягкий пасмурный свет без резкого блика).
@export_range(0.1, 1.5, 0.01) var sun_energy_mul: float = 0.46
## Множитель рассеянного света неба (держит глубокий хвойный полог читаемым).
@export_range(0.5, 2.5, 0.01) var ambient_energy_mul: float = 1.44
## Дневной множитель экспозиции поверх кривой DayCycle.
@export_range(0.5, 1.5, 0.01) var exposure_mul: float = 0.92
## Дополнительное размытие краёв солнечных теней под пасмурной пеленой.
@export_range(0.0, 3.0, 0.05) var shadow_blur_add: float = 1.35
## Множитель общей насыщенности сцены DayCycle в светлое время суток.
@export_range(0.5, 1.2, 0.01) var day_saturation_mul: float = 0.84
## Доля затемнения нижней полусферы карты отражений неба (0 — как в Типе 1, ближе к 1 — тёмное отражение земли).
@export_range(0.0, 1.0, 0.01) var cubemap_ground_darken: float = 0.0
## Сила градиента пасмурного неба CIE в карте отражений (горизонт темнее, зенит ярче; 0 — как в Типе 1).
@export_range(0.0, 1.0, 0.01) var cubemap_overcast_cie: float = 0.0
## Доля направленного кубмапа неба в рассеянном свете (ambient_light_sky_contribution; 0.6 — базовое значение).
@export_range(0.0, 1.0, 0.01) var ambient_sky_contribution: float = 0.6

@export_group("Горный туман и долинная дымка")
## Множитель плотности дальнего экспоненциального тумана долины.
@export_range(0.5, 4.0, 0.05) var fog_density_mul: float = 1.50
## Минимальный дневной базовый уровень долинной дымки в тумане.
@export_range(0.0, 1.0, 0.01) var local_mist_floor: float = 0.58
## Смещение высоты потолка высотного тумана над камерой (следует за спуском долины).
@export_range(-20.0, 120.0, 1.0) var fog_height_offset: float = 24.0
## Множитель плотности высотной слоистой дымки env.fog_height_density.
@export_range(0.5, 4.0, 0.05) var fog_height_density_mul: float = 2.28
## Множитель воздушной перспективы (разделение силуэтов хребтов).
@export_range(0.5, 2.5, 0.05) var aerial_perspective_mul: float = 1.22
## Множитель плотности объёмного тумана при включённом Volumetric Fog.
@export_range(0.5, 3.0, 0.05) var volumetric_density_mul: float = 2.20
## Множитель локальных пятен долинного тумана LocalMist по склонам и реке.
@export_range(0.5, 2.5, 0.05) var local_mist_patch_mul: float = 1.45
## Диапазон влажности [min, max] для появления локальных пятен долинного тумана (LocalMist).
@export var local_mist_moist_range := Vector2(0.36, 0.72)
## Диапазон уклона [min, max], в котором локальные пятна тумана сходят на нет.
@export var local_mist_slope_range := Vector2(0.16, 0.55)
## Минимальная пригодность клетки (0..1) для размещения пятна локального тумана.
@export_range(0.0, 1.0, 0.01) var local_mist_min_suitability: float = 0.14
## Доля цвета горизонта в альбедо объёмного тумана (0 — нейтрально-серый, 1 — тон горизонта).
@export_range(0.0, 1.0, 0.01) var volumetric_horizon_tint: float = 0.48
## Ослабление облачных теней на земле при сплошной пасмурной пелене overcast_deck (0..1).
@export_range(0.0, 1.0, 0.01) var overcast_shadow_damp: float = 0.55

@export_group("Осенняя палитра")
## Общая сила ранней/средней осени для листвы, лиственниц, подлеска и дёрна.
@export_range(0.0, 1.0, 0.01) var autumn_strength: float = 0.88
## Приглушение яркой летней травы и открытого дернина в terrain.gdshader.
@export_range(0.0, 1.0, 0.01) var ground_turf_desat: float = 0.78
## Потемнение и оливковое приглушение лесного мха в подстилке.
@export_range(0.0, 1.0, 0.01) var ground_moss_darken: float = 0.68
## Усиление рыже-медного осеннего опада на лесной земле в terrain.gdshader.
@export_range(0.0, 1.0, 0.01) var ground_litter_warmth: float = 0.85

@export_group("Цветокоррекция и планы (VisualStyle)")
## Идентификатор пресета 3D LUT в VisualStyle ("default" для Типа 1).
@export_enum("default", "expedition_overcast") var style_preset: String = "expedition_overcast"
## Остаточная теплота светов в 3D LUT (снижена относительно летнего золота).
@export_range(0.0, 1.5, 0.01) var lut_warm_shift: float = 0.14
## Сдвиг теней и средних землистых тонов к спокойному холодно-коричневому/сланцевому балансу.
@export_range(0.0, 1.0, 0.01) var lut_cool_brown: float = 0.44
## Приглушение кричащей летней зелени в 3D LUT при сохранности медной/охристой осени.
@export_range(0.0, 0.8, 0.01) var lut_desat_green: float = 0.52
## Верхний предел контраста кривой AgX (мягче базовых 1.50 для читаемости хвойных теней).
@export_range(1.0, 1.6, 0.01) var agx_contrast_max: float = 1.34
## Множитель ближнего контраста depth_tone (x).
@export_range(0.4, 2.0, 0.05) var depth_near_mul: float = 0.90
## Множитель обесцвечивания дальних склонов depth_tone (y).
@export_range(0.5, 2.5, 0.05) var depth_far_desat_mul: float = 1.25
## Множитель примешивания дымки горизонта на дальних хребтах depth_tone (z).
@export_range(0.5, 2.5, 0.05) var depth_haze_mul: float = 1.38


## Сигнатура параметров цветокоррекции для раздельного кэша 3D LUT в VisualStyle.
func lut_signature() -> String:
	return "%s|%.3f|%.3f|%.3f" % [style_preset, lut_warm_shift, lut_cool_brown, lut_desat_green]

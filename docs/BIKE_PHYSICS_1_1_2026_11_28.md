# Bike Physics 1.1 (ветка `test4`, 28.11.2026)

Полировка и релиз **1.1** упрощённой 60 Гц физики велосипеда по итогам реального заезда и телеметрии игрока (`Заря-4741`, Тип 2 `river_expedition`).

## Ключевые изменения 1.1

### 1. Разделение руления передним колесом и крена рамы
- **`Controls.bike_steer()` ([controls.gd](file:///c:/Users/Luisa/Downloads/Godot_v4.7.2-stable_mono_win64/world-generator-godot/scripts/game/controls.gd)):** на клавиатуре короткое нажатие даёт мягкое подруливание (`steer_tap = 0.30`), а удержание плавно раскрывает полный угол руля за `steer_ramp_time = 0.24 с`.
- **`BikeRide._step_horizontal()` ([bike_ride.gd](file:///c:/Users/Luisa/Downloads/Godot_v4.7.2-stable_mono_win64/world-generator-godot/scripts/game/bike_ride.gd)):** убран искусственный множитель `steer_boost = 2.2`; `max_steer_angle = 0.60 рад` приведён `1:1` к визуальному повороту рулевой `BikeView.STEER_VIEW = 0.60`.
- **Прогрессивный крен (`lean_gentle_share = 0.10`, `lean_share = 0.48`, `lean_max = 0.32 рад`, `lean_response = 6.5`):** лёгкие корректировки курса и езда на малой скорости управляются передним колесом почти без завала рамы; глубокий крен раскрывается только в быстрой sustained-дуге.
- **`BikeView` ([bike_view.gd](file:///c:/Users/Luisa/Downloads/Godot_v4.7.2-stable_mono_win64/world-generator-godot/scripts/render/bike_view.gd)):** ослаблена ложная реакция смещения таза/руля от обычного поперечного уклона траверса и мелких кренов.

### 2. Скользящие двухосевые коллизии без залипания
- Задняя ось всегда сдвигается из предыдущей допустимой позиции (`old_p_r -> want_p_r`), а не телепортируется в занятую точку с нулевым смещением.
- Добавлен выход из микропересечения `BODY_R` (`r = 0.0` при заблокированном старте точки) и мягкий fallback центра при сжатии базы в узких углах.
- Трение о стену масштабируется на `dt` и косинус угла удара: касательный контакт сохраняет скорость и скользит вдоль препятствия без приклеивания и ложных падений.

### 3. Стабильные крутые подъёмы и спуски (включая горные дороги Типа 2)
- В **`BikeRide._step_speed_sub()`** устранена мёртвая зона микроотката (`-0.02..0.0 м/с`), усилена компенсация тяги в подъём (`climb_assist = 0.50`) и удержание на крутых склонах (`stop_hold_grade = 0.40`), а также сцепление тормоза на грунте.
- В **`BikeRide._wheel_support_raw()`** исключён геометрический подъём `+4 см` на ровных уклонах и добавлен высокий порог отсчёта `y + 0.35` для верхнего колеса на крутых подъёмах.
- В **`BikeRide._step_vertical()`** луч проверки вылета `crest_launch` ведётся по текущей дуге поворота и не срабатывает ложно, когда прямая на горном повороте Типа 2 выходит за обочину над обрывом.

### 4. Чистка ошибок рантайма из `godot.log`
- **[brake_effects.gd](file:///c:/Users/Luisa/Downloads/Godot_v4.7.2-stable_mono_win64/world-generator-godot/scripts/render/brake_effects.gd):** `ImmediateMesh.surface_begin` больше не запускается без фактических связанных сегментов (исправлена ошибка `No vertices were added`).
- **[world_carousel.gd](file:///c:/Users/Luisa/Downloads/Godot_v4.7.2-stable_mono_win64/world-generator-godot/scripts/ui/world_carousel.gd):** безопасное чтение метаданных `menu_hover` через `has_meta`.

## Конфигурация `BikePhysicsConfig` (версия `1.1`)
Основные правки сосредоточены в [bike_physics_config.gd](file:///c:/Users/Luisa/Downloads/Godot_v4.7.2-stable_mono_win64/world-generator-godot/scripts/game/bike_physics_config.gd) и пресете [bike_physics.tres](file:///c:/Users/Luisa/Downloads/Godot_v4.7.2-stable_mono_win64/world-generator-godot/resources/bike_physics.tres).

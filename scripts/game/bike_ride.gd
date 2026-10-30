class_name BikeRide
extends RefCounted
## Велосипед: где стоит, разгон и торможение, руль, подъёмы, полёт с горбов и прыжок, подвеска колёс.
## Без узлов сцены, как PlayerState. Пока игрок едет, велосипед везёт его: положение игрока
## берётся отсюда. Проходимость та же, что у пешехода (PlayerState.is_passable): глубокая вода,
## дома, перила мостов и стены туннелей не пускают; по настилу моста велосипед едет, как по земле.
## С 2.2 велосипед для столкновений — три круга вдоль рамы (колёса и середина), а не точка:
## переднее колесо не въезжает в дом и не высовывается за перила.

const WHEEL_R := 0.34   # радиус колеса, м
const GEAR_MIN := 1.4   # самая лёгкая передача виртуального переключателя
const GEAR_MAX := 5.0   # и самая тяжёлая: на 20 м/с — около 110 об/мин, дальше ноги не учащаются бесконтрольно
const CADENCE_LOW := 6.3  # рад/с педалей (60 об/мин) на малой скорости
const CADENCE_HIGH := 9.4 # рад/с (90 об/мин) в крейсерском темпе
const GEAR_RESPONSE := 2.5 # 1/с: передача меняется плавно
const START_CRANK := 2.5  # рад/с педалей на полном усилии с места: нажатие видно до того, как велосипед поехал
const WALL_LOSS := 6.0  # 1/с: как быстро удар в стену в лоб гасит скорость (при скольжении вдоль стены почти не гасит)
const BODY_R := 0.3     # радиус кругов, которыми велосипед задевает препятствия, м (руль шириной 0,6 м)
const AXLE := 0.57      # круги колёс — на столько впереди и позади середины, м: вместе с BODY_R до края колеса (0,53 + 0,34)
const SPRING_K := 170.0   # жёсткость подвески, 1/с²
const SPRING_DAMP := 16.0 # затухание подвески, 1/с
const SAG_MAX := 0.16     # подвеска просаживается не больше этого, м
const STRETCH_MAX := 0.08 # и вытягивается при прыжке не больше этого, м
const SOFT_IMPACT := 7.0  # приземление жёстче этого (м/с) гасит скорость
const FACE_CRASH := 5.0   # приземление в подъём (крутизна 1 = 45°) роняет при ударе слабее BIKE_CRASH на столько, м/с
const WALL_CRASH := 9.0   # удар в стену в лоб быстрее этого (м/с) роняет седока; с 7.7 и в ствол, валун, бревно —
                          # по скорости поперёк их поверхности (вскользь не роняет)
## На пути колёса держатся полотна на мелких изломах, руль зависит от сцепления покрытия.
const SLOPE_GRAVITY := GameConfig.GRAVITY # та же тяжесть, что в полёте; склон не превращается в вязкий тормоз
const CLIFF_GRADE := 2.0 # около 63°: на такой стене колёса уже не удерживают седока
const CORNER_GRIP := GameConfig.BIKE_GRIP
const MOUNT_RISE := 1.5  # сесть можно, если велосипед не выше и не ниже ног на столько, м
const HOP_COYOTE := 0.1  # можно успеть прыгнуть сразу после схода с края, с
const HOP_BUFFER := 0.22 # 14.1: пробел ждёт касания столько, с (было 0,12, как пешком): короткий отрыв на гребне
                         # перед бревном длится 0,2–0,3 с и съедал нажатие, сделанное вовремя
## С 7.0 опора — середина между точками касания колёс, отрыв — по форме рельефа впереди.
const HUB := GameConfig.BIKE_WHEELBASE * 0.5 # оси колёс впереди и позади середины, м
const LIFT := 0.1        # отрыв, только если за LOOK секунд рельеф уйдёт из-под полёта глубже этого, м
                         # (было 0,2: с кромки стола и гребня роллера велосипед отрывался только к 40 км/ч;
                         # меньший провал подвеска выбирает сама, она вытягивается на STRETCH_MAX)
const LOOK: Array[float] = [0.1, 0.2, 0.3]
const DROP_STEP := 0.12  # земля ушла вниз за один такт больше этого — это край, а не излом: падаем
## С 7.1 подвеска у каждого колеса своя: пружина-демпфер от профиля под этим колесом.
const KICK_MAX := 6.0    # больший скачок (ступенька, телепорт) ограничивается, м/с
const PITCH_LOAD := GameConfig.BIKE_PITCH_LOAD
const BUMP := 0.035      # высота мелких кочек под колесом на бездорожье (rough 1), м
const REVERSE_HOLD := GameConfig.BIKE_REVERSE_WAIT
const WHEEL_REACH := 0.16 # колесо — круг: земля меряется ещё на столько впереди и позади точки касания, м
const PROFILE_SPAN := 1.5 # база, на которой измеряется кривизна профиля (впадина, роллер), м
const BANK_SPAN := 0.7   # поперечная база, на которой измеряется наклон полотна (вираж), м
const BANK_LIMIT := 2.0  # вираж поднимает сцепление не больше чем во столько раз (шина и рама не держат больше)
const BUMP_DRAG := 1.0   # подвеска забирает у хода энергию подъёма колеса на корень или камень, 1/с
const PROFILE_SAG := 0.6 # сжатие подвески на 1 g нагрузки от профиля, доля SAG_MAX
const BOTTOM_OUT := 0.8  # вилка ударилась в упор SAG_MAX быстрее этого (м/с) — стук пробоя
## Скорости сглаживания (1/с, через Util.damp) и пределы, раньше записанные прямо в формулах.
const SUB_HZ := 120.0          # частота подшагов движения и подвески, Гц
const G_RESPONSE := 12.0       # нагрузка профиля (vertical_g) следует за землёй
const G_RELAX_AIR := 8.0       # и спадает к нулю в полёте
const G_MIN := -1.0            # пределы нагрузки профиля, g
const G_MAX := 1.5
const BANK_RESPONSE := 15.0    # наклон полотна поперёк (bank_slope)
const BANK_SLOPE_MAX := 0.8    # учитываемый наклон виража, м на м
const TILT_RESPONSE := 25.0    # наклон рамы вдоль склона на земле
const TILT_RESPONSE_AIR := 5.0 # и в полёте
const AIR_TILT_MAX := 0.55     # наклон рамы по траектории полёта, рад
const AIR_TILT_SPEED := 4.0    # ниже этой скорости (м/с) наклон в полёте считается от неё
const LEAN_RESPONSE := 9.0     # крен в повороте на земле
const LEAN_RESPONSE_AIR := 2.5 # и в полёте (возвращается к нулю)
const LEAN_SHARE := 0.38       # крен — такая доля угла от боковой силы (30.10: было 0,5; поворот виден рулём, а не креном)
const LEAN_MAX := 0.22         # наибольший видимый крен, рад (было 0,28)
const STEER_RATE := 3.8        # скорость поворота руля, доля хода в секунду (30.10: было 5 — руль дёргался)
const STEER_CENTER := 5.0      # и возврата руля в середину, когда его отпустили (было 7)
const TURN_RESPONSE_SLOW := 10.0 # отклик курса на руль на малой скорости
const TURN_RESPONSE_FAST := 4.5  # и на большой (TURN_PACE_HIGH)
const TURN_PACE_LOW := 3.0     # между этими скоростями, м/с, отклик плавно меняется
const TURN_PACE_HIGH := 16.0
const HOP_CARRY := 3.0         # к прыжку добавляется не больше этой вертикальной скорости, м/с
const HOP_PRELOAD := 0.9       # толчок подвески вверх при прыжке, м/с
const HOP_WAIT := 0.08         # после приземления без нажатого пробела прыжок доступен через столько, с
const HOP_WAIT_AIR := 0.2      # если в воздухе были дольше этого, с
const LANDING_KICK := 0.4      # доля скорости удара, которая уходит в сжатие подвески
const SQUASH_V_MIN := -2.0     # пределы скорости хода подвески, м/с
const SQUASH_V_MAX := 4.0
## Общая модель двух контактов: у каждого колеса своя нагрузка,
## от неё — запас сцепления для тормоза и поворота; поперечный уклон тянет вниз тяжестью, а не правит запас.
const CONTACT_SPRING := 0.5  # доля силы пружины колеса в его нагрузке: каждая подвеска держит половину массы
## Нагрузка колеса — от хода пружины, без скорости хода: скачки скорости хода — толчки подвески для картинки (кочки,
## швы сетки), а не силы, и шум от них дёргал запас сцепления на пределе поворота
const CONTACT_DAMP := 0.0
const LOAD_MAX := 3.0        # нагрузка колеса не больше этого, доли веса
const CONTACT_MIN := 0.02    # легче этого колесо не держит (разгружено, оторвалось)
const SIDE_HOLD_SPEED := 2.0 # ниже этой скорости (м/с) седок стоит и тяжесть поперёк не тянет велосипед вбок
## Шина набирает силу не мгновенно, а за путь (длина релаксации): скачки нагрузки от каждой кочки сглаживаются,
## а гребень роллера или ложбина, длинные по сравнению с ней, меняют запас сцепления полностью.
## Колесо и препятствие: удар о кромку отнимает у колеса скорость по углу встречи (1 − cos), торможение рамы —
## по доле массы на этом колесе (нагрузка шины). Переднее колесо, остановленное резче ENDO_DV, бросает седока через руль.
const IMPACT_ANGLE := 0.12   # рад: плавнее этого подъём опоры — накат, а не удар
const ENDO_DV := 5.0         # м/с: такая потеря скорости переднего колеса (при обычной нагрузке) — полёт через руль
const EDGE_SOAK := 0.75      # наибольшая доля удара о кромку, которую принимает оставшийся ход подвески (не раму)
## Тело седока (модель двух контактов): положение вперёд/назад body_x от −1 (вперёд) до 1 (назад), движется к цели
## (body_back / body_forward) с ограниченными скоростью и ходом. Положение переносит часть веса (BODY_HOLD на весь
## ход: назад — легче переднее колесо, хуже его поворот), а само движение — рывок (BODY_PUSH на единицу скорости):
## быстро назад — переднее колесо лёгкое, пока тело движется; быстро вперёд — лёгкое заднее. Импульс длится, пока
## тело в движении, поэтому окно — доли секунды и нужно попасть в момент; дёрганье туда-сюда даёт ещё и обратные рывки.
const BODY_K := 160.0        # 1/с²: тяга тела к цели
const BODY_D := 25.0         # 1/с: демпфирование (около критического)
const BODY_RATE := 4.0       # ход в секунду: быстрее тело не движется
const BODY_HOLD := 0.12      # доля веса на весь ход положения
const BODY_PUSH := 0.15      # доля веса на единицу скорости тела (на BODY_RATE — 0,6)
const BODY_LEAD := 0.1       # с от нажатия до пика рывка (для сценариев замеров)
## Подъём колеса: рывок тела сильнее веса, который несёт колесо, отрывает его от земли (lift_f / lift_r, м над опорой).
## Пока колесо в воздухе, весь вес на другом, а о препятствие оно не бьётся, если поднято выше него. Оба колеса в
## воздухе — банни-хоп. Q поднимает переднее, затем E в пределах HOP_LINK подтягивает заднее.
const LIFT_GAIN_F := 5.0    # ускорение подъёма переднего колеса на долю веса сверх его нагрузки, g (руль на себя)
const LIFT_GAIN_R := 3.0     # заднего (ноги подтягивают раму); вниз оба падают с g
## Банни-хоп: заднее колесо оторвалось, пока переднее в воздухе. Скорость вверх — от толчка ногами (HOP_POP) тем
## больше, чем выше уже поднято переднее (на HOP_FRONT — полный), плюс часть скорости подъёма переднего.
const HOP_POP := 3.1         # м/с (30.10: было 2,6 — около 21 см толчка при игровой тяжести 16 м/с², теперь около 30 см)
const HOP_FRONT := 0.16      # м: полный толчок без необходимости ловить пик переднего колеса до кадра
const LIFT_MAX := 0.6        # м
const LIFT_RATE_F := 1.9     # м/с: быстрее рывок не поднимает переднее (30.10: было 1,5 — Q выглядел вялым)
const LIFT_TURN_MAX := 0.10  # м: в быстрой дуге переднее поднимается не выше (без предела Q в дуге №17 уводил на 9 м;
                             # 0,14 проверяли 30.10 — Q 0,2 с в дуге №17 уводит дальше: 2,1 м против 1,5)
## Пробел в модели двух контактов — автоматический Q→E с умеренной подготовкой: точный ручной выше.
const AUTO_BACK := 0.13      # с тела назад (раньше лучшего момента: прыжок ниже ручного)
const AUTO_FORWARD := 0.2    # с тела вперёд после этого
const AUTO_STRENGTH := 1.0   # доля хода тела
const PULL_PITCH := 0.25     # рад наклона рамы носом вверх на всю долю снятого веса: рывок видно
const YAW_DROP := 8.0        # рад/с²: так быстро гаснет поворот, когда переднее колесо теряет запас
## Нагрузка колеса — через податливость шины (TIRE_COMPLY): пятно контакта не теряет и не набирает вес мгновенно.
## Без этого ограничение силы шины нагрузкой ловило каждый провал хода пружины и занижало запас в среднем на 17–20 %.
const TIRE_COMPLY := 0.03    # с
const PITCH_TRANSFER := 0.14 # с: перенос нагрузки между осями следует за тормозом и подъёмом колеса
## Занос: рама сама доворачивает к направлению движения (переднее колесо уходит в занос, седок ловит), а снос больше
## SLIDE_CRASH на скорости — падение набок. Велосипед не катится боком.
const ALIGN_SLIP := 0.3      # рад: меньший снос — обычный поворот
const ALIGN_RATE := 3.0      # рад/с: наибольшая скорость доворота рамы к движению
const SLIDE_CRASH := 1.05    # рад (60°)
const SLIDE_CRASH_SPEED := 4.0 # м/с
## Корни и мелкие камни (кочки ForestObstacles.bump_at) скользкие: пока колесо на них, его запас сцепления меньше.
## Проезд поперёк накатом их почти не замечает; тормоз или руль на корнях срывают колесо.
const ROOT_GRIP := 0.45
const SLICK_BUMP := 0.015    # м: выше этого колесо стоит на корне, а не на земле
const TIRE_RELAX := 0.8      # м пути
const TIRE_RELAX_MIN := 0.05 # с: не быстрее этого и на большой скорости
## Боковой запас ещё и с инерцией рамы и седока: поворот не дрожит от каждой кочки на пределе сцепления,
## а длинный гребень или контруклон всё так же отнимают его.
const SIDE_RELAX := 0.2      # с
## Помощь баланса в лабораторной модели: запас на обычную дугу и на исправление ошибки.
const RIDER_GRIP := 1.6
const TURN_RESERVE := 0.97 # 30.10: было 0,88 — руль на скорости оставлял лишний запас; дуга круче, снос не растёт
const SIDE_RESPONSE := 30.0
const RIDER_STEER := 1.35
const RIDER_TURN_RESPONSE := 8.0 # 30.10: было 6 — на скорости поворот набирался вяло
const TURN_SCALE_RELAX := 0.35 # с: за столько полный руль следует за изменением доступной дуги (волны, вираж)
const HOP_ARM_HEIGHT := 0.015 # Q должен действительно поднять переднее колесо; кромка не съедает подготовку
const HOP_LINK := 0.3         # окно E после подъёма, с
## Автопамп читает только поверхность: сгибаемся на волне, давим на обратный склон.
## Отдельно от Q/E: не поднимает колёса и не готовит баннихоп. Ограничен ходом тела и скоростью.
const PUMP_ABSORB_V := 2.0    # м/с вертикальной скорости, которую ноги и руки гасят на гребне волны
const PUMP_REACH := 0.22      # м хода тела, которым седок поглощает гребень волны (было 0,12 и только до 14 м/с)
const PUMP_ACCEL := 3.0       # м/с² на единицу обратного уклона волны
const PUMP_TOP := 14.0        # м/с: выше этого помощь ходу плавно исчезает
const PUMP_PAUSE := 0.25      # с после ручного действия/приземления до возврата автоматики
const PUMP_STEER_LIMIT := 0.25 # с такого руля автоматический толчок плавно уступает повороту (до нуля к 0,8)
## 30.10: ручной памп — рывок тела на волне (Q поглощает подъём, E продавливает обратный склон), см. _step_pump.
const PUMP_BODY := 0.3        # доля веса, которую тело на полной скорости хода добавляет к опоре или снимает с неё
const PUMP_BODY_ACCEL := 2.5  # м/с²: предел разгона и торможения от ручного пампа
const PUMP_KINK := 0.55      # 1/м: резче этого излом профиля — ступень или кромка, а не волна
const PUMP_HOLD := 0.3       # с: столько велосипед считается «на волне» после последнего заметного изгиба профиля
const PUMP_WAVE_PRESS := 0.06 # уклон волны: от подъёма до гребня (выше −половины этого) Q на волне — поглощение
const START_PACE := 3.0       # м/с: до этой скорости тяга педалей не ограничена запасом заднего колеса (помощь старта)
## Усилие седока на педалях — общее состояние тяги и позы: набирается плавно (около 95 % за 0,5 с),
## без мёртвой задержки, и спадает при отпускании без длинной скрытой тяги.
const EFFORT_RISE := 0.16     # с (30.10: было 0,08 — 95 % за 0,24 с ощущалось рывком; теперь около 0,5 с)
const EFFORT_FALL := 0.1      # с (было 0,05)
## Воздух — один закон на земле и в полёте (доля прежнего BIKE_DRAG); остальное от квадрата скорости на земле —
## потери шины и подвески на скорости. Сумма на земле прежняя.
const AIR_DRAG := 0.0035      # 1/м
const SPEED_LOSS := GameConfig.BIKE_DRAG - AIR_DRAG

var pump_pressed := false  # удержание ЛКМ; без него нет сил или поглощения пампа
var pump_enabled := true    # общий механизм и в мире, и в Lab; выключатель для сравнительных прогонов
var effort := 0.0           # усилие седока на педалях 0..1: от него тяга и поза (BikeView)
var effort_ramp := true     # false — прежняя мгновенная тяга, для сравнительных прогонов
var gear := GEAR_MIN        # виртуальная передача: оборотов колеса на оборот педалей (только каденс и вид, не тяга)
var pump_motion := 0.0       # -1..1: вытянуться / согнуться; поза, не ручное body_x
var pump_load := 0.0         # добавка нагрузки, доля веса
var pump_accel := 0.0        # помощь ходу на обратной стороне волны, м/с² (с ручным пампом — и торможение при ошибке)
var pump_wave := 0.0         # местный уклон волны под велосипедом по ходу (больше нуля — подъём на гребень)
var pump_active := 0.0       # 0..1: велосипед на волне, где работает памп (0 — ровно, ровный склон, отрыв)
var pump_body := 0.0         # доля веса, которую тело сейчас добавляет к опоре (+, E) или снимает с неё (−, Q)
var _pump_reach := 0.0
var _pump_absorb_v := 0.0   # вертикальная скорость, которую седок сейчас гасит на гребне, м/с
var _pump_wait := 0.0

var x := 0.0          # метры
var z := 0.0
var y := 0.0          # высота, где колёса касаются земли (в полёте — над землёй)
var vy := 0.0         # вертикальная скорость, м/с
var airborne := false
var heading := 0.0    # курс, как yaw камеры: 0 — на север (-Z)
var speed := 0.0      # м/с вдоль курса, назад — меньше нуля
var acceleration := 0.0 # фактический продольный разгон за последний такт, для ощущения скорости
var lateral_speed := 0.0 # боковая скорость относительно рамы
const Brakes = preload("res://scripts/game/bike_brakes.gd")
var brakes := Brakes.new()
var brake_pressure: float:
	get: return brakes.pressure
var brake_deceleration: float:
	get: return brakes.deceleration
var front_load: float:
	get: return brakes.front_load
var grip_usage := 0.0 # фактически использованный общий запас, 0..1
var slip := 0.0 # подписанный угол сноса, радианы
var _corner_demand := 0.0
var _side_use := 0.0   # доля бокового запаса шин, занятая на прошлом подшаге (модель двух контактов)
var body_back := false    # вход: тело назад (руль на себя)
var body_forward := false # вход: тело вперёд (на руль)
var body_x := 0.0         # положение тела: + назад, − вперёд
var body_v := 0.0
var unweight := 0.0       # доля веса, снятая с переднего колеса на заднее сейчас (меньше нуля — с заднего на переднее)
var lift_f := 0.0         # переднее колесо над опорой, м (0 — на земле)
var lift_fv := 0.0
var lift_r := 0.0
var lift_rv := 0.0
var hop_height := 0.0     # высота последнего банни-хопа от точки отрыва, м (для замеров и метрик)
var _hop_from := 0.0
var _auto_hop := -1.0     # с от начала автоматического Q→E (пробел), -1 — нет
var _hop_link := 0.0
var _hop_front := 0.0
var _hop_front_v := 0.0
var _hop_used := false
var contact_model := true # общая модель игры и Trail Lab; false оставлен для сравнительных проб
var load_f := 0.5     # нагрузка переднего колеса, доли веса велосипеда с седоком (на ровном стоя — 0,5)
var load_r := 0.5
var tire_f := 0.5     # нагрузка, которую «чувствует» шина (сглажена по пути, TIRE_RELAX): от неё запас сцепления
var tire_r := 0.5
var side_f := 0.5     # нагрузка для бокового запаса (tire_* с инерцией SIDE_RELAX)
var side_r := 0.5
var slick_f := 1.0    # доля сцепления колеса на скользком (корень, камень), 1 — земля
var slick_r := 1.0
var force_f := Vector2() # фактически приложенная сила колеса на массу велосипеда, м/с²: x — тормоз (у заднего минус тяга), y — поперёк
var force_r := Vector2()
var use_f := 0.0      # использованный запас сцепления колеса (тормоз и поворот), 0..1; 1 — колесо скользит
var use_r := 0.0
var _share := 0.5     # доля нагрузки на переднем колесе после переноса (PITCH_TRANSFER)
var _rest_f := 0.0    # цель пружин на прошлом такте: отклонение от неё — сила подвески сверх равновесия
var _rest_r := 0.0
var _on_f := -1          # препятствие, на котором стоит колесо (ForestObstacles.wheel_contact id; -1 — на земле)
var _on_r := -1
var impacts := Vector2i() # сколько раз колесо встретило кромку препятствия (перед, зад), для замеров
var hit_dv := Vector2()   # потеря скорости рамы при последней встрече переднего и заднего колеса с кромкой, м/с
var landing_info := {} # snapshot before landing resets velocities and flight time
var crash_info := {} # snapshot at the first crash substep
var last_hit := {}        # подробности последней встречи с кромкой (угол, подход, доля нагрузки, доля порога), для стендов
var _sup_f := 0.0        # опора колеса на прошлом такте: от этой высоты колесо встречает следующую кромку
var _sup_r := 0.0
var riding := false
var lean := 0.0       # крен в повороте, радианы
var tilt := 0.0       # наклон вдоль склона или полёта, радианы
var wheel := 0.0      # угол поворота колёс
var crank := 0.0      # угол педалей
var steer := 0.0      # положение руля -1..1
var squash := 0.0     # средний ход подвески, м (меньше нуля — вытянулась при прыжке); для камеры и седока
var squash_f := 0.0   # ход вилки, м
var squash_r := 0.0   # ход заднего колеса, м
var squash_fv := 0.0  # скорость сжатия вилки, м/с
var squash_rv := 0.0
var ground_f := 0.0   # точка касания переднего колеса относительно y, м (в полёте — где колесо висит)
var ground_r := 0.0   # то же для заднего
var _g_f := 0.0       # высота земли под колёсами на прошлом такте и её вертикальная скорость
var _g_r := 0.0
var _gv_f := 0.0
var _gv_r := 0.0
var _o_f := 0.0       # высота корня или камня под колёсами на прошлом такте
var _o_r := 0.0
var _fresh := true    # колёса только встали на землю: прошлых высот нет, толчка не считаем
var _dist := 0.0      # пройденный путь, для покачивания
var air_time := 0.0   # сколько секунд в воздухе
var _hop_wait := 0.0  # после приземления прыжок доступен не сразу
var _hop_buf := 0.0   # пробел, нажатый чуть раньше, чем прыжок стал доступен
var _yaw_rate := 0.0   # фактическая угловая скорость поворота, рад/с
var _turn_scale := -1.0 # сглаженная наибольшая доступная угловая скорость: полный руль, рад/с (-1 — ещё не мерили)
var _coyote := 0.0     # запас прыжка после схода с края
var _brake_hold := 0.0 # сколько секунд держат тормоз у остановки
var _reverse_armed := true # тормоз отпускали после движения вперёд: удержание у остановки включит задний ход
var crashed := false  # седок упал: жёстко приземлился или врезался в стену (GameWorld покажет падение и сбросит флаг)
enum CrashCause { FALL, COLLISION, BRAKING, OBSTACLE }
var crash_cause := CrashCause.FALL
var crash_normal := Vector3.UP # наружу от препятствия или опоры
var crash_velocity := Vector3() # скорость велосипеда перед падением, м/с (для ragdoll)
var vertical_g := 0.0  # нагрузка профиля земли вдоль пути в g: впадина сжимает (+), гребень разгружает (−)
var bank_slope := 0.0  # наклон полотна поперёк: рост высоты на метр вправо от курса, сглаженный
var land_impact := 0.0 # сила последнего приземления, м/с (для тряски камеры); только приземления
var wheel_impact := Vector2() # удар переднего и заднего колеса о кромку за такт, м/с скорости колеса (GameWorld сбрасывает)
var bottom_out := 0.0  # 12.7: скорость удара вилки в упор, м/с (для звука; GameWorld сбрасывает)
var braking := 0.0     # 12.7: резкое торможение на скорости 0..1 (для хруста покрытия)
var fallen := false # рама остаётся в физической позе до ручной посадки
var fallen_transform := Transform3D.IDENTITY


## Поставить велосипед справа от игрока, лицом туда же, куда смотрит игрок
static func park_near(p: PlayerState, yaw: float, w: WorldData, heights: Heightfield) -> BikeRide:
	var b := BikeRide.new()
	b.heading = yaw
	b.x = p.x
	b.z = p.z
	b.y = p.feet
	for side: float in [1.6, -1.6]:
		var bx: float = p.x + cos(yaw) * side
		var bz: float = p.z - sin(yaw) * side
		if b.fits(bx, bz, yaw, w, heights):
			b.x = bx
			b.z = bz
			break
	b.y = heights.surface_at(b.x, b.z, p.feet)
	return b


func distance_to(p: PlayerState) -> float:
	return Grid.hypot(x - p.x, z - p.z)


## Можно ли сесть: велосипед рядом и на том же уровне (не на мосту над бредущим под ним игроком)
func can_mount(p: PlayerState) -> bool:
	return distance_to(p) <= GameConfig.BIKE_MOUNT and absf(y - p.feet) < MOUNT_RISE


## Поднимаем раму только рядом с игроком, на опору и без прохода сквозь стены.
## Отказ оставляет состояние велосипеда и игрока прежним.
func prepare_mount(p: PlayerState, w: WorldData, heights: Heightfield) -> bool:
	if not can_mount(p) or not p.on_ground:
		return false
	for radius: float in ([0.0, 0.5, 1.0, 1.5] if fallen else [0.0]):
		for i in (1 if radius == 0.0 else 8):
			var px := x + cos(i * TAU / 8.0) * radius
			var pz := z + sin(i * TAU / 8.0) * radius
			if Grid.hypot(px - p.x, pz - p.z) > GameConfig.BIKE_MOUNT:
				continue
			var floor_y := heights.surface_at(px, pz, y + 0.4)
			if absf(floor_y - p.feet) > 0.6 or heights.ceiling_at(px, pz, floor_y) < floor_y + 1.8:
				continue
			var destination := Vector3(px, floor_y, pz)
			if not BikeRecovery.clear_path(w, heights, Vector3(x, y, z), destination, true):
				continue
			if not BikeRecovery.clear_path(w, heights, Vector3(p.x, p.feet, p.z), destination):
				continue
			for direction: float in [heading, heading + PI * 0.5, heading - PI * 0.5]:
				if BikeRecovery.placement(w, heights, destination, direction).is_empty():
					continue
				x = px
				z = pz
				y = floor_y
				heading = direction
				return true
	return false


func mount(p: PlayerState) -> void:
	reset_motion()
	riding = true
	fallen = false
	speed = 0.0
	_yaw_rate = 0.0
	_coyote = 0.0
	_fresh = true
	p.x = x
	p.z = z
	p.vy = 0.0
	p.vx = 0.0
	p.vz = 0.0
	p.on_ground = true
	p.feet = y


## Обнулить движение, подвеску и отложенный ввод, не меняя местоположение: новая поездка, посадка, восстановление.
## Сбрасывается всё временное состояние, от которого зависят следующие подшаги и телеметрия, — контакт колёс
## (скользкость, силы, опоры), последнее событие падения, путь для фазы кочек. Накопительная статистика
## замеров (impacts, hop_height) остаётся: её сбрасывает reset_stats(). Положение и визуальные углы колёс
## и педалей (wheel, crank) тоже остаются.
func reset_motion() -> void:
	landing_info = {}
	crash_info = {}
	slick_f = 1.0
	slick_r = 1.0
	force_f = Vector2()
	force_r = Vector2()
	hit_dv = Vector2()
	_sup_f = 0.0
	_sup_r = 0.0
	_g_f = 0.0
	_g_r = 0.0
	_gv_f = 0.0
	_gv_r = 0.0
	_o_f = 0.0
	_o_r = 0.0
	_hop_from = 0.0
	_dist = 0.0
	tilt = 0.0
	crash_cause = CrashCause.FALL
	crash_normal = Vector3.UP
	crash_velocity = Vector3()
	_sub.fill(0.0)
	_side_use = 0.0
	_reverse_armed = true
	_share = 0.5
	effort = 0.0
	gear = GEAR_MIN
	drive_request = 0.0
	drive_force = 0.0
	brake_force = Vector2()
	roll_loss = 0.0
	air_loss = 0.0
	rough_loss = 0.0
	slope_force = 0.0
	pump_force = 0.0
	grade_now = 0.0
	feel_acceleration = 0.0
	pump_motion = 0.0
	pump_load = 0.0
	pump_accel = 0.0
	pump_wave = 0.0
	pump_pressed = false
	pump_active = 0.0
	pump_body = 0.0
	_pump_reach = 0.0
	_pump_absorb_v = 0.0
	_pump_wait = PUMP_PAUSE
	acceleration = 0.0
	vertical_g = 0.0
	bank_slope = 0.0
	lateral_speed = 0.0
	brakes.reset()
	grip_usage = 0.0
	slip = 0.0
	_corner_demand = 0.0
	braking = 0.0
	riding = false
	speed = 0.0
	lean = 0.0
	steer = 0.0
	squash = 0.0
	squash_f = 0.0
	squash_r = 0.0
	squash_fv = 0.0
	squash_rv = 0.0
	ground_f = 0.0
	ground_r = 0.0
	_fresh = true
	_hop_buf = 0.0
	_brake_hold = 0.0
	_yaw_rate = 0.0
	_turn_scale = -1.0
	_coyote = 0.0
	vy = 0.0
	air_time = 0.0
	_hop_wait = 0.0
	airborne = false
	crashed = false
	land_impact = 0.0
	wheel_impact = Vector2()
	bottom_out = 0.0
	body_back = false
	body_forward = false
	body_x = 0.0
	body_v = 0.0
	unweight = 0.0
	lift_f = 0.0
	lift_fv = 0.0
	lift_r = 0.0
	lift_rv = 0.0
	_auto_hop = -1.0
	_hop_link = 0.0
	_hop_front = 0.0
	_hop_front_v = 0.0
	_hop_used = false
	load_f = 0.5
	load_r = 0.5
	tire_f = 0.5
	tire_r = 0.5
	side_f = 0.5
	side_r = 0.5
	use_f = 0.0
	use_r = 0.0
	_rest_f = 0.0
	_rest_r = 0.0
	_on_f = -1
	_on_r = -1


## Накопительная статистика замеров: встречи колёс с кромками и высота последнего банни-хопа.
func reset_stats() -> void:
	impacts = Vector2i()
	hop_height = 0.0


## Слезть: велосипед остаётся на месте, игрок встаёт слева от него. В полёте слезть нельзя.
func dismount(p: PlayerState, w: WorldData, heights: Heightfield) -> void:
	reset_motion()
	y = heights.surface_at(x, z, y)
	p.vx = 0.0
	p.vy = 0.0
	p.vz = 0.0
	p.on_ground = true
	var spot := _dismount_spot(w, heights)
	p.x = spot.x
	p.z = spot.y
	p.feet = heights.surface_at(p.x, p.z, y)


## Место для седока у велосипеда: слева, справа, сзади или спереди, первое проходимое.
## Если рядом нигде не пройти, седок встаёт на место велосипеда
func _dismount_spot(w: WorldData, heights: Heightfield) -> Vector2:
	var fwd := Vector2(-sin(heading), -cos(heading))
	var dirs: Array[Vector2] = [Vector2(-cos(heading), sin(heading)), Vector2(cos(heading), -sin(heading)), -fwd, fwd]
	for dist: float in [0.9, 1.5]:
		for d: Vector2 in dirs:
			var q := Vector2(x, z) + d * dist
			var floor_y := heights.surface_at(q.x, q.y, y)
			if BikeRecovery.clear_path(w, heights, Vector3(x, y, z), Vector3(q.x, floor_y, q.y)) \
					and BikeRecovery.headroom(heights, q.x, q.y, floor_y):
				return q
	return Vector2(x, z)


## 14.0: подъём земли на метр пути вдоль курса (для выносливости): больше нуля — в гору по курсу
func grade(heights: Heightfield) -> float:
	return _slope(heights)


## Подъём земли на метр пути вдоль курса: от заднего колеса к переднему
func _slope(heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	if contact_model:
		# по опорам колёс: на бревне и валуне тоже подъём, который надо одолеть
		return (_wheel_ground(x + fx, z + fz, heights) - _wheel_ground(x - fx, z - fz, heights)) / (2.0 * HUB)
	return _ground_slope(heights)


## Уклон самой земли вдоль курса, без препятствий
func _ground_slope(heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (heights.surface_at(x + fx, z + fz, y) - heights.surface_at(x - fx, z - fz, y)) / (2.0 * HUB)


## Высота опоры в (px, pz): середина между точками касания колёс. Велосипед перекрывает
## мелкие изломы базой, а не повторяет каждый под одной точкой.
func _contact(px: float, pz: float, heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (_wheel_ground(px + fx, pz + fz, heights) + _wheel_ground(px - fx, pz - fz, heights)) * 0.5


## Высота земли под ступицей колеса как круга: ребро ступеньки или резкий гребень поднимают колесо
## плавно по дуге, а не проваливают в излом метровой сетки. На гладком рельефе равна высоте точки.
func _wheel_ground(px: float, pz: float, heights: Heightfield) -> float:
	var best := heights.surface_at(px, pz, y)
	var dx := -sin(heading) * WHEEL_REACH
	var dz := -cos(heading) * WHEEL_REACH
	var arc := sqrt(WHEEL_R * WHEEL_R - WHEEL_REACH * WHEEL_REACH) - WHEEL_R
	best = maxf(best, heights.surface_at(px + dx, pz + dz, y) + arc)
	best = maxf(best, heights.surface_at(px - dx, pz - dz, y) + arc)
	if contact_model and heights.obstacles != null:
		best = maxf(best, heights.obstacles.wheel_support(px, pz, WHEEL_R, ForestObstacles.CLIMB_MAX))
	return best


## Низкие препятствия встречает колесо, а не рама (модель двух контактов)
func _climb() -> float:
	return ForestObstacles.CLIMB_MAX if contact_model else 0.0


## Нагрузка от кривизны профиля вдоль курса и поперечный наклон полотна; оба сглажены от шума сетки.
func _read_surface(heights: Heightfield, dt: float) -> void:
	if airborne:
		vertical_g = lerpf(vertical_g, 0.0, Util.damp(G_RELAX_AIR, dt))
		return
	var ahead := Vector2(-sin(heading), -cos(heading)) * PROFILE_SPAN
	var g0 := heights.surface_at(x, z, y)
	var curve := (heights.surface_at(x + ahead.x, z + ahead.y, y) + heights.surface_at(x - ahead.x, z - ahead.y, y) - 2.0 * g0) / (PROFILE_SPAN * PROFILE_SPAN)
	var goal := clampf(speed * speed * curve / GameConfig.GRAVITY, G_MIN, G_MAX)
	vertical_g = lerpf(vertical_g, goal, Util.damp(G_RESPONSE, dt))
	var right := Vector2(cos(heading), -sin(heading)) * BANK_SPAN
	var cross := (heights.surface_at(x + right.x, z + right.y, y) - heights.surface_at(x - right.x, z - right.y, y)) / (2.0 * BANK_SPAN)
	bank_slope = lerpf(bank_slope, clampf(cross, -BANK_SLOPE_MAX, BANK_SLOPE_MAX), Util.damp(BANK_RESPONSE, dt))


## Уходит ли рельеф впереди из-под полёта: летим с нынешней вертикальной скоростью
## и смотрим, насколько ниже окажется земля через 0,1–0,3 с.
func _lifts(heights: Heightfield) -> bool:
	var velocity := horizontal_velocity()
	var fx := velocity.x
	var fz := velocity.y
	# 30.10: на волне седок гасит ногами часть вертикальной скорости, набранной на подъёме гребня (PUMP_ABSORB_V):
	# без этого на 12+ м/с каждый подъём волны 5–6 м выбрасывал велосипед в полёт
	var lift_v := vy - _pump_absorb_v
	for t: float in LOOK:
		var fly := y + lift_v * t - GameConfig.GRAVITY * t * t * 0.5
		if fly - _contact(x + fx * t, z + fz * t, heights) > LIFT + _pump_reach:
			return true
	return false


## Короткий профиль по направлению движения. Длинный уклон вычитается: ровная гора не становится пампом.
## Вызывается до сил/вертикали, поэтому ручной ввод выключает помощь в том же подшаге.
func _step_pump(dt: float, throttle: float, turn: float, hop: bool, heights: Heightfield) -> void:
	pump_accel = 0.0
	pump_load = 0.0
	_pump_reach = 0.0
	_pump_absorb_v = 0.0
	pump_wave = 0.0
	var held := pump_active
	# короткий отрыв не стирает «на волне»: посадка на следующий подъём тоже поглощается
	pump_active = held * exp(-dt / PUMP_HOLD)
	pump_body = 0.0
	_pump_wait = maxf(0.0, _pump_wait - dt)
	if not pump_pressed or not pump_enabled:
		pump_active = 0.0
		pump_motion = lerpf(pump_motion, 0.0, Util.damp(12.0, dt))
		return
	# 30.10: ручная работа телом больше не выключает памп — она и есть памп (ниже). Автоматика уступает ей место
	# плавно; целиком памп снимают только прыжок, тормоз, занос и отрыв.
	var blocked := hop or _auto_hop >= 0.0 or _hop_buf > 0.0 or _hop_used or throttle < -0.05 or brake_pressure > 0.1 or absf(slip) > 0.12
	var body_work := clampf(absf(body_x) / 0.3 + absf(body_v) / 1.2, 0.0, 1.0)
	if blocked or airborne or _fresh:
		_pump_wait = PUMP_PAUSE
	# пауза после приземления и ручного действия — только для толчка автоматики: гребень сразу после посадки тоже
	# поглощается, иначе на скорости велосипед не возвращался на волны до конца серии
	var ready := pump_enabled and riding and not crashed and not airborne and not blocked
	ready = ready and speed > 2.0 and _on_f < 0 and _on_r < 0
	ready = ready and heights.immersion_at(x, z, y) < 0.03
	var motion := 0.0
	if ready:
		var direction := horizontal_velocity().normalized()
		# 30.10: не длиннее 1 м — раньше до 1,6 м, и на 12+ м/с волна 5–6 м уже выглядела ступенькой: памп выключался
		var span := clampf(absf(speed) * 0.12, 0.8, 1.0)
		var levels := PackedFloat32Array()
		var clear := true
		for i in range(-2, 3):
			var at := Vector2(x, z) + direction * span * i
			# Одна и та же доступная земля: не качаемся через край настила, неизвестную область или воду.
			if not heights.known(at.x, at.y) or is_finite(heights.deck_at(at.x, at.y, INF)) or heights.immersion_at(at.x, at.y, y) > 0.03:
				clear = false
				break
			levels.append(heights.surface_at(at.x, at.y, y))
		if clear:
			var previous := 0.0
			for i in 4:
				var grade := (levels[i + 1] - levels[i]) / span
				# Ступень/стена/гэп и очень крутой кикер остаются штатными препятствиями и вылетами.
				if absf(grade) > 0.65 or (i > 0 and absf(grade - previous) > PUMP_KINK * span): clear = false
				previous = grade
		if clear:
			var local_grade := (levels[3] - levels[1]) / (2.0 * span)
			var long_grade := (levels[4] - levels[0]) / (4.0 * span)
			var wave := local_grade - long_grade
			var hollow := (levels[1] + levels[3]) * 0.5 - levels[2]
			var activity := smoothstep(0.01, 0.07, absf(hollow)) * smoothstep(2.0, 5.0, speed)
			# для ручного пампа — настоящий местный уклон: на ровной горе нажатие и возврат тела взаимно гасятся
			pump_wave = local_grade
			# кривизна (hollow) проходит через ноль на середине склона волны, где уклон наибольший: «на волне» держится
			# PUMP_HOLD секунд после последнего заметного изгиба, а не мигает дважды за волну
			pump_active = maxf(activity, held * exp(-dt / PUMP_HOLD)) * smoothstep(2.0, 5.0, speed)
			# Автоматика — спокойный седок: слегка сгибается на гребне и давит на обратный склон. Уступает
			# ручной работе телом и заметному рулю плавно, без паузы возврата.
			var auto := (1.0 if _pump_wait <= 0.0 else 0.0) * (1.0 - body_work) * (1.0 - smoothstep(PUMP_STEER_LIMIT, 0.8, absf(turn))) * (1.0 if lift_f <= 0.0 and lift_r <= 0.0 else 0.0)
			motion = clampf(wave * 1.8 - hollow * 3.0, -1.0, 1.0) * activity * auto
			var pace := 1.0 - smoothstep(PUMP_TOP - 4.0, PUMP_TOP, speed)
			pump_accel = minf(1.0, maxf(0.0, -wave) * PUMP_ACCEL) * activity * pace * auto
			pump_load = clampf(-wave * 0.65, -0.12, 0.2) * activity * auto
			# 30.10: гребень поглощают ноги и руки на любой скорости (раньше ход тела исчезал к 14 м/с, и с 12 м/с велосипед
			# летел с каждой волны 5–6 м); исчезает только толчок автоматики, ход тела остаётся и при ручной работе
			# гасим только волну — впереди или под нами гребень, за которым спуск; кромка кикера перед ровным столом
			# подбрасывает, как прежде
			var backside := smoothstep(0.03, 0.12, maxf(levels[2], levels[3]) - levels[4])
			_pump_reach = PUMP_REACH * pump_active * backside
			_pump_absorb_v = PUMP_ABSORB_V * pump_active * backside
			# Ручной памп — один закон для обеих фаз: сколько веса тело добавило к опоре (E — продавить, рывок вперёд-
			# вниз) или сняло с неё (Q — поглотить, рывок назад-вверх), столько этой нагрузки работает на уклоне волны,
			# a = −g · Δнагрузки · уклон. Продавить обратный склон или поглотить подъём — разгон; наоборот — торможение.
			# Поглощение ещё и держит колёса на гребне (ход тела), продавливание прижимает их к земле.
			pump_body = clampf(-body_v / BODY_RATE, -1.0, 1.0) * PUMP_BODY
			var manual_pace := 1.0 - smoothstep(PUMP_TOP, PUMP_TOP + 6.0, speed)
			pump_load += pump_body * pump_active
			pump_accel += clampf(-GameConfig.GRAVITY * pump_body * local_grade, -PUMP_BODY_ACCEL, PUMP_BODY_ACCEL) * pump_active * manual_pace
			_pump_reach += PUMP_REACH * 1.5 * maxf(0.0, -pump_body / PUMP_BODY) * pump_active
			_pump_absorb_v += PUMP_ABSORB_V * 0.5 * maxf(0.0, -pump_body / PUMP_BODY) * pump_active
	pump_motion = lerpf(pump_motion, motion, Util.damp(12.0, dt))


## Шаг езды за dt секунд (в игре — один такт физики, 1/60 с). throttle — газ (+) и тормоз (-),
## turn — руль вправо (+) и влево (-), hop — пробел нажат в этом такте (срабатывает, как только прыжок
## доступен, если ждать недолго).
func step(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	# Один и тот же короткий шаг при 30/60/120 Гц; hop передаётся только первому подшагу.
	# Существующие рельеф, вода и подвеска остаются в том же цикле, без новой вертикальной модели.
	# Упавший велосипед ждёт BikeController (ragdoll); новых импульсов и событий у него нет.
	landing_info = {}
	if dt <= 0.0 or crashed:
		return
	var ticks := ceili(dt * SUB_HZ) if dt > 1.0 / SUB_HZ + 0.000001 else 1
	var start := horizontal_velocity()
	var sums := PackedFloat32Array()
	sums.resize(TELEMETRY)
	var done := 0.0
	for i in ticks:
		_substep(p, throttle, turn, boost, hop and i == 0, dt / ticks, w, heights)
		done += dt / ticks
		for k in TELEMETRY:
			sums[k] += _sub[k] * dt / ticks
		if crashed:
			break
	_end_tick(sums, done, start)


## Силы и сигналы за последний внешний шаг (средние по подшагам), м/с² на массу велосипеда с седоком.
## Дают седоку, камере и звуку одни и те же данные за тот же интервал, а не значение последнего подшага.
enum { T_DRIVE_REQUEST, T_DRIVE, T_BRAKE_F, T_BRAKE_R, T_ROLL, T_AIR, T_ROUGH, T_SLOPE, T_PUMP, T_GRADE, TELEMETRY }
var _sub := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var drive_request := 0.0   # запрос педалей до ограничения контактом и сцеплением
var drive_force := 0.0     # реализованная тяга заднего колеса
var brake_force := Vector2() # фактически приложенный тормоз переднего и заднего колеса
var roll_loss := 0.0       # качение по покрытию
var air_loss := 0.0        # воздух (на земле и в полёте один закон)
var rough_loss := 0.0      # неровности и потери на большой скорости
var slope_force := 0.0     # тяжесть вдоль пути: больше нуля — разгоняет
var pump_force := 0.0      # помощь автопампа
var grade_now := 0.0       # геометрический уклон земли вдоль курса (без подвески и тела), м на м
var feel_acceleration := 0.0 # продольное ускорение по мировой скорости за внешний шаг: перепроекция рамы его не даёт
var tick_time := 0.0       # длительность последнего внешнего шага, с
## Продольная сила в пятнах контакта за внешний шаг (тяга минус тормоз): перенос нагрузки, которую принимает тело
var contact_acceleration: float:
	get: return drive_force - brake_force.x - brake_force.y


func _end_tick(sums: PackedFloat32Array, done: float, start: Vector2) -> void:
	tick_time = done
	var inv := 1.0 / maxf(done, 0.000001)
	drive_request = sums[T_DRIVE_REQUEST] * inv
	drive_force = sums[T_DRIVE] * inv
	brake_force = Vector2(sums[T_BRAKE_F], sums[T_BRAKE_R]) * inv
	roll_loss = sums[T_ROLL] * inv
	air_loss = sums[T_AIR] * inv
	rough_loss = sums[T_ROUGH] * inv
	slope_force = sums[T_SLOPE] * inv
	pump_force = sums[T_PUMP] * inv
	grade_now = sums[T_GRADE] * inv
	var forward := Vector2(-sin(heading), -cos(heading))
	feel_acceleration = (horizontal_velocity() - start).dot(forward) * inv


## Подшаг езды; step() делит внешний шаг на них и собирает сигналы.
func _substep(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	_sub.fill(0.0)
	# Порядок подшага и возраст данных (контракт; переставлять фазы нельзя — от него зависят задержки):
	# 1. покрытие читается один раз в начале (Footing);
	# 2. продольная сила: педали и тормоз берут нагрузки, скользкость и боковую силу шин с прошлого подшага;
	# 3. курс и боковая сила: руль, доворот из заноса, снос — запас шин тоже с прошлого подшага;
	# 4. перемещение со столкновениями; 5. вертикаль: опора, прыжок, полёт, свод;
	# 6. колёса на опоре: кромки, кочки, скользкость — для следующего подшага;
	# 7. подвеска и нагрузки колёс, тело седока и Q/E — для следующего подшага; 8. поза рамы для вида.
	# Любое падение завершает подшаг сразу (_sync) и сохраняет первое событие.
	var f := _read_footing(turn, w, heights)
	var speed0 := speed
	_step_longitudinal(f, throttle, turn, boost, hop, dt, heights)
	if crashed:
		_sync(p)
		return
	_read_surface(heights, dt)
	var free_now := fits(x, z, heading, w, heights)
	var lateral := _step_heading(f, free_now, turn, dt, w, heights)
	if crashed:
		_sync(p)
		return
	_step_move(free_now, dt, w, heights)
	if crashed:
		_sync(p)
		return
	_step_vertical(_contact(x, z, heights), hop, dt, heights)
	# Непрерывный крутой склон раньше подменял падение покадровой привязкой к земле.
	# Даже медленный съезд по почти отвесной стене теперь теряет равновесие и запускает ragdoll.
	if not crashed and not airborne and absf(speed) > 0.25 and f.slope * signf(speed) < -CLIFF_GRADE:
		_crash(vy, Vector3(sin(heading) * f.slope, 1.0, cos(heading) * f.slope).normalized())
	if crashed:
		_sync(p)
		return
	_step_wheels(heights, f.rough, dt, f.surf, f.path_weight, f.slope, f.across)
	if crashed:
		_sync(p)
		return
	acceleration = clampf((speed - speed0) / maxf(dt, 0.0001), -9.0, 12.0)
	_step_suspension(dt, minf(absf(lateral) * 0.001, 0.015) + clampf(vertical_g, G_MIN, G_MAX) * SAG_MAX * PROFILE_SAG, _sub[T_DRIVE] - _sub[T_BRAKE_F] - _sub[T_BRAKE_R])
	_step_contacts(f.slope, dt)
	_step_pose(throttle, lateral, dt)
	_sync(p)


## Покрытие под велосипедом на один подшаг: уклон по опорам колёс, путь, сцепление и неровность.
class Footing:
	var slope := 0.0
	var surf := RoadSurface.NONE
	var path_weight := 0.0
	var across := 0.0
	var terrain := 1.0   # общая скорость передвижения по покрытию (PlayerState.terrain_speed), как у пешехода
	var pace := 1.0      # велосипед: доля крейсерской скорости, к которой тянут педали
	var rolling := 1.0   # велосипед: лёгкость качения (сопротивление BIKE_ROLL / rolling)
	var rough := 0.0
	var grip := 0.85
	var technical := 0.0


func _read_footing(turn: float, w: WorldData, heights: Heightfield) -> Footing:
	var f := Footing.new()
	# Резерв поворота в тормозе — по фактическому положению руля (оно догоняет ввод с той же скоростью, что и курс)
	# и по боковой силе, которую шины держат сейчас: на выходе из дуги руль уже прямо, а снос ещё гасится.
	# Раньше — по сырому вводу: на входе резерв появлялся раньше поворота, на выходе исчезал раньше сноса.
	_corner_demand = maxf(absf(steer) * smoothstep(3.0, 10.0, absf(speed)), _side_use)
	f.slope = _slope(heights)
	_sub[T_GRADE] = _ground_slope(heights)
	var contact := RideSurface.sample(w, heights, x, z)
	f.surf = contact.surface
	f.path_weight = contact.weight
	f.across = contact.across
	f.terrain = maxf(0.15, PlayerState.terrain_speed(w, x, z, heights))
	# Параметры велосипеда отдельно от пешей скорости: пока те же числа, настраиваются здесь независимо.
	f.pace = f.terrain
	f.rolling = f.terrain
	f.rough = clampf(1.3 - f.terrain, 0.15, 1.0)
	if f.surf != RoadSurface.NONE:
		f.grip = lerpf(f.grip, RoadSurface.LIST[f.surf].grip, f.path_weight)
		f.rough = lerpf(f.rough, RoadSurface.LIST[f.surf].rough, f.path_weight)
	# На корнях и камнях медленный проезд точный; быстрый требует более широкой дуги.
	f.technical = smoothstep(0.25, 0.8, f.rough) * smoothstep(6.0, 15.0, absf(speed))
	f.grip *= 1.0 - f.technical * 0.2
	return f


## Продольное движение подшага: педали, тормоз и автопамп на земле, накат в воздухе. Может уронить (перелёт).
func _step_longitudinal(f: Footing, throttle: float, turn: float, boost: bool, hop: bool, dt: float, heights: Heightfield) -> void:
	# При постановке на склон велосипед уже движется вдоль опоры. vy=0 здесь создавал
	# ложный отрыв на спуске ещё до Q, после чего подготовка баннихопа пропадала.
	if _fresh and not airborne:
		y = _contact(x, z, heights)
		vy = _ground_slope(heights) * speed
	_step_pump(dt, throttle, turn, hop, heights)
	if not airborne:
		var water := lerpf(1.0, 0.4, smoothstep(0.05, 0.8, heights.immersion_at(x, z, y)))
		_step_speed(throttle, boost, f.slope, f.pace * water, dt, f.grip, f.technical, f.rolling * water)
		if brakes.tipped:
			_crash(vy, Vector3.UP, CrashCause.BRAKING)
	else:
		# В воздухе педали и тормоз не меняют скорость и не готовят задний ход; ноги перестают давить.
		_step_effort(0.0, dt)
		_brake_hold = 0.0
		brakes.step(dt, 0.0, speed, f.slope, f.grip, 0.0, false)
		braking = 0.0
		# Тот же воздух, что на земле, по полной горизонтальной скорости: отрыв не меняет закон сопротивления.
		var v := Vector2(speed, lateral_speed)
		var keep := 1.0 / (1.0 + AIR_DRAG * v.length() * dt)
		_sub[T_AIR] = speed * (1.0 - keep) / dt
		speed *= keep
		lateral_speed *= keep


func _step_effort(want: float, dt: float) -> void:
	if not effort_ramp:
		effort = want
		return
	effort = lerpf(effort, want, 1.0 - exp(-dt / (EFFORT_RISE if want > effort else EFFORT_FALL)))


## Курс и боковая сила: руль и доворот из заноса в пределах габарита, затем перепроекция скорости и снос.
## Возвращает боковое ускорение (для крена и подвески). Большой снос на скорости роняет набок.
func _step_heading(f: Footing, free_now: bool, turn: float, dt: float, w: WorldData, heights: Heightfield) -> float:
	var grip := f.grip
	var h0 := heading
	heading += _step_turn(turn, grip, dt, brake_deceleration / maxf(CORNER_GRIP * grip, 0.1))
	# Вплотную к стене колесо не поворачивается в неё, накопленного рывка тоже нет.
	if free_now and not fits(x, z, heading, w, heights):
		heading = h0
		_yaw_rate = 0.0
	if contact_model and not airborne:
		# Доворот из заноса проходит ту же проверку габарита, что и руль: у стены рама остаётся на принятом курсе,
		# а снос гасит боковая сила. Скорость перепроецируется ниже от h0 на итоговый курс.
		var turned := heading
		heading += _align(dt)
		if free_now and not fits(x, z, heading, w, heights):
			heading = turned
		if absf(slip) > SLIDE_CRASH and Vector2(speed, lateral_speed).length() > SLIDE_CRASH_SPEED:
			var side := Vector2(cos(heading), -sin(heading)) * signf(lateral_speed)
			_crash(vy, Vector3(-side.x, 0.4, -side.y), CrashCause.FALL)
			return 0.0
	return _step_traction(h0, grip, dt)


## Перемещение подшага со столкновениями: скольжение вдоль стен и препятствий, потеря скорости, удар в лоб.
## free_now — велосипед до шага помещался; иначе выехать можно, проверяется середина.
func _step_move(free_now: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	var x0 := x
	var z0 := z
	var velocity := horizontal_velocity()
	var dx := velocity.x * dt
	var dz := velocity.y * dt
	var wanted := Vector3(dx, 0, dz)
	var full := velocity.length() * dt
	if full > 0.0:
		# если велосипед уже задевает препятствие (поставлен вплотную), выехать можно: проверяется середина
		var hd := heading
		var free := func(px: float, pz: float) -> bool:
			if free_now:
				return fits(px, pz, hd, w, heights)
			if PlayerState.is_passable(w, heights, px, pz, y, 0.0, false, _climb()):
				return true
			# 11.7: после прыжка середина внутри валуна или бревна: наружу выехать можно, иначе застрял бы
			# (прыжок ниже верха валуна), а вглубь и в сторону — нет
			if heights.obstacles == null or not w.accessible(px / GameConfig.TILE, pz / GameConfig.TILE) or not heights.known(px, pz) \
					or heights.depth_at(px, pz, y) >= GameConfig.FORD_DEPTH:
				return false
			return heights.obstacles.normal(x, z, y, 0.0, _climb()).dot(Vector2(px - x, pz - z)) > 0.0
		# 7.7: вдоль ствола и бревна велосипед скользит по касательной
		var around := Callable()
		if heights.obstacles != null:
			around = func(px: float, pz: float) -> Vector2: return obstacle_normal(px, pz, hd, heights)
		var to := PlayerState.slide(free, x, z, dx, dz, around)
		x = to[0]
		z = to[1]
		var moved := Grid.hypot(x - x0, z - z0)
		if moved < full - 1e-5:
			# в лоб скорость гаснет, при скольжении вдоль стены почти нет
			var blocked := Vector3(x - x0, 0.0, z - z0) - wanted
			var normal := blocked.normalized()
			var impact := maxf(0.0, -Vector3(velocity.x, 0, velocity.y).dot(normal))
			# 11.6: щуп на весь несделанный кусок пути: тонкое бревно, на котором встали за 0,1–0,2 м, тоже удар
			# 11.7: не дальше куска шага: то, что остановило, лежит в его пределах, а не за ним
			var ahead := wanted.normalized() * maxf(PlayerState.PIECE * 0.5, minf(full - moved, PlayerState.PIECE) + 0.01)
			var solid := false
			for axle: float in [-AXLE, 0.0, AXLE]:
				if not PlayerState.is_passable(w, heights, x + ahead.x - sin(heading) * axle, z + ahead.z - cos(heading) * axle, y, BODY_R, true, _climb()):
					solid = true
					break
			# Удар о предмет опасен и в прыжке; вода и граница открытой земли не являются стеной.
			if solid and impact > WALL_CRASH:
				_crash(vy, normal, CrashCause.COLLISION)
			var keep := 0.0 if moved < 1e-5 else _slide_keep(dt, moved, full)
			speed *= keep
			lateral_speed *= keep
	_dist += Grid.hypot(x - x0, z - z0)


## Поза рамы для вида: наклон по подвескам или траектории, крен от поворота, углы колёс и педалей.
func _step_pose(throttle: float, lateral: float, dt: float) -> void:
	# Рама лежит на концах подвесок: колёса на точках касания, рама — выше на свой ход у каждого.
	# Разгон и торможение наклоняют её через подвеску (PITCH_LOAD), отдельного покачивания нет.
	var tilt_goal := atan2((ground_f - squash_f) - (ground_r - squash_r), 2.0 * HUB) + unweight * PULL_PITCH
	if airborne:
		tilt_goal = clampf(atan2(vy, maxf(absf(speed), AIR_TILT_SPEED)), -AIR_TILT_MAX, AIR_TILT_MAX)
		if speed < 0.0:
			tilt_goal = -tilt_goal
	tilt = lerpf(tilt, tilt_goal, Util.damp(TILT_RESPONSE_AIR if airborne else TILT_RESPONSE, dt))
	# Крен от реального поворота, а не от кнопки: на месте не заваливаемся.
	# Умеренный визуальный крен (до 16°), без изменения радиуса поворота и сцепления.
	var lean_goal := 0.0 if airborne else clampf(atan(lateral / GameConfig.GRAVITY) * LEAN_SHARE, -LEAN_MAX, LEAN_MAX)
	lean = lerpf(lean, lean_goal, Util.damp(LEAN_RESPONSE_AIR if airborne else LEAN_RESPONSE, dt))

	# углы держим в пределах оборота, чтобы за долгую езду они не теряли точность
	wheel = fmod(wheel + speed * dt / WHEEL_R, TAU)
	# Виртуальная автоматическая передача: каденс растёт с темпом от 60 до 90 об/мин, а не вместе со скоростью
	# через одну передачу. Подбирается плавно и накатом, чтобы повторный газ начинался с подходящей передачи.
	var wheel_rate := maxf(speed, 0.0) / WHEEL_R
	var wanted_gear := clampf(wheel_rate / lerpf(CADENCE_LOW, CADENCE_HIGH, smoothstep(2.0, 9.0, speed)), GEAR_MIN, GEAR_MAX)
	gear = lerpf(gear, wanted_gear, Util.damp(GEAR_RESPONSE, dt))
	# педали крутятся, только пока их жмут на земле: накатом и в полёте свободный ход; на старте видно нажатие
	if throttle > 0.0 and not airborne and (speed > 0.3 or effort > 0.05):
		crank = fmod(crank + maxf(wheel_rate / gear, effort * START_CRANK) * dt, TAU)


## Игрока везёт велосипед: положение и опора — отсюда, в конце подшага или при падении.
func _sync(p: PlayerState) -> void:
	p.x = x
	p.z = z
	p.feet = y
	p.vy = vy
	p.on_ground = not airborne


## Полная горизонтальная скорость для движения, полёта и передачи импульса падению.
func horizontal_velocity() -> Vector2:
	var forward := Vector2(-sin(heading), -cos(heading))
	return forward * speed + Vector2(-forward.y, forward.x) * lateral_speed


## Рама доворачивается раньше траектории. В воздухе только меняем систему координат.
func _step_traction(old_heading: float, grip: float, dt: float) -> float:
	var old_forward := Vector2(-sin(old_heading), -cos(old_heading))
	var velocity := old_forward * speed + Vector2(-old_forward.y, old_forward.x) * lateral_speed
	var forward := Vector2(-sin(heading), -cos(heading))
	var side := Vector2(-forward.y, forward.x)
	speed = velocity.dot(forward)
	lateral_speed = velocity.dot(side)
	var lateral := 0.0
	if not airborne and contact_model:
		# Тяжесть поперёк полотна: на контруклоне тянет вниз, на вираже — внутрь поворота. Шины держат её вместе
		# со сносом из своего запаса; стоящий седок упирается ногой.
		var s := clampf(bank_slope, -BANK_SLOPE_MAX, BANK_SLOPE_MAX)
		lateral_speed -= GameConfig.GRAVITY * s / sqrt(1.0 + s * s) * smoothstep(SIDE_HOLD_SPEED * 0.5, SIDE_HOLD_SPEED * 2.0, absf(speed)) * dt
		var caps := _side_caps(grip)
		var cap_f := CORNER_GRIP * RIDER_GRIP * grip * side_f * slick_f
		var cap_r := CORNER_GRIP * RIDER_GRIP * grip * side_r * slick_r
		var free_f := caps.x
		var free_r := caps.y
		# Седок балансирует нагрузку: второе колесо использует свободный запас первого.
		# Руль ограничен теми же силами с резервом, поэтому обычная дуга не порождает вечный снос.
		var need := lateral_speed * Util.damp(SIDE_RESPONSE, dt) / dt
		var total := maxf(free_f + free_r, 0.0001)
		var side_force_f := clampf(need * free_f / total, -free_f, free_f)
		var side_force_r := clampf(need * free_r / total, -free_r, free_r)
		lateral = side_force_f + side_force_r
		_side_use = clampf(absf(lateral) / maxf(cap_f + cap_r, 0.1), 0.0, 1.0)
		lateral_speed -= lateral * dt
		force_f = Vector2(brakes.front_force, side_force_f)
		force_r = Vector2(_rear_long(), side_force_r)
		use_f = clampf(force_f.length() / maxf(cap_f, 0.01), 0.0, 1.0) if cap_f > 0.001 else (1.0 if absf(need) > 0.01 else 0.0)
		use_r = clampf(force_r.length() / maxf(cap_r, 0.01), 0.0, 1.0) if cap_r > 0.001 else (1.0 if absf(need) > 0.01 else 0.0)
		grip_usage = clampf(Vector2(brake_deceleration, lateral).length() / maxf(cap_f + cap_r, 0.1), 0.0, 1.0)
	elif not airborne:
		var capacity := CORNER_GRIP * grip
		# Вираж держит и сам занос, а не только доворот рамы: иначе на вираже рама поворачивала,
		# а велосипед уходил наружу так же, как на ровном, только с бо́льшим углом сноса.
		capacity += _bank_assist(signf(lateral_speed), absf(speed), capacity)
		var available := sqrt(maxf(0.0, capacity * capacity - brake_deceleration * brake_deceleration))
		var correction := lateral_speed * Util.damp(GameConfig.BIKE_SIDE_RESPONSE, dt)
		correction = clampf(correction, -available * dt, available * dt)
		lateral_speed -= correction
		lateral = correction / dt
		grip_usage = clampf(Vector2(brake_deceleration, lateral).length() / maxf(capacity, 0.1), 0.0, 1.0)
	else:
		grip_usage = 0.0
		_side_use = 0.0
		use_f = 0.0
		use_r = 0.0
		force_f = Vector2()
		force_r = Vector2()
	slip = atan2(lateral_speed, maxf(absf(speed), 2.0))
	return lateral


## Продольная сила заднего колеса в этом подшаге: тормоз минус реализованная тяга педалей (один круг сцепления).
func _rear_long() -> float:
	return brakes.rear_force - _sub[T_DRIVE]


## Один запас для запроса руля и удержания траектории; тормоз и тяга уже заняли свою часть.
func _side_caps(grip: float) -> Vector2:
	var cap_f := CORNER_GRIP * RIDER_GRIP * grip * side_f * slick_f if contact_f() else 0.0
	var cap_r := CORNER_GRIP * RIDER_GRIP * grip * side_r * slick_r if contact_r() else 0.0
	return Vector2(sqrt(maxf(0.0, cap_f * cap_f - brakes.front_force * brakes.front_force)),
		sqrt(maxf(0.0, cap_r * cap_r - _rear_long() * _rear_long())))


## Добавка к сцеплению flat (м/с²) от наклона полотна: drift — куда велосипед несёт поперёк рамы (+ вправо).
## Полотно, поднятое в сторону заноса, прижимает колёса; опущенное — отнимает. Как на наклонном вираже:
## тяжесть сама держит поворот, а прижатые колёса ещё и сильнее цепляются, g·(μ + s) / (1 − μ·s).
## Раньше бралась только доля тяжести без прижима, и вираж почти не отличался от плоского поворота.
func _bank_assist(drift: float, pace: float, flat: float) -> float:
	var s := clampf(bank_slope * drift, -BANK_SLOPE_MAX, BANK_SLOPE_MAX)
	var mu := flat / GameConfig.GRAVITY
	var banked := GameConfig.GRAVITY * (mu + s) / maxf(1.0 - mu * s, 0.5)
	return clampf(banked - flat, -flat * 0.4, flat * (BANK_LIMIT - 1.0)) * smoothstep(2.0, 6.0, pace)


## Модель двух контактов: снос больше ALIGN_SLIP доворачивает раму к направлению движения (на шаге dt, рад).
## Курс уменьшается — поворот вправо (как у _step_turn), а снос вправо (lateral_speed > 0) — движение правее рамы.
func _align(dt: float) -> float:
	var excess := absf(slip) - ALIGN_SLIP
	if excess <= 0.0 or absf(speed) < 0.5:
		return 0.0
	return -signf(slip) * minf(excess, ALIGN_RATE * dt)


## Руль отзывчив на малой скорости; на большой сцепление расширяет дугу и чуть съедает ход.
## Боковая инерция и торможение делят общий запас сцепления.
func _step_turn(turn: float, grip: float, dt: float, brake := 0.0) -> float:
	steer = move_toward(steer, turn, dt * (STEER_CENTER if is_zero_approx(turn) else STEER_RATE) * (RIDER_STEER if contact_model else 1.0))
	var pace := absf(speed)
	# На малой скорости манёвр лёгкий; на большой у перекладки появляется вес.
	var response := lerpf(TURN_RESPONSE_SLOW, TURN_RESPONSE_FAST, smoothstep(TURN_PACE_LOW, TURN_PACE_HIGH, pace)) * (1.0 if contact_model else grip)
	if contact_model:
		response = maxf(response, RIDER_TURN_RESPONSE)
	var rate := GameConfig.BIKE_TURN * clampf(pace / 3.0, 0.0, 1.0) / (1.0 + pace * 0.04)
	var wanted := -steer * rate * (1.0 if speed >= 0.0 else -1.0)
	var limit := rate
	if airborne:
		wanted *= 0.25
		limit *= 0.25
		response = 3.0
	else:
		# Торможение расходует часть сцепления: дуга шире, но управление сохраняется.
		var corner_grip := CORNER_GRIP * grip * sqrt(maxf(0.0, 1.0 - brake * brake))
		if contact_model:
			var caps := _side_caps(grip)
			# Переднее по-прежнему задаёт курс, но рама не требует больше, чем держат обе шины.
			corner_grip = minf(2.0 * caps.x, caps.x + caps.y) * TURN_RESERVE
		# Накопленный снос расширяет дугу до восстановления, вместо бесконечного дрифта.
		var slip_yaw := lerpf(GameConfig.BIKE_SLIP_YAW, 0.92, smoothstep(0.04, GameConfig.BIKE_SLIP_RECOVER, absf(slip)))
		if not contact_model:
			corner_grip *= lerpf(1.0, slip_yaw, smoothstep(5.0, 12.0, pace))
		# Вираж: полотно, поднятое снаружи поворота, прижимает колёса и добавляет сцепления; уклон внутрь отнимает.
		if contact_model:
			# Вираж — тяжестью: полотно, поднятое снаружи поворота, тянет внутрь; контруклон тянет наружу
			var s := clampf(bank_slope * -signf(steer), -BANK_SLOPE_MAX, BANK_SLOPE_MAX)
			corner_grip = maxf(0.0, corner_grip + GameConfig.GRAVITY * s / sqrt(1.0 + s * s) * smoothstep(2.0, 6.0, pace))
		else:
			corner_grip += _bank_assist(-signf(steer), pace, corner_grip)
		limit = minf(rate, corner_grip / maxf(pace, 3.0))
		var excess := maxf(0.0, absf(wanted) * pace - corner_grip)
		if contact_model:
			# 30.10: руль задаёт долю доступной дуги, а не долю геометрического хода. Раньше на скорости уже треть
			# руля упиралась в сцепление: команда быстро становилась предельной, а дуга менялась с нагрузкой колеса на
			# каждой волне. Теперь полный руль — самая крутая дуга, которую шины держат в среднем за TURN_SCALE_RELAX,
			# часть руля — такая же часть её; короткая разгрузка (гребень, Q) по-прежнему режет поворот пределом limit.
			if _turn_scale < 0.0: _turn_scale = limit
			_turn_scale = lerpf(_turn_scale, limit, 1.0 - exp(-dt / TURN_SCALE_RELAX))
			wanted = -steer * minf(rate, _turn_scale) * (1.0 if speed >= 0.0 else -1.0)
		wanted = clampf(wanted, -limit, limit)
		# Потеря хода — от настоящей перегрузки шины, а не просто от удержания клавиши на скорости.
		if not contact_model:
			speed = move_toward(speed, 0.0, excess * 0.08 * dt)
	_yaw_rate = move_toward(_yaw_rate, wanted, response * dt)
	# Остаточная инерция не вращает стоящий велосипед и не превышает сцепление.
	if contact_model and not airborne and pace > 1.0:
		# у рамы с седоком есть инерция: когда запас переднего колеса падает (гребень, рывок на себя), поворот гаснет
		# за доли секунды, а не обрывается в такт — избыток уходит в снос
		_yaw_rate = move_toward(_yaw_rate, clampf(_yaw_rate, -limit, limit), YAW_DROP * dt)
	else:
		_yaw_rate = clampf(_yaw_rate, -limit, limit)
	return _yaw_rate * dt


## Опора держит мелкие неровности и изломы; отрыв — только с края или когда рельеф впереди
## уходит вниз быстрее, чем позволяет тяжесть на этой скорости (гребень, трамплин).
func _step_vertical(g: float, hop: bool, dt: float, heights: Heightfield) -> void:
	# Перекрытие ищется от высоты до шага: подъём сквозь настил не переносит седока на мост.
	var feet0 := y
	_step_height(g, hop, dt, heights)
	if airborne:
		var top := _roof_over(x, z, heading, feet0, heights) - BikeRecovery.CLEARANCE
		if y > top:
			# Седок упёрся в свод: подъём гаснет, дальше обычное падение до опоры.
			y = maxf(top, g)
			vy = minf(vy, 0.0)


func _step_height(g: float, hop: bool, dt: float, heights: Heightfield) -> void:
	_hop_wait = maxf(0.0, _hop_wait - dt)
	# На коротком естественном отрыве ранний Space не должен ждать далёкую посадку.
	var accept_hop := hop and (not airborne or _coyote > 0.0 or (vy < 0.0 and y - g < 0.2))
	_hop_buf = HOP_BUFFER if accept_hop else maxf(0.0, _hop_buf - dt)
	_coyote = maxf(0.0, _coyote - dt) if airborne else HOP_COYOTE
	if contact_model:
		# На земле пробел запускает тот же Q→E телом.
		if _hop_buf > 0.0 and _hop_wait <= 0.0 and not airborne and _auto_hop < 0.0:
			_hop_buf = 0.0
			_auto_hop = 0.0
		elif _hop_buf > 0.0 and _coyote > 0.0 and _auto_hop < 0.0 and not _hop_used:
			# Малый запас после кромки: игрок нажал вовремя, хотя колёса уже потеряли опору.
			_hop_buf = 0.0
			_hop_front = HOP_FRONT * 0.5
			_hop_front_v = 0.0
			_takeoff_hop()
	elif _hop_buf > 0.0 and _hop_wait <= 0.0 and (not airborne or _coyote > 0.0):
		_hop_buf = 0.0
		_coyote = 0.0
		airborne = true
		air_time = 0.0
		# Наследуем подъём, но крутой излом не превращается в катапульту.
		vy = clampf(vy, 0.0, HOP_CARRY) + GameConfig.BIKE_HOP
		squash_fv -= HOP_PRELOAD
		squash_rv -= HOP_PRELOAD
	if airborne:
		air_time += dt
		y += (vy - GameConfig.GRAVITY * dt * 0.5) * dt
		vy -= GameConfig.GRAVITY * dt
		if y <= g:
			_land(g, heights)
	else:
		var fly := y + (vy - GameConfig.GRAVITY * dt * 0.5) * dt
		# Земля уходит вниз быстрее падения: отрываемся с края сразу, с излома — только если
		# впереди рельеф действительно уходит из-под колёс; иначе прижимаемся к земле.
		if fly > g and (fly - g > DROP_STEP or _lifts(heights)):
			airborne = true
			air_time = dt
			vy -= GameConfig.GRAVITY * dt
			y = fly
		else:
			var gv := (g - y) / maxf(dt, 0.0001)
			# ступенька (въезд на настил, шов полотна) — не склон: её подъём не становится скоростью взлёта
			# При 120 Гц шов даёт вдвое больший скачок (g-y)/dt, чем при 60 Гц.
			# Ограничиваем подъём уклоном на базе колёс, сохраняя импульс настоящего склона.
			var gradient := Vector2(
				(heights.surface_at(x + HUB, z, g) - heights.surface_at(x - HUB, z, g)) / (2.0 * HUB),
				(heights.surface_at(x, z + HUB, g) - heights.surface_at(x, z - HUB, g)) / (2.0 * HUB))
			gv = minf(gv, maxf(0.0, gradient.dot(horizontal_velocity())))
			vy = gv
			y = g


## Колёса на точках касания. Подвеска колеса получает толчок, когда вертикальная скорость земли
## под ним меняется (излом, ступенька, кочка): переднее колесо встречает излом раньше заднего.
## 11.5: на полотне кочки — поле RoadBump в точке касания (то же, что видно в шейдере), вне пути — прежние.
## 11.6: поверх — кочки веток и камней на полотне (ForestObstacles.bump_at).
## 12.3: across — поперечная координата полотна у середины велосипеда (колеи RoadBump); колёса идут
## вдоль курса, поперёк они почти не расходятся.
func _step_wheels(heights: Heightfield, rough: float, dt: float, surf := RoadSurface.NONE, path_weight := 0.0, grade := 0.0, across := 0.0) -> void:
	if airborne:
		# в полёте колёса висят на подвеске под рамой
		ground_f = sin(tilt) * HUB
		ground_r = -ground_f
		_fresh = true
		return
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	var gf := _wheel_ground(x + fx, z + fz, heights)
	var gr := _wheel_ground(x - fx, z - fz, heights)
	if contact_model and heights.obstacles != null:
		var clear_f := lift_f > 0.0 and gf <= heights.surface_at(x + fx, z + fz, y) + lift_f + 0.01
		var clear_r := lift_r > 0.0 and gr <= heights.surface_at(x - fx, z - fz, y) + lift_r + 0.01
		var was_f := _on_f
		_on_f = _wheel_hit(heights, x + fx, z + fz, gf, _sup_f, _on_f, tire_f, true, clear_f)
		if crashed:
			return
		if lift_f > 0.0 and not clear_f and _on_f != was_f:
			lift_f = 0.0 # поднято ниже препятствия — колесо встретило кромку
			lift_fv = 0.0
		var was_r := _on_r
		_on_r = _wheel_hit(heights, x - fx, z - fz, gr, _sup_r, _on_r, tire_r, false, clear_r)
		if lift_r > 0.0 and not clear_r and _on_r != was_r:
			lift_r = 0.0
			lift_rv = 0.0
	_sup_f = gf
	_sup_r = gr
	# мелкие кочки (только вверх, колесо не тонет в земле): заднее колесо проходит ту же кочку на базу позже
	var wild := BUMP * rough * (1.0 - path_weight)
	# поле кочек в мировых метрах: у участка Trail Lab свой сдвиг (WorldData.world_origin), у мира ноль
	var o := Vector2(heights.world.world_origin) * GameConfig.TILE
	var bump_f := wild * _bump(_dist + HUB) + RoadBump.height(x + fx + o.x, z + fz + o.y, surf, grade, across) * path_weight
	var bump_r := wild * _bump(_dist - HUB) + RoadBump.height(x - fx + o.x, z - fz + o.y, surf, grade, across) * path_weight
	# 11.6: ветки и камни на полотне (RoadObstacles) — та же кочка, только с места препятствия
	var of := 0.0
	var orr := 0.0
	if heights.obstacles != null:
		of = heights.obstacles.bump_at(x + fx, z + fz)
		orr = heights.obstacles.bump_at(x - fx, z - fz)
	bump_f += of
	bump_r += orr
	# Поднятое колесо касается кочки, только если она выше подъёма: удар, сопротивление, скользкость
	# и толчок подвески — от той части кочки, что выше колеса. Колесо видно на подъёме или на кочке.
	var touch_f := lift_f <= 0.0 or bump_f > lift_f
	var touch_r := lift_r <= 0.0 or bump_r > lift_r
	# (колея RoadBump бывает ниже нуля: колесо на земле повторяет её, как прежде)
	var feel_f := bump_f if lift_f <= 0.0 else maxf(0.0, bump_f - lift_f)
	var feel_r := bump_r if lift_r <= 0.0 else maxf(0.0, bump_r - lift_r)
	ground_f = gf + lift_f + feel_f - y
	ground_r = gr + lift_r + feel_r - y
	gf += feel_f
	gr += feel_r
	# колесо на корне или камне скользкое: держит хуже, тормоз и поворот на нём — риск
	slick_f = ROOT_GRIP if contact_model and touch_f and of > SLICK_BUMP else 1.0
	slick_r = ROOT_GRIP if contact_model and touch_r and orr > SLICK_BUMP else 1.0
	if _fresh:
		_fresh = false
		_g_f = gf
		_g_r = gr
		_gv_f = vy
		_gv_r = vy
		_o_f = of
		_o_r = orr
		return
	# Колесо, которое взбирается на корень или камень, тормозит велосипед: энергию подъёма забирает
	# подвеска (как демпфер, ∝ скорости подъёма²). Раньше кочки только качали подвеску, ход не терялся.
	var rise_f := maxf(0.0, of - _o_f) / maxf(dt, 0.0001) if touch_f else 0.0
	var rise_r := maxf(0.0, orr - _o_r) / maxf(dt, 0.0001) if touch_r else 0.0
	_o_f = of
	_o_r = orr
	if rise_f + rise_r > 0.0:
		speed = signf(speed) * sqrt(maxf(0.0, speed * speed - 2.0 * BUMP_DRAG * (rise_f * rise_f + rise_r * rise_r) * dt))
	var vf := (gf - _g_f) / maxf(dt, 0.0001)
	var vr := (gr - _g_r) / maxf(dt, 0.0001)
	# колесо поднимается вместе с землёй сразу, рама — через пружину: разница и есть сжатие
	squash_fv += clampf(vf - _gv_f, -KICK_MAX, KICK_MAX)
	squash_rv += clampf(vr - _gv_r, -KICK_MAX, KICK_MAX)
	_g_f = gf
	_g_r = gr
	_gv_f = vf
	_gv_r = vr


## Колесо и препятствие: в такт, когда колесо встало на новое препятствие (другой id — и соседний камень без
## промежутка), удар о кромку отнимает у колеса скорость, с которой оно шло на препятствие (проекция скорости на
## направление к нему: косой заход бьёт слабее и сдвигает вдоль бревна), 1 − cos(угла встречи) — угол дуги колеса над
## кромкой в точке касания (ForestObstacles.wheel_contact) от высоты, на которой колесо ехало, за вычетом уклона
## земли. Раму тормозит на долю массы этого колеса (нагрузка шины). Угол — из геометрии, не из шага движения: не
## зависит от скорости и частоты тактов. Переднее колесо, потерявшее вдоль рамы больше ENDO_DV (лёгкое — меньше),
## бросает седока через руль. Возвращает id препятствия под колесом (-1 — на земле).
func _wheel_hit(heights: Heightfield, px: float, pz: float, support: float, before: float, on_id: int, load: float, front: bool, clear := false) -> int:
	var ground := heights.surface_at(px, pz, y)
	if support <= ground + 0.005:
		return -1
	var hit := heights.obstacles.wheel_contact(px, pz, WHEEL_R, ForestObstacles.CLIMB_MAX, minf(before, support) if on_id >= 0 else ground)
	if hit.is_empty():
		return -1
	if hit.id == on_id or _fresh or clear:
		return hit.id # то же препятствие, колесо опустилось на него сверху (приземление) или прошло над ним поднятым
	var angle: float = hit.angle - atan(maxf(0.0, _ground_slope(heights) * signf(speed)))
	if angle < IMPACT_ANGLE:
		return hit.id
	if front: impacts.x += 1
	else: impacts.y += 1
	var velocity := horizontal_velocity()
	var into: Vector2 = -hit.normal if hit.normal != Vector2.ZERO else velocity.normalized()
	var approach := maxf(0.0, velocity.dot(into))
	var share := clampf(load, 0.05, 1.0)
	var strike := into * approach * (1.0 - cos(minf(angle, PI * 0.5))) * share
	# 30.10: подвеска колеса принимает подъём на кромку своим оставшимся ходом — раму тормозит только часть удара,
	# которую ход не вместил. Раньше колесо било как жёсткое: потеря рамы росла со скоростью без предела, и бревно
	# 22 см на №17 бросало через руль с 13,5 м/с накатом.
	# Ход вмещает невысокую кромку почти целиком; у кромки выше хода его доля быстро падает (бревно 40 см на скорости
	# по-прежнему бросает через руль). Подвеска ходит в плоскости рамы: снос вдоль косого бревна она не гасит.
	var travel := clampf(SAG_MAX - (squash_f if front else squash_r), 0.0, SAG_MAX + STRETCH_MAX)
	var soak := EDGE_SOAK * pow(minf(1.0, travel / maxf(float(hit.get("rise", 0.0)), 0.02)), 1.5)
	var forward := Vector2(-sin(heading), -cos(heading))
	var side := Vector2(-forward.y, forward.x)
	var dv := strike - forward * strike.dot(forward) * soak
	# Диагностика последней встречи с кромкой (стенды): что именно ударило и насколько близко к порогу
	last_hit = {front = front, angle = angle, approach = approach, share = share, dv = dv.length(), soak = soak, rise = hit.get("rise", 0.0),
		endo = dv.dot(forward) / 0.5 / ENDO_DV, ground = ground, support = support, vy = vy, lift = lift_f if front else lift_r}
	if front and dv.dot(forward) / 0.5 > ENDO_DV:
		_crash(vy, Vector3(-sin(heading), 0.6, -cos(heading)), CrashCause.OBSTACLE)
		return hit.id
	# импульс вычитается из вектора скорости (и при заднем ходе), но не разворачивает движение через препятствие
	var after := velocity - dv
	if after.dot(into) < 0.0: after -= into * after.dot(into)
	speed = after.dot(forward)
	lateral_speed = after.dot(side)
	# принятая ходом часть удара сжимает подвеску сильнее: быстрый наезд на кромку бьёт вилку в упор (стук пробоя)
	var kick := strike.length() / share * (0.3 + 0.4 * soak)
	if front: hit_dv.x = dv.length()
	else: hit_dv.y = dv.length()
	# событие удара колеса — отдельно от приземления и пробоя: у переднего и заднего своя реакция
	if front: wheel_impact.x = maxf(wheel_impact.x, strike.length() / share)
	else: wheel_impact.y = maxf(wheel_impact.y, strike.length() / share)
	if front:
		squash_fv += kick
	else:
		squash_rv += kick
	return hit.id


## Кочка под колесом на отметке пути d, 0..1
static func _bump(d: float) -> float:
	var n := sin(d * 2.3) * 0.6 + sin(d * 5.9 + 1.3) * 0.4
	return maxf(0.0, n) ** 2


## Две пружины-демпфера, вилка и задний ход. Короткие подшаги не дают раскачки от длинного такта.
## load — сжатие от поворота, acceleration — продольная сила в пятнах контакта (тяга минус тормоз), м/с²: перенос
## нагрузки между осями. Не итоговое изменение скорости: тормоз, держащий скорость на спуске, всё так же сжимает
## вилку, а потеря хода в подъём без тормоза её не сжимает (тяжесть приложена к центру масс, не к колёсам).
func _step_suspension(dt: float, load := 0.0, acceleration := 0.0) -> void:
	var target := -0.035 if airborne else load
	var shift := 0.0 if airborne else acceleration * PITCH_LOAD
	var ticks := maxi(1, ceili(dt * SUB_HZ))
	var h := dt / ticks
	var f := Vector2(squash_f, squash_fv)
	var r := Vector2(squash_r, squash_rv)
	for i in ticks:
		var hit := f.y
		f = _spring(f, target - shift, h)
		if f.x >= SAG_MAX and hit > BOTTOM_OUT:
			bottom_out = maxf(bottom_out, hit)
		r = _spring(r, target + shift, h)
	_rest_f = target - shift
	_rest_r = target + shift
	squash_f = f.x
	squash_fv = f.y
	squash_r = r.x
	squash_rv = r.y
	squash = (squash_f + squash_r) * 0.5


## Подшаг одной пружины: s — ход и скорость сжатия; упоры на SAG_MAX и STRETCH_MAX
static func _spring(s: Vector2, target: float, h: float) -> Vector2:
	s.y += (SPRING_K * (target - s.x) - SPRING_DAMP * s.y) * h
	s.x += s.y * h
	if s.x > SAG_MAX:
		s = Vector2(SAG_MAX, minf(s.y, 0.0))
	elif s.x < -STRETCH_MAX:
		s = Vector2(-STRETCH_MAX, maxf(s.y, 0.0))
	return s


## Нагрузка колёс после подвески (модель двух контактов): вес по нормали с кривизной профиля (vertical_g),
## перенос между осями от тормоза, уклона и корпуса (Brakes.front_load) и сила пружины сверх равновесия —
## удар о корень прижимает колесо, отскок разгружает. В полёте нагрузки нет.
func _step_contacts(grade: float, dt: float) -> void:
	# E завершает движение даже если Q ещё не успели отпустить.
	var target := -1.0 if body_forward else (1.0 if body_back else 0.0)
	if _auto_hop >= 0.0:
		_auto_hop += dt
		target = AUTO_STRENGTH if _auto_hop < AUTO_BACK else (-AUTO_STRENGTH if _auto_hop < AUTO_BACK + AUTO_FORWARD else 0.0)
		if _auto_hop > AUTO_BACK + AUTO_FORWARD + 0.2: _auto_hop = -1.0
	body_v = clampf(body_v + (BODY_K * (target - body_x) - BODY_D * body_v) * dt, -BODY_RATE, BODY_RATE)
	body_x += body_v * dt
	if absf(body_x) > 1.0:
		body_x = signf(body_x)
		body_v = 0.0
	unweight = (BODY_HOLD * body_x + BODY_PUSH * body_v) if contact_model else 0.0
	_hop_link = maxf(0.0, _hop_link - dt)
	if absf(body_x) < 0.2 and absf(body_v) < 0.8 and is_zero_approx(target):
		_hop_used = false
	if contact_model and not _hop_used:
		if not airborne and lift_f >= HOP_ARM_HEIGHT and target > 0.0:
			if _hop_link <= 0.0:
				_hop_front = 0.0
				_hop_front_v = 0.0
			_hop_link = HOP_LINK
			_hop_front = maxf(_hop_front, lift_f)
			_hop_front_v = maxf(_hop_front_v, lift_fv)
		# Сохраняем подготовку на коротком отрыве у гребня. В затяжном полёте второго прыжка нет.
		# 30.10: на волне E после Q, когда переднее уже опустилось на обратный склон, — продавливание пампа, а не
		# подтягивание заднего: прыжок с волны — только пока переднее ещё в воздухе.
		var pressing := not airborne and lift_f <= 0.0 and pump_active > 0.15
		if target < 0.0 and body_v < -1.2 and _hop_link > 0.0 and (not airborne or _coyote > 0.0) and not pressing:
			_takeoff_hop()
	if airborne:
		pump_accel = 0.0
		pump_load = 0.0
		_pump_reach = 0.0
		_pump_absorb_v = 0.0
		load_f = 0.0
		load_r = 0.0
		tire_f = 0.0
		tire_r = 0.0
		side_f = 0.0
		side_r = 0.0
		lift_f = 0.0
		lift_fv = 0.0
		lift_r = 0.0
		lift_rv = 0.0
		if _hop_used: hop_height = maxf(hop_height, y - _hop_from)
		return
	# Вираж прижимает: в повороте по наклонному полотну часть центростремительного ускорения давит в склон,
	# a·sinθ (контруклон — наоборот, разгружает). Тяжесть вдоль склона учтена в _step_turn и _step_traction.
	var bank := clampf(bank_slope * signf(_yaw_rate), -BANK_SLOPE_MAX, BANK_SLOPE_MAX)
	var press := absf(speed * _yaw_rate) / GameConfig.GRAVITY * bank / sqrt(1.0 + bank * bank)
	var normal := maxf(0.0, 1.0 / sqrt(1.0 + grade * grade) + vertical_g + press + pump_load)
	# Перенос нагрузки между осями идёт через наклон рамы и ход вилки, а не мгновенно: доля переднего следует
	# за распределением тормоза с PITCH_TRANSFER. Пока колесо поднято, вся нагрузка на другом — вернувшееся
	# колесо принимает её постепенно, и тормоз не проваливается, пока шина набирает силу.
	var share_goal := 0.0 if lift_f > 0.0 else (1.0 if lift_r > 0.0 else clampf(brakes.front_load, 0.0, 1.0))
	_share = lerpf(_share, share_goal, 1.0 - exp(-dt / PITCH_TRANSFER)) if contact_model else share_goal
	var share := _share
	var spring_f := (SPRING_K * (squash_f - _rest_f) + SPRING_DAMP * CONTACT_DAMP * squash_fv) / GameConfig.GRAVITY
	var spring_r := (SPRING_K * (squash_r - _rest_r) + SPRING_DAMP * CONTACT_DAMP * squash_rv) / GameConfig.GRAVITY
	var raw_f := clampf(share * normal + CONTACT_SPRING * spring_f, 0.0, LOAD_MAX)
	var raw_r := clampf((1.0 - share) * normal + CONTACT_SPRING * spring_r, 0.0, LOAD_MAX)
	if contact_model:
		# Седок компенсирует перенос веса, готовя рывок: одинаковый Q/E работает и вверх, и вниз.
		# Это помощь только подъёму; настоящие нагрузки тормоза и шин остаются выше.
		_step_lift(normal * 0.5, normal * 0.5, unweight * normal, dt)
		if airborne:
			return
	if lift_f > 0.0:
		raw_r = minf(raw_r + raw_f, LOAD_MAX)
		raw_f = 0.0
	elif lift_r > 0.0:
		raw_f = minf(raw_f + raw_r, LOAD_MAX)
		raw_r = 0.0
	else:
		# седок переносит вес: сколько снято с одного колеса, столько легло на другое
		var moved := clampf(unweight * normal, -raw_r, raw_f)
		raw_f = minf(raw_f - moved, LOAD_MAX)
		raw_r = minf(raw_r + moved, LOAD_MAX)
	var kc := 1.0 - exp(-dt / TIRE_COMPLY)
	load_f = lerpf(load_f, raw_f, kc)
	load_r = lerpf(load_r, raw_r, kc)
	var k := 1.0 - exp(-dt / maxf(TIRE_RELAX_MIN, TIRE_RELAX / maxf(absf(speed), 0.5)))
	# сила шины набирается по пути, но не больше того, что колесо сейчас несёт: разгруженное колесо силы не даёт
	tire_f = minf(lerpf(tire_f, load_f, k), load_f)
	tire_r = minf(lerpf(tire_r, load_r, k), load_r)
	var ks := 1.0 - exp(-dt / SIDE_RELAX)
	side_f = minf(lerpf(side_f, tire_f, ks), tire_f)
	side_r = minf(lerpf(side_r, tire_r, ks), tire_r)


## Подъём колёс рывком тела: pull — доля веса, которую тело снимает с переднего колеса (меньше нуля — с заднего),
## weight_f / weight_r — веса, которые колёса несут. Сверх веса колесо идёт вверх, иначе опускается обратно.
## Последовательность Q→E собирается в _step_contacts; сам подъём одного колеса не запускает прыжок.
func _step_lift(weight_f: float, weight_r: float, pull: float, dt: float) -> void:
	var g := GameConfig.GRAVITY
	# 30.10: на подъёме волны и на гребне Q — поглощение: руки сгибаются навстречу земле, переднее не отрывается (памп,
	# а не подготовка прыжка). На обратном склоне и ровном Q поднимает переднее, как прежде; пробел (авто Q→E) — всегда.
	if _auto_hop < 0.0 and pull > 0.0:
		pull *= 1.0 - minf(1.0, pump_active * 2.0) * smoothstep(-PUMP_WAVE_PRESS * 0.5, PUMP_WAVE_PRESS * 0.5, pump_wave)
	# рывок поднимает колесо, пока сильнее его веса; дальше оно летит и падает обратно с ускорением свободного падения
	if pull > weight_f: lift_fv = minf(LIFT_RATE_F, lift_fv + (pull - weight_f) * g * LIFT_GAIN_F * dt)
	elif lift_f > 0.0: lift_fv -= g * dt
	# на волне рывок вперёд при опущенном переднем продавливает велосипед (памп), а не отрывает заднее
	var rear_gain := LIFT_GAIN_R * (1.0 - minf(1.0, pump_active * 2.0) if lift_f <= 0.0 else 1.0)
	if -pull > weight_r and rear_gain > 0.0: lift_rv += (-pull - weight_r) * g * rear_gain * dt
	elif lift_r > 0.0: lift_rv -= g * dt
	lift_f += lift_fv * dt
	lift_r += lift_rv * dt
	if lift_f <= 0.0:
		if lift_fv < -0.5: squash_fv += -lift_fv * 0.4 # колесо опустилось — подвеска принимает
		lift_f = 0.0
		lift_fv = maxf(lift_fv, 0.0) if pull > weight_f else 0.0
	if lift_r <= 0.0:
		if lift_rv < -0.5: squash_rv += -lift_rv * 0.4
		lift_r = 0.0
		lift_rv = maxf(lift_rv, 0.0) if -pull > weight_r else 0.0
	# На скорости в дуге седок ограничивает ручной подъём, сохраняя запас для Q→E.
	var turning := smoothstep(0.15, 0.45, absf(steer)) * smoothstep(6.0, 12.0, absf(speed))
	var front_limit := lerpf(LIFT_MAX, LIFT_TURN_MAX, turning)
	if lift_f >= front_limit:
		lift_f = front_limit
		lift_fv = minf(lift_fv, 0.0)
	if lift_r >= LIFT_MAX:
		lift_r = LIFT_MAX
		lift_rv = minf(lift_rv, 0.0)


## Q поднял переднее, E подтягивает заднее. Высота зависит от подготовки, окно не требует точности до кадра.
func _takeoff_hop() -> void:
	airborne = true
	air_time = 0.0
	_coyote = 0.0
	_hop_from = y
	hop_height = 0.0
	var quality := clampf(_hop_front / HOP_FRONT, 0.0, 1.0)
	y += minf((lift_f + lift_r) * 0.5, 0.12 if vy > 0.5 else LIFT_MAX)
	# Сохраняем движение вдоль спуска: прыжок считается относительно полотна, без катапульты вниз по склону.
	var carry := lerpf(HOP_CARRY, HOP_CARRY * 0.5, smoothstep(0.1, 0.5, absf(vertical_g)))
	vy = minf(vy, carry) + HOP_POP * lerpf(0.8, 1.0, quality) + maxf(0.0, _hop_front_v) * 0.35
	lift_f = 0.0
	lift_fv = 0.0
	lift_r = 0.0
	lift_rv = 0.0
	_hop_link = 0.0
	_hop_used = true


## Колесо держит: стоит на земле и нагружено
func contact_f() -> bool:
	return not airborne and lift_f <= 0.0 and load_f > CONTACT_MIN


func contact_r() -> bool:
	return not airborne and lift_r <= 0.0 and load_r > CONTACT_MIN


## Продольное движение: тяга педалей, склон, качение и сопротивление на скорости.
## speed — скорость по горизонтали, поэтому проекция тяжести — slope / (1 + slope²).
## terrain — доля крейсерской скорости (цель педалей), roll_terrain — лёгкость качения (меньше нуля — та же terrain).
## Сила ног — от усилия седока (effort), а не прямо от ввода: тяга нарастает вместе с позой.
func _step_speed(throttle: float, boost: bool, slope: float, terrain: float, dt: float, grip := 1.0, technical := 0.0, roll_terrain := -1.0) -> void:
	if dt > 1.0 / SUB_HZ + 0.000001:
		var ticks := ceili(dt * SUB_HZ)
		for i in ticks:
			_step_speed(throttle, boost, slope, terrain, dt / ticks, grip, technical, roll_terrain)
		return
	_step_effort(maxf(throttle, 0.0), dt)
	var top := GameConfig.BIKE_SPEED * terrain
	var rolling := GameConfig.BIKE_ROLL / maxf(terrain if roll_terrain < 0.0 else roll_terrain, 0.25)
	# Воздух не становится плотнее над камнями или травой; покрытие влияет на качение.
	var drag := GameConfig.BIKE_DRAG
	var gravity := -SLOPE_GRAVITY * slope / (1.0 + slope * slope) + pump_accel
	var loads := Vector2(tire_f * slick_f if contact_f() else 0.0, tire_r * slick_r if contact_r() else 0.0)
	brakes.step(dt, maxf(0.0, -throttle), speed, slope, grip, _corner_demand, true, loads if contact_model else Vector2(-1.0, -1.0))
	braking = 0.0
	# Пауза заднего хода отсчитывается у остановки, а не во время торможения с разгона. Тормоз, зажатый на ходу,
	# так и заканчивается стоянкой: задний ход — повторным нажатием (отпустить и снова держать).
	if throttle > -GameConfig.BIKE_REVERSE_INPUT:
		_reverse_armed = true
	elif speed > 0.05:
		_reverse_armed = false
	if throttle <= -GameConfig.BIKE_REVERSE_INPUT and absf(speed) < 0.05 and _reverse_armed:
		_brake_hold += dt
	elif throttle > -GameConfig.BIKE_REVERSE_INPUT or speed > 0.05:
		_brake_hold = 0.0
	var reversing := throttle < 0.0 and (speed < -0.05 or _brake_hold >= REVERSE_HOLD)
	if reversing:
		# Медленный манёвр назад остаётся предсказуемым и на склоне.
		speed = move_toward(speed, -GameConfig.BIKE_REVERSE * absf(throttle), GameConfig.BIKE_ACCEL * dt)
		brakes.limit(0.0)
		return
	# Автобаланс и статический тормоз: не сползаем, пока игрок обдумывает задний ход.
	if throttle < 0.0 and absf(speed) < 0.05:
		speed = 0.0
		brakes.limit(0.0)
		return
	if speed < 0.0:
		var stop := GameConfig.BIKE_ACCEL if throttle > 0.0 else rolling + drag * speed * speed
		speed = move_toward(speed, 0.0, stop * dt)
		return
	var drive := 0.0
	var request := 0.0
	if throttle > 0.0:
		top *= (GameConfig.BIKE_BOOST if boost else 1.0) * throttle
		var ratio := maxf(speed, 0.0) / maxf(top, 0.1)
		# Уверенный старт и плавное ослабление тяги; скорость спуска не срезается до top.
		var push := GameConfig.BIKE_ACCEL * 1.75
		var taper := maxf(0.1, push / (rolling + drag * top * top) - 1.0)
		drive = push / (1.0 + taper * ratio * ratio) * effort
		# Shift помогает дожать крутой подъём на малой скорости, без переключения передач.
		if boost:
			drive += 1.5 * smoothstep(0.08, 0.35, slope) * (1.0 - smoothstep(3.0, 9.0, speed)) * effort * grip
		request = drive
		if contact_model:
			drive = _rear_drive(drive, grip)
	# Кочки съедают ход только при быстром проезде. На длинном спуске воздух мягко
	# сдерживает разгон выше 18 м/с, не обрезая накопленную скорость на пороге.
	var rough_loss_now := SPEED_LOSS * speed * speed + technical * 0.8 + 0.04 * pow(maxf(speed - 18.0, 0.0), 2.0)
	var resistance := rolling + AIR_DRAG * speed * speed + rough_loss_now
	_sub[T_DRIVE_REQUEST] = request
	_sub[T_DRIVE] = drive
	_sub[T_ROLL] = rolling
	_sub[T_AIR] = AIR_DRAG * speed * speed
	_sub[T_ROUGH] = rough_loss_now
	_sub[T_SLOPE] = gravity - pump_accel
	_sub[T_PUMP] = pump_accel
	if brake_pressure > 0.001:
		var force := brakes.deceleration
		var before_brake := maxf(0.0, speed + (drive + gravity) * dt)
		speed = move_toward(before_brake, 0.0, (force + resistance) * dt)
		brakes.limit(minf(force, maxf(0.0, before_brake / dt - resistance)))
		braking = clampf(brake_deceleration / GameConfig.BIKE_BRAKE, 0.0, 1.0) * smoothstep(0.3, 3.0, before_brake)
		_sub[T_BRAKE_F] = brakes.front_force
		_sub[T_BRAKE_R] = brakes.rear_force
	else:
		speed += (drive + gravity) * dt
		speed = move_toward(speed, 0.0, resistance * dt)
		# Не заставляем новичка балансировать и ловить самопроизвольный откат в подъём.
		speed = maxf(0.0, speed)


## Реализованная тяга педалей (модель двух контактов): только через заднее колесо на земле и в пределах его запаса
## сцепления, оставшегося после боковой силы (она с прошлого подшага: _step_traction идёт после скорости).
## Помощь старта явная: до START_PACE седок толкается в полную силу педалей и на рыхлом или корнях.
func _rear_drive(wanted: float, grip: float) -> float:
	if wanted <= 0.0 or not contact_r():
		return 0.0
	var cap := CORNER_GRIP * RIDER_GRIP * grip * tire_r * slick_r
	var free := sqrt(maxf(0.0, cap * cap - force_r.y * force_r.y))
	var start := wanted * (1.0 - smoothstep(START_PACE * 0.5, START_PACE, speed))
	return minf(wanted, maxf(free, start))


## Седок падает: запомнить, с какой скоростью летел велосипед
## Первое событие падения в подшаге главное: следующие не переписывают причину, нормаль и скорость удара.
func _crash(v_up: float, normal := Vector3.UP, cause := CrashCause.FALL) -> void:
	if crashed:
		return
	crash_info = {speed = speed, lateral_speed = lateral_speed, vy = v_up, load_f = load_f, load_r = load_r, unweight = unweight}
	crashed = true
	crash_cause = cause
	crash_normal = normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP
	var velocity := horizontal_velocity()
	crash_velocity = Vector3(velocity.x, v_up, velocity.y)


## Нормаль препятствия леса (ствол, валун, бревно), которое задевает один из трёх кругов велосипеда
## с серединой в (px, pz) и курсом hd; ноль, если не задевает
func obstacle_normal(px: float, pz: float, hd: float, heights: Heightfield) -> Vector2:
	for side: float in [1.0, 0.0, -1.0]:
		var n := heights.obstacles.normal(px - sin(hd) * AXLE * side, pz - cos(hd) * AXLE * side, y, BODY_R, _climb())
		if n != Vector2.ZERO:
			return n
	return Vector2.ZERO


## Помещается ли велосипед серединой в (px, pz) с курсом hd: все три круга вдоль рамы свободны
func fits(px: float, pz: float, hd: float, w: WorldData, heights: Heightfield) -> bool:
	var fx := -sin(hd) * AXLE
	var fz := -cos(hd) * AXLE
	var climb := _climb()
	return (PlayerState.is_passable(w, heights, px, pz, y, BODY_R, false, climb)
		and PlayerState.is_passable(w, heights, px + fx, pz + fz, y, BODY_R, false, climb)
		and PlayerState.is_passable(w, heights, px - fx, pz - fz, y, BODY_R, false, climb)
		and _roof_over(px, pz, hd, y, heights) >= y + BikeRecovery.CLEARANCE)


## Самое низкое перекрытие над рамой (середина и оси) для ног на высоте feet: свод туннеля или низ моста.
## Габарит седока — BikeRecovery.CLEARANCE, тот же, что при посадке и восстановлении.
func _roof_over(px: float, pz: float, hd: float, feet: float, heights: Heightfield) -> float:
	var fx := -sin(hd) * AXLE
	var fz := -cos(hd) * AXLE
	return minf(BikeRecovery.roof(heights, px, pz, feet),
		minf(BikeRecovery.roof(heights, px + fx, pz + fz, feet), BikeRecovery.roof(heights, px - fx, pz - fz, feet)))


## Доля скорости, которая остаётся после касания стены: moved — путь, который всё же прошли, full — весь путь за кадр
func _slide_keep(dt: float, moved: float, full: float) -> float:
	if full <= 0.0:
		return 1.0
	return 1.0 - minf(1.0, dt * WALL_LOSS * (1.0 - moved / full))


## Приземление: подвеска проседает тем сильнее, чем жёстче удар; жёсткий удар гасит скорость,
## а слишком жёсткий (с высоты больше 5 м на ровное) сбрасывает седока
func _land(g: float, heights: Heightfield) -> void:
	# Нормаль — от той же опоры, что и высота g: вдоль рамы по опорам колёс (бревно, камень, настил),
	# поперёк по земле. Вектор в мировых X/Z: боком к склону важна траектория, а не курс рамы.
	var forward := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(-forward.y, forward.x)
	var gradient := forward * _slope(heights) + right * (heights.surface_at(x + right.x * HUB, z + right.y * HUB, g)
		- heights.surface_at(x - right.x * HUB, z - right.y * HUB, g)) / (2.0 * HUB)
	var normal := Vector3(-gradient.x, 1.0, -gradient.y).normalized()
	var horizontal := horizontal_velocity()
	var incoming := Vector3(horizontal.x, vy, horizontal.y)
	var impact := maxf(0.0, -incoming.dot(normal))
	var approach_grade := gradient.dot(horizontal.normalized()) if horizontal.length_squared() > 0.0001 else 0.0
	landing_info = {air = air_time, impact = impact, speed = speed, vy = vy, hop = _hop_used, hop_height = hop_height if _hop_used else 0.0}
	airborne = false
	y = g
	# Седок автоматически принимает умеренную посадку ногами. Сильный удар
	# проверяется по исходной скорости: помощь не спасает от опасного недолёта.
	var absorbed := minf(1.2, impact * 0.18) * (1.0 - smoothstep(9.0, 13.0, impact))
	var felt := impact - absorbed
	land_impact = maxf(land_impact, felt)
	squash_fv = clampf(squash_fv + felt * LANDING_KICK, SQUASH_V_MIN, SQUASH_V_MAX)
	squash_rv = clampf(squash_rv + felt * LANDING_KICK, SQUASH_V_MIN, SQUASH_V_MAX)
	# В подъём (нос в склон) удар опаснее, чем на ровное: порог падения ниже.
	if impact > GameConfig.BIKE_CRASH - FACE_CRASH * clampf(approach_grade, 0.0, 1.0):
		_crash(vy, normal)
		speed = 0.0
		lateral_speed = 0.0
	elif felt > SOFT_IMPACT:
		var keep := 1.0 - clampf((felt - SOFT_IMPACT) * 0.05, 0.0, 0.5)
		speed *= keep
		lateral_speed *= keep
	vy = gradient.dot(horizontal_velocity())
	_coyote = HOP_COYOTE
	# Короткие подскоки и заранее нажатый прыжок не блокируют управление.
	if air_time > HOP_WAIT_AIR:
		_hop_wait = 0.0 if _hop_buf > 0.0 else HOP_WAIT
	air_time = 0.0

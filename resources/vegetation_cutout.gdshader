// Кроны с вырезанными листьями. Код — vegetation.gdshaderinc.
// 9.4: крона не принимает тени — объём даёт эллипсоид нормалей (ForestModels), без чёрных провалов
// от собственных веток; на земле тень кроны остаётся. Заодно дешевле: листве не нужна выборка карты теней.
shader_type spatial;
render_mode cull_disabled, shadows_disabled;

#define CUTOUT
#include "res://resources/vegetation.gdshaderinc"

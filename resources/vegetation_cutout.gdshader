// Кроны с вырезанными листьями. Код — vegetation.gdshaderinc.
// Кроны принимают тени рельефа, зданий и других деревьев; объём поддерживают мягкие нормали и BACKLIGHT.
shader_type spatial;
render_mode cull_disabled;

#define CUTOUT
#include "res://resources/vegetation.gdshaderinc"

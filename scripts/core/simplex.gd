class_name Simplex
extends RefCounted
## Симплекс-шум 2D (Stefan Gustavson), перестановка зависит от сида. Копия js/core/simplex.js.
## Градиенты GX/GY из JS-версии (1,1) (-1,1) (1,-1) (-1,-1) (1,0) (-1,0) (0,1) (0,-1) развёрнуты в код:
## так быстрее (и без общих объектов между потоками), а результат тот же до бита.

var perm := PackedInt32Array()
var pm8 := PackedInt32Array()
var f2: float = 0.5 * (sqrt(3.0) - 1.0)
var g2: float = (3.0 - sqrt(3.0)) / 6.0


func _init(rng: WGRandom = null) -> void:
	if rng == null:
		return
	var p := PackedInt32Array()
	p.resize(256)
	for i: int in 256:
		p[i] = i
	for i: int in range(255, 0, -1):
		var j := floori(rng.next_float() * (i + 1))
		var t := p[i]
		p[i] = p[j]
		p[j] = t
	perm.resize(512)
	pm8.resize(512)
	for i: int in 512:
		perm[i] = p[i & 255]
		pm8[i] = perm[i] & 7


## Копия для другого потока (свои массивы — потоки не делят счётчики ссылок)
func clone() -> Simplex:
	var s := Simplex.new()
	s.perm = perm.duplicate()
	s.pm8 = pm8.duplicate()
	return s


func noise(xin: float, yin: float) -> float:
	var pm := perm
	var p8 := pm8
	var g2 := self.g2
	var s := (xin + yin) * f2
	var i := floori(xin + s)
	var j := floori(yin + s)
	var t := (i + j) * g2
	var x0 := xin - (i - t)
	var y0 := yin - (j - t)
	var i1 := 0
	var j1 := 1
	if x0 > y0:
		i1 = 1
		j1 = 0
	var x1 := x0 - i1 + g2
	var y1 := y0 - j1 + g2
	var x2 := x0 - 1.0 + 2.0 * g2
	var y2 := y0 - 1.0 + 2.0 * g2
	var ii := i & 255
	var jj := j & 255
	var n := 0.0
	var t0 := 0.5 - x0 * x0 - y0 * y0
	var g: int
	var d: float
	if t0 > 0.0:
		g = p8[ii + pm[jj]]
		if g < 4:
			d = (x0 if (g & 1) == 0 else -x0) + (y0 if g < 2 else -y0)
		elif g < 6:
			d = x0 if g == 4 else -x0
		else:
			d = y0 if g == 6 else -y0
		t0 *= t0
		n += t0 * t0 * d
	var t1 := 0.5 - x1 * x1 - y1 * y1
	if t1 > 0.0:
		g = p8[ii + i1 + pm[jj + j1]]
		if g < 4:
			d = (x1 if (g & 1) == 0 else -x1) + (y1 if g < 2 else -y1)
		elif g < 6:
			d = x1 if g == 4 else -x1
		else:
			d = y1 if g == 6 else -y1
		t1 *= t1
		n += t1 * t1 * d
	var t2 := 0.5 - x2 * x2 - y2 * y2
	if t2 > 0.0:
		g = p8[ii + 1 + pm[jj + 1]]
		if g < 4:
			d = (x2 if (g & 1) == 0 else -x2) + (y2 if g < 2 else -y2)
		elif g < 6:
			d = x2 if g == 4 else -x2
		else:
			d = y2 if g == 6 else -y2
		t2 *= t2
		n += t2 * t2 * d
	return 70.0 * n


## Фрактальный шум: сумма октав, результат примерно в [-1, 1]
func fbm(x: float, y: float, oct: int, lac: float = 2.0, gain: float = 0.5) -> float:
	var a := 1.0
	var f := 1.0
	var s := 0.0
	var n := 0.0
	for _o: int in oct:
		s += a * noise(x * f, y * f)
		n += a
		a *= gain
		f *= lac
	return s / n


## Гребневой шум для горных хребтов, примерно [0, 1]
func ridged(x: float, y: float, oct: int) -> float:
	var a := 0.5
	var f := 1.0
	var s := 0.0
	var w := 1.0
	for _o: int in oct:
		var v := 1.0 - absf(noise(x * f, y * f))
		v *= v
		v *= w
		w = minf(1.0, maxf(0.0, v * 2.0))
		s += v * a
		f *= 2.1
		a *= 0.5
	return s

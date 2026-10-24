class_name EntityCodec
extends RefCounted

static func encode(value: Variant) -> Variant:
	if value is EntityRecord:
		return value.to_dict()
	if value is Array:
		var out: Array = []
		for item: Variant in value:
			out.append(encode(item))
		return out
	if value is Dictionary:
		var out := {}
		for key: Variant in value:
			out[key] = encode(value[key])
		return out
	return value

## Compatibility at heterogeneous UI place/region boundaries.
static func value(record: Variant, key: String, fallback: Variant = null) -> Variant:
	if record is EntityRecord:
		return record.value(key, fallback)
	return record.get(key, fallback)

static func settlements(items: Array) -> Array[SettlementData]:
	var out: Array[SettlementData] = []
	for item: Variant in items:
		out.append(item if item is SettlementData else SettlementData.from_dict(item))
	return out

static func sites(items: Array) -> Array[SiteData]:
	var out: Array[SiteData] = []
	for item: Variant in items:
		out.append(item if item is SiteData else SiteData.from_dict(item))
	return out

static func lakes(items: Array) -> Array[LakeData]:
	var out: Array[LakeData] = []
	for item: Variant in items:
		out.append(item if item is LakeData else LakeData.from_dict(item))
	return out

static func bridges(items: Array) -> Array[BridgeData]:
	var out: Array[BridgeData] = []
	for item: Variant in items:
		out.append(item if item is BridgeData else BridgeData.from_dict(item))
	return out

static func tunnels(items: Array) -> Array[TunnelData]:
	var out: Array[TunnelData] = []
	for item: Variant in items:
		out.append(item if item is TunnelData else TunnelData.from_dict(item))
	return out

static func huts(items: Array) -> Array[HutData]:
	var out: Array[HutData] = []
	for item: Variant in items:
		out.append(item if item is HutData else HutData.from_dict(item))
	return out

## Unlike Array/Dictionary.duplicate(true), also copies RefCounted entity records.
static func copy(value: Variant) -> Variant:
	if value is EntityRecord:
		return value.duplicate()
	if value is Array:
		var out: Array = []
		for item: Variant in value:
			out.append(copy(item))
		return out
	if value is Dictionary:
		var out := {}
		for key: Variant in value:
			out[key] = copy(value[key])
		return out
	return value

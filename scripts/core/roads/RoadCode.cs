namespace Roads;

/// <summary>Версия кода дорожных вычислений на C# (RoadBed, RoadRefinement, подгонка профиля, формы коридора, покрытия).
/// Входит в ключ кэша поверхности (WorldCache.artifact_key) рядом с RoadBump.PATCH_VERSION. Поднимать при любой правке
/// этих вычислений, которая меняет результат (сами числа форм лежат в RoadRefinement.corridor_params и ключа не требуют:
/// при смене чисел поднимается SURFACE_VERSION, как и раньше).</summary>
public static class RoadCode
{
	public const int Version = 1;
}

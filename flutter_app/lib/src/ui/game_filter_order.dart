import '../rust/models.dart';

/// A stable partition: selecting a game does not reorder either group's
/// catalog order, and deselecting returns it to the unselected catalog group.
List<GameTagSummary> selectedGameTagsFirst(
  Iterable<GameTagSummary> games,
  Set<String> selected,
) {
  final checked = <GameTagSummary>[];
  final unchecked = <GameTagSummary>[];
  for (final game in games) {
    (selected.contains(game.name) ? checked : unchecked).add(game);
  }
  return [...checked, ...unchecked];
}

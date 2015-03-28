require 'coffee-cache'

expectMapsToSource = (layer, sourcePosition, position, clip) ->
  expect(layer.toSourcePosition(position, clip)).toEqual(sourcePosition)

expectMapsFromSource = (layer, sourcePosition, position, clip) ->
  expect(layer.fromSourcePosition(sourcePosition, clip)).toEqual(position)

expectMapsSymmetrically = (layer, sourcePosition, position) ->
  expectMapsToSource(layer, sourcePosition, position)
  expectMapsFromSource(layer, sourcePosition, position)

expectSet = (actualSet, expectedItems) ->
  expectedSet = new Set(expectedItems)

  expectedSet.forEach (item) ->
    unless actualSet.has(item)
      throw new Error("Expected set #{formatSet(actualSet)} to have item #{item}")

  actualSet.forEach (item) ->
    unless expectedSet.has(item)
      throw new Error("Expected set #{formatSet(actualSet)} not to have item #{item}")

setToArray = (set) ->
  items = []
  set.forEach (item) -> items.push(item)
  items

formatSet = (set) ->
  "(#{setToArray(set).join(' ')})"

module.exports = {expectMapsToSource, expectMapsFromSource, expectMapsSymmetrically, expectSet}

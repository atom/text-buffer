require 'coffee-cache'

expectMapsToSource = (layer, sourcePosition, position, clip) ->
  expect(layer.toSourcePosition(position, clip)).toEqual(sourcePosition)

expectMapsFromSource = (layer, sourcePosition, position, clip) ->
  expect(layer.fromSourcePosition(sourcePosition, clip)).toEqual(position)

expectMapsSymmetrically = (layer, sourcePosition, position) ->
  expectMapsToSource(layer, sourcePosition, position)
  expectMapsFromSource(layer, sourcePosition, position)

module.exports = {expectMapsToSource, expectMapsFromSource, expectMapsSymmetrically}

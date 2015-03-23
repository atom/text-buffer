require 'coffee-cache'

exports.expectMapsToSource = (layer, sourcePosition, position, clip) ->
  expect(layer.toSourcePosition(position, clip)).toEqual(sourcePosition)

exports.expectMapsFromSource = (layer, sourcePosition, position, clip) ->
  expect(layer.fromSourcePosition(sourcePosition, clip)).toEqual(position)

exports.expectMapsSymmetrically = (layer, sourcePosition, position) ->
  expectMapsToSource(layer, sourcePosition, position)
  expectMapsFromSource(layer, sourcePosition, position)

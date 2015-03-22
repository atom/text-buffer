require 'coffee-cache'

exports.expectMapsSymmetrically = (layer, sourcePosition, position) ->
  expect(layer.fromSourcePosition(sourcePosition)).toEqual(position)
  expect(layer.toSourcePosition(position)).toEqual(sourcePosition)

exports.expectMapsToSource = (layer, sourcePosition, position, clip) ->
  expect(layer.toSourcePosition(position, clip)).toEqual(sourcePosition)

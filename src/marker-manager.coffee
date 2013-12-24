{omit, defaults} = require 'underscore'
Marker = require './marker'
Range = require './range'

module.exports =
class MarkerManager
  nextMarkerId: 1

  constructor: (@textBuffer) ->
    @markers = {}

  markRange: (range, options) ->
    range = Range.fromObject(range, true).freeze()
    params = Marker.paramsFromOptions(options)
    params.id = @nextMarkerId++
    params.range = range
    marker = new Marker(params)
    @markers[marker.id] = marker
    @textBuffer.emit 'marker-created', marker
    marker

  markPosition: (position, options) ->
    @markRange([position, position], defaults({hasTail: false}, options))

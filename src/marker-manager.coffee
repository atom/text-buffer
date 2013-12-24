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

    marker = new Marker
      id: @nextMarkerId++
      range: range
      tailed: options?.hasTail ? true
      reversed: options?.isReversed ? false
      valid: true
      invalidate: options?.invalidate ? 'overlap'
      persistent: options?.persistent ? options?.persist ? true # The 'persist' key is deprecated
      state: omit(options, Marker.reservedKeys...)

    @markers[marker.id] = marker
    @textBuffer.emit 'marker-created', marker
    marker

  markPosition: (position, options) ->
    @markRange([position, position], defaults({hasTail: false}, options))

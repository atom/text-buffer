{omit, defaults, values} = require 'underscore'
Marker = require './marker'
Range = require './range'

module.exports =
class MarkerManager
  nextMarkerId: 1

  constructor: (@textBuffer) ->
    @markers = {}

  markRange: (range, params) ->
    range = Range.fromObject(range, true).freeze()
    params = Marker.extractParams(params)
    params.range = range
    @createMarker(params)

  markPosition: (position, options) ->
    @markRange([position, position], defaults({hasTail: false}, options))

  getMarker: (id) ->
    @markers[id]

  getMarkers: ->
    values(@markers)

  findMarkers: (params) ->
    markers = @getMarkers().filter (marker) -> marker.matchesParams(params)
    markers.sort (a, b) -> a.compare(b)

  createMarker: (params) ->
    params.manager = this
    params.id = @nextMarkerId++
    marker = new Marker(params)
    @markers[marker.id] = marker
    @textBuffer.emit 'marker-created', marker
    marker

  removeMarker: (id) ->
    delete @markers[id]

  recordMarkerPatch: (patch) ->
    if @textBuffer.isTransacting()
      @textBuffer.history.recordNewPatch(patch)

  handleBufferChange: (patch) ->
    marker.handleBufferChange(patch) for id, marker of @markers

  applyPatches: (markerPatches, bufferChanged) ->
    for id, patch of markerPatches
      @getMarker(id)?.applyPatch(patch, bufferChanged)

  pauseChangeEvents: ->
    marker.pauseEvents('changed') for marker in @getMarkers()

  resumeChangeEvents: ->
    marker.resumeEvents('changed') for marker in @getMarkers()

Serializable = require 'nostalgia'
Range = require './range'

module.exports =
class BufferPatch extends Serializable
  constructor: (@oldRange, @newRange, @oldText, @newText, @markerPatches={}) ->

  serializeParams: ->
    oldRange = @oldRange.serialize()
    newRange = @newRange.serialize()
    markerPatches = {}
    markerPatches[id] = patch.serialize() for id, patch in @markerPatches
    {oldRange, newRange, @oldText, @newText, markerPatches}

  deserializeParams: (params) ->
    params.oldRange = Range.deserialize(params.oldRange)
    params.newRange = Range.deserialize(params.newRange)
    for id, patchState in params.markerPatches
      params.markerPatches[id] = MarkerPatch.deserialize(patchState)
    params

  invert: (buffer) ->
    markerPatches = {}
    markerPatches[id] = patch.invert() for id, patch of @markerPatches
    invertedPatch = new @constructor(@newRange, @oldRange, @newText, @oldText, markerPatches)
    for marker in buffer.getMarkers()
      unless @markerPatches[marker.id]?
        marker.handleBufferChange(invertedPatch)
    invertedPatch

  applyTo: (buffer) ->
    buffer.applyPatch(this)

  addMarkerPatch: (patch) ->
    @markerPatches[patch.id] = patch

Serializable = require 'serializable'
Range = require './range'
Marker = require './marker'

# Represents a single change to {TextBuffer}. We reify the change into an object
# so it can be stored in the undo/redo stack of {History}.
module.exports =
class BufferPatch extends Serializable
  oldMarkersSnapshot: null

  constructor: (@oldRange, @newRange, @oldText, @newText, @normalizeLineEndings, @newMarkersSnapshot, @oldMarkersSnapshot) ->

  serializeParams: ->
    oldRange = @oldRange.serialize()
    newRange = @newRange.serialize()
    newMarkersSnapshot = Marker.serializeSnapshot(@newMarkersSnapshot)
    oldMarkersSnapshot = Marker.serializeSnapshot(@oldMarkersSnapshot)
    {oldRange, newRange, @oldText, @newText, @normalizeLineEndings, newMarkersSnapshot, oldMarkersSnapshot}

  deserializeParams: (params) ->
    params.oldRange = Range.deserialize(params.oldRange)
    params.newRange = Range.deserialize(params.newRange)
    params.newMarkersSnapshot = Marker.deserializeSnapshot(params.newMarkersSnapshot)
    params.oldMarkersSnapshot = Marker.deserializeSnapshot(params.oldMarkersSnapshot)
    params

  invert: (buffer) ->
    new @constructor(@newRange, @oldRange, @newText, @oldText, @normalizeLineEndings, @oldMarkersSnapshot)

  applyTo: (buffer) ->
    buffer.applyPatch(this)

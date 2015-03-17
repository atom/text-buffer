Serializable = require 'serializable'
Range = require './range'

# Represents a single change to {TextBuffer}. We reify the change into an object
# so it can be stored in the undo/redo stack of {History}. Changes to the buffer
# can be associated with changes to markers in addition to text, so this also
# contains a hash of {MarkerPatch} objects.
module.exports =
class BufferPatch extends Serializable
  constructor: (@oldRange, @newRange, @oldText, @newText, @normalizeLineEndings, @markerPatches={}) ->

  serializeParams: ->
    oldRange = @oldRange.serialize()
    newRange = @newRange.serialize()
    markerPatches = {}
    markerPatches[id] = patch.serialize() for id, patch in @markerPatches
    {oldRange, newRange, @oldText, @newText, @normalizeLineEndings, markerPatches}

  deserializeParams: (params) ->
    params.oldRange = Range.deserialize(params.oldRange)
    params.newRange = Range.deserialize(params.newRange)
    for id, patchState in params.markerPatches
      params.markerPatches[id] = MarkerPatch.deserialize(patchState)
    params

  invert: (buffer) ->
    markerPatches = {}
    markerPatches[id] = patch.invert() for id, patch of @markerPatches
    new @constructor(@newRange, @oldRange, @newText, @oldText, @normalizeLineEndings, markerPatches)

  applyTo: (buffer) ->
    buffer.applyPatch(this)

  addMarkerPatch: (patch) ->
    @markerPatches[patch.id] = patch

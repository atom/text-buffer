module.exports =
class BufferPatch
  constructor: (@oldRange, @newRange, @oldText, @newText, @markerPatches={}) ->

  invert: ->
    markerPatches = {}
    markerPatches[id] = patch.invert() for id, patch of @markerPatches
    new @constructor(@newRange, @oldRange, @newText, @oldText, markerPatches)

  applyTo: (textBuffer) ->
    textBuffer.applyPatch(this)

  addMarkerPatch: (patch) ->
    @markerPatches[patch.id] = patch

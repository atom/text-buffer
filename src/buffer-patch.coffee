module.exports =
class BufferPatch
  constructor: (@oldRange, @newRange, @oldText, @newText) ->
    @markerPatches = {}

  invert: ->
    new @constructor(@newRange, @oldRange, @newText, @oldText)

  applyTo: (textBuffer) ->
    textBuffer.applyPatch(this)

  addMarkerPatch: (patch) ->
    @markerPatches[patch.id] = patch

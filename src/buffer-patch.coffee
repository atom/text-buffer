module.exports =
class BufferPatch
  constructor: (@oldRange, @newRange, @oldText, @newText, @markerPatches={}) ->

  invert: (textBuffer) ->
    markerPatches = {}
    markerPatches[id] = patch.invert() for id, patch of @markerPatches
    invertedPatch = new @constructor(@newRange, @oldRange, @newText, @oldText, markerPatches)
    for marker in textBuffer.getMarkers()
      unless @markerPatches[marker.id]?
        marker.handleBufferChange(invertedPatch)
    invertedPatch

  applyTo: (textBuffer) ->
    textBuffer.applyPatch(this)

  addMarkerPatch: (patch) ->
    @markerPatches[patch.id] = patch

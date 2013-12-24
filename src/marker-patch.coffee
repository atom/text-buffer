module.exports =
class MarkerPatch
  constructor: (@id, @oldParams, @newParams) ->

  invert: ->
    new @constructor(@id, @newParams, @oldParams)

  applyTo: (textBuffer) ->
    textBuffer.getMarker(@id).update(@newParams)
